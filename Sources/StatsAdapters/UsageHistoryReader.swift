import Foundation
import StatsCore

/// Lightweight metrics accumulator used exclusively by `UsageHistoryReader` so
/// historical scans benefit from `IncrementalLog` + `ParseCacheStore` (zero-byte
/// restore on unchanged files) without paying for full timing-turn projections.
final class UsageLogMetrics: SessionMetrics {
  private static let fractionalTrim = try! NSRegularExpression(pattern: "\\.([0-9]{3})[0-9]+")
  private let fractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  private let plain = ISO8601DateFormatter()

  private let provider: StatsProvider
  var issues = 0
  private var updatedAt = 0.0
  private var model: String?

  init(provider: StatsProvider) {
    self.provider = provider
  }

  func accept(_ record: JSONObject) {
    let type = record["type"] as? String ?? ""
    if provider == .codex {
      if let stamp = record["timestamp"] as? String, !stamp.isEmpty {
        let msStamp = Self.fractionalTrim.stringByReplacingMatches(
          in: stamp, range: NSRange(stamp.startIndex..., in: stamp), withTemplate: ".$1")
        if let date = fractional.date(from: msStamp) ?? plain.date(from: msStamp) {
          updatedAt = max(updatedAt, (date.timeIntervalSince1970 * 1000).rounded())
        }
      }
      if type == "turn_context", let m = structuralText(jsonObject(record["payload"])["model"]) {
        model = m
      }
    } else {
      if let time = nonnegative(record["time"]) {
        updatedAt = max(updatedAt, time)
      }
      if type == "profile.bind", let m = structuralText(record["modelAlias"]) {
        model = m
      } else if type == "llm.request", record["kind"] as? String == "loop",
        let m = structuralText(record["modelAlias"]) ?? structuralText(record["model"])
      {
        model = m
      }
    }
  }

  func snapshot(now: Double) -> JSONObject {
    ["updatedAt": updatedAt, "model": nullable(model), "malformedLines": issues]
  }

  var cacheState: JSONObject? {
    ["schemaVersion": 1, "issues": issues, "updatedAt": updatedAt, "model": nullable(model)]
  }

  func restore(_ state: JSONObject) -> Bool {
    guard number(state["schemaVersion"]) == 1,
      let updatedAt = number(state["updatedAt"])
    else { return false }
    issues = Int(number(state["issues"]) ?? 0)
    self.updatedAt = updatedAt
    model = state["model"] as? String
    return true
  }
}

package protocol TokenHistoryServing: AnyObject {
  func loadAll(now: Double, completion: @escaping ([StatsProvider: ProviderTokenCorpus]) -> Void)
}

/// On-demand historical scanner for the Settings `Token 统计` page.
/// Reads both active and archived local sessions with a dedicated parse cache
/// (`token-stats-cache-<provider>.json`) so the live 1.5s HUD reader keeps
/// skipping archived Codex history.
package final class UsageHistoryReader {
  private let clock: StatsClock
  private let roots: [StatsProvider: URL]
  private let stores: [StatsProvider: SessionLogStore]
  private let caches: [StatsProvider: ParseCacheStore]
  private let codexCatalog: CodexRolloutCatalog
  private var kimiTaskCache =
    [String: (size: Int, modified: Double, entry: (agentID: String, startedAt: Double, model: String)?)]()

  package init(
    roots: [StatsProvider: URL]? = nil,
    cacheDirectory: URL = Product.cacheDirectory,
    clock: StatsClock = SystemStatsClock()
  ) {
    self.clock = clock
    var resolvedRoots = [StatsProvider: URL]()
    var resolvedStores = [StatsProvider: SessionLogStore]()
    var resolvedCaches = [StatsProvider: ParseCacheStore]()
    for provider in StatsProvider.allCases {
      let root = (roots?[provider] ?? provider.dataRoot).standardizedFileURL.resolvingSymlinksInPath()
      resolvedRoots[provider] = root
      let cache = ParseCacheStore(
        path: cacheDirectory.appendingPathComponent("token-stats-cache-\(provider.rawValue).json"),
        clock: clock)
      resolvedCaches[provider] = cache
      resolvedStores[provider] = SessionLogStore(root: root, provider: provider, cache: cache) {
        _ in UsageLogMetrics(provider: provider)
      }
    }
    self.roots = resolvedRoots
    self.stores = resolvedStores
    self.caches = resolvedCaches
    self.codexCatalog = CodexRolloutCatalog(logs: resolvedStores[.codex]!)
  }

  package func restoredLogs(for provider: StatsProvider) -> Int {
    stores[provider]?.restoredLogs ?? 0
  }

  package func parsedBytes(for provider: StatsProvider) -> UInt64 {
    stores[provider]?.parsedBytes ?? 0
  }

  package func flushCaches() {
    for cache in caches.values { cache.flush() }
  }

  package func scanAll(now: Double? = nil) -> [StatsProvider: ProviderTokenCorpus] {
    let timestamp = now ?? clock.milliseconds
    return [
      .codex: scanCodex(now: timestamp),
      .kimi: scanKimi(now: timestamp),
    ]
  }

  package func scan(provider: StatsProvider, now: Double? = nil) -> ProviderTokenCorpus {
    let timestamp = now ?? clock.milliseconds
    switch provider {
    case .codex: return scanCodex(now: timestamp)
    case .kimi: return scanKimi(now: timestamp)
    }
  }

  private func scanCodex(now: Double) -> ProviderTokenCorpus {
    let logs = stores[.codex]!
    let groups = codexCatalog.projectGroups()
    let rows = codexCatalog.entries(now: now)

    var agents = [JSONObject]()
    var ledgers = [String: [JSONObject]]()
    var journalsByKey = [String: UsageJournal]()
    var livePaths = Set<String>()

    for meta in rows {
      let id = identifier(meta["id"])
      let pages = codexCatalog.branch(for: id, primary: meta["rollout_path"] as? String)
      let key = pages.slices.first?.url.path
      var loaded: JSONObject?
      var journal: UsageJournal?
      if let key, logs.safeLog(URL(fileURLWithPath: key)) {
        livePaths.insert(key)
        loaded = try? logs.load(
          pages.slices, now: now, sessionID: meta["catalogued"] as? Bool == true ? id : nil)
        journal = loaded == nil ? nil : logs.journal(at: URL(fileURLWithPath: key))
      }
      if let journal { journalsByKey[id] = journal }

      var facts = meta
      facts.merge(journal?.metadata ?? [:]) { old, new in new is NSNull ? old : new }
      let child = UsageAccounting.isChild(facts)
      let parent = UsageAccounting.parent(facts)
      let isForked =
        structuralText(facts["forked_from_id"]) != nil
        || structuralText(facts["attached_thread_parent_id"]) != nil
      let inherited = isForked ? (journal?.inheritedTokens ?? 0) : 0
      let hostTokens: Any =
        nonnegative(facts["tokens_used"]).map { rawHost in
          loaded != nil && inherited > 0 ? max(0, rawHost - inherited) : rawHost
        } ?? jsonNull

      let row: JSONObject = [
        "id": child ? "__agent__:" + id : id,
        "key": id,
        "sessionID": id,
        "agentID": id,
        "title": meta["title"] ?? SessionTitle.unnamed(id),
        "group": groups.group(for: id),
        "project": usageProject(cwd: facts["cwd"], workspace: facts["project_id"]),
        "provider": "codex",
        "role": child ? "subagent" : "main",
        "parentID": nullable(parent),
        "archived": meta["archived"] ?? false,
        "accountingMode": journal?.mode ?? "missing",
        "partial": loaded == nil || journal?.partial == true
          || (number(loaded?["malformedLines"]) ?? 0) > 0,
        "hostTokensUsed": hostTokens,
        "updatedAt": meta["updatedAt"] ?? loaded?["updatedAt"] ?? 0,
        "model": nullable(
          journal?.currentModel ?? (loaded?["model"] as? String) ?? (facts["model"] as? String)),
      ]
      ledgers[id] = journal?.values ?? []
      agents.append(row)
    }

    let known = Dictionary(agents.map { (identifier($0["key"]), $0) }, uniquingKeysWith: { $1 })
    for i in agents.indices {
      var current = identifier(agents[i]["key"])
      var visited = Set<String>()
      var valid = true
      while let parent = structuralText(known[current]?["parentID"]) {
        guard parent != current, !visited.contains(parent), known[parent] != nil else {
          valid = false
          break
        }
        visited.insert(current)
        current = parent
      }
      let child = agents[i]["role"] as? String == "subagent"
      if child && structuralText(agents[i]["parentID"]) == nil { valid = false }
      agents[i]["taskKey"] = valid ? current : identifier(agents[i]["key"])
      if valid { agents[i]["group"] = groups.group(for: current) }
      if !valid { agents[i]["parentID"] = jsonNull }
    }

    logs.finishScan(livePaths: livePaths)
    return buildCorpus(
      provider: .codex, now: now, agents: agents, ledgers: ledgers, journalsByKey: journalsByKey)
  }

  private func scanKimi(now: Double) -> ProviderTokenCorpus {
    let logs = stores[.kimi]!
    let root = roots[.kimi]!
    let groups = ProjectCatalog.kimi(root: root)

    var agents = [JSONObject]()
    var ledgers = [String: [JSONObject]]()
    var journalsByKey = [String: UsageJournal]()
    var livePaths = Set<String>()
    var liveTaskFiles = Set<String>()

    for workspace in directories(root.appendingPathComponent("sessions")) {
      for directory in directories(workspace) {
        let stateFile = directory.appendingPathComponent("state.json")
        let stateInfo = try? stateFile.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        let state =
          stateInfo?.isSymbolicLink == false && (stateInfo?.fileSize ?? Int.max) <= 2 * 1024 * 1024
          ? (try? Data(contentsOf: stateFile)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? JSONObject
          } ?? [:] : [:]
        let archived = state["archived"] as? Bool == true
        let sessionID = directory.lastPathComponent
        let taskKey = usageHash(workspace.lastPathComponent + "/" + sessionID)
        let project = usageProject(
          cwd: state["cwd"] ?? state["workDir"], workspace: workspace.lastPathComponent)
        let declared = jsonObject(state["agents"])
        let agentDirectories = directories(directory.appendingPathComponent("agents"))
        var agentIDs = Set(agentDirectories.map { $0.lastPathComponent })
        agentIDs.formUnion(declared.keys)
        agentIDs.insert("main")
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("wire.jsonl").path)
        {
          agentIDs.insert("main")
        }
        let taskModels = kimiTaskModels(agentDirectories: agentDirectories, live: &liveTaskFiles)

        for agentID in agentIDs.sorted()
        where !agentID.contains("/") && agentID != "." && agentID != ".." {
          var file = directory.appendingPathComponent("agents/\(agentID)/wire.jsonl")
          if agentID == "main", !FileManager.default.fileExists(atPath: file.path) {
            file = directory.appendingPathComponent("wire.jsonl")
          }
          guard !FileManager.default.fileExists(atPath: file.path) || logs.safeLog(file) else {
            continue
          }
          livePaths.insert(file.path)
          let loaded = try? logs.load(file, now: now, agentID: agentID)
          let journal = loaded == nil ? nil : logs.journal(at: file)
          let key = taskKey + ":" + agentID
          if let journal { journalsByKey[key] = journal }

          let declaredAgent = jsonObject(declared[agentID])
          let parent = structuralText(declaredAgent["parentAgentId"])
          let model =
            journal?.currentModel
            ?? SessionTitle.nonempty(loaded?["model"])
            ?? SessionTitle.nonempty(taskModels[agentID])
          let row: JSONObject = [
            "id": agentID == "main" ? sessionID : "__agent__:" + key,
            "key": key,
            "taskKey": taskKey,
            "sessionID": sessionID,
            "agentID": agentID,
            "title": agentID == "main"
              ? SessionTitle.resolved(state["title"], id: sessionID) : agentID,
            "group": groups.group(for: workspace.lastPathComponent),
            "project": project,
            "provider": "kimi",
            "role": agentID == "main" ? "main" : "subagent",
            "parentID": parent != agentID && parent.map(agentIDs.contains) == true
              ? parent as Any : jsonNull,
            "archived": archived,
            "accountingMode": journal?.mode ?? "missing",
            "partial": loaded == nil || journal?.partial == true
              || (number(loaded?["malformedLines"]) ?? 0) > 0,
            "updatedAt": loaded?["updatedAt"] ?? 0,
            "model": nullable(model),
          ]
          ledgers[key] = journal?.values ?? []
          agents.append(row)
        }
      }
    }

    logs.finishScan(livePaths: livePaths)
    kimiTaskCache = kimiTaskCache.filter { liveTaskFiles.contains($0.key) }
    return buildCorpus(
      provider: .kimi, now: now, agents: agents, ledgers: ledgers, journalsByKey: journalsByKey)
  }

  private func directories(_ url: URL) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(
      at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles])) ?? []).filter {
      let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      return values?.isDirectory == true && values?.isSymbolicLink != true
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func kimiTaskModels(agentDirectories: [URL], live: inout Set<String>) -> [String: String] {
    var identities = [String: (startedAt: Double, model: String)]()
    for agent in agentDirectories.prefix(256) {
      let files = ((try? FileManager.default.contentsOfDirectory(
        at: agent.appendingPathComponent("tasks"),
        includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles])) ?? []).filter { $0.pathExtension == "json" }
      for file in files.prefix(1024) {
        let info = try? file.resourceValues(forKeys: [
          .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ])
        guard info?.isSymbolicLink != true, (info?.fileSize ?? Int.max) <= 128 * 1024 else {
          continue
        }
        live.insert(file.path)
        let size = info?.fileSize ?? -1
        let modified = info?.contentModificationDate?.timeIntervalSince1970 ?? -1
        let parsedEntry: (agentID: String, startedAt: Double, model: String)?
        if let cached = kimiTaskCache[file.path], cached.size == size, cached.modified == modified {
          parsedEntry = cached.entry
        } else {
          let data = try? Data(contentsOf: file)
          let obj = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? JSONObject }
          if let obj, obj["kind"] as? String == "agent",
            let model = SessionTitle.nonempty(obj["model"]),
            let agentID = structuralText(obj["agentId"])
          {
            parsedEntry = (agentID, nonnegative(obj["startedAt"]) ?? 0, model)
          } else {
            parsedEntry = nil
          }
          kimiTaskCache[file.path] = (size, modified, parsedEntry)
        }
        guard let parsedEntry else { continue }
        if identities[parsedEntry.agentID] == nil
          || (identities[parsedEntry.agentID]?.startedAt ?? 0) <= parsedEntry.startedAt
        {
          identities[parsedEntry.agentID] = (parsedEntry.startedAt, parsedEntry.model)
        }
      }
    }
    return identities.mapValues(\.model)
  }

  private func buildCorpus(
    provider: StatsProvider,
    now: Double,
    agents: [JSONObject],
    ledgers: [String: [JSONObject]],
    journalsByKey: [String: UsageJournal]
  ) -> ProviderTokenCorpus {
    let resolved = UsageAccounting.resolve(agents, ledgers: ledgers)
    var sharedByTask = [String: [JSONObject]]()
    var crossSessionShared = [JSONObject]()
    for record in resolved.shared {
      let taskKeys = record["taskKeys"] as? [String] ?? []
      if taskKeys.count == 1, let onlyTask = taskKeys.first {
        sharedByTask[onlyTask, default: []].append(record)
      } else {
        crossSessionShared.append(record)
      }
    }

    struct CoalesceKey: Hashable {
      let bucketTime: Double?
      let model: String?
      let projectKey: String
      let sessionKey: String
      let archived: Bool
      let isSharedCrossSession: Bool
      let source: TokenUsageEntry.Source
    }
    struct CoalesceValue {
      var projectTitle: String
      var projectSubtitle: String?
      var sessionTitle: String
      var input: Double = 0
      var cacheRead: Double = 0
      var cacheWrite: Double = 0
      var output: Double = 0
      var totalTokens: Double = 0
      var requestCount: Int = 0
    }

    var buckets = [CoalesceKey: CoalesceValue]()
    var bucketOrder = [CoalesceKey]()

    func appendEntry(
      timestampMs: Double?, model: String?,
      project: (key: String, title: String, subtitle: String?),
      sessionKey: String, sessionTitle: String, archived: Bool,
      isSharedCrossSession: Bool, source: TokenUsageEntry.Source,
      input: Double, cacheRead: Double, cacheWrite: Double, output: Double,
      totalTokens: Double, requestCount: Int
    ) {
      let bucketTime = timestampMs.flatMap { $0 > 0 ? floor($0 / 900_000) * 900_000 : nil }
      let key = CoalesceKey(
        bucketTime: bucketTime, model: model, projectKey: project.key,
        sessionKey: sessionKey, archived: archived,
        isSharedCrossSession: isSharedCrossSession, source: source)
      if buckets[key] == nil {
        buckets[key] = CoalesceValue(
          projectTitle: project.title, projectSubtitle: project.subtitle,
          sessionTitle: sessionTitle)
        bucketOrder.append(key)
      }
      buckets[key]!.input += input
      buckets[key]!.cacheRead += cacheRead
      buckets[key]!.cacheWrite += cacheWrite
      buckets[key]!.output += output
      buckets[key]!.totalTokens += totalTokens
      buckets[key]!.requestCount += requestCount
    }

    let grouped = Dictionary(grouping: agents, by: { identifier($0["taskKey"]) })
    var totalSessions = 0
    var archivedSessions = 0
    var ambiguousSessions = 0
    var hostFallbackSessions = 0
    var partialSessions = 0

    for taskKey in grouped.keys.sorted() {
      let members = grouped[taskKey]!
      totalSessions += 1
      let main =
        members.first { identifier($0["key"]) == taskKey || $0["role"] as? String == "main" }
        ?? members[0]
      let sessionTitle = SessionTitle.resolved(main["title"], id: identifier(main["sessionID"]))
      let archived = main["archived"] as? Bool == true
      if archived { archivedSessions += 1 }
      let projectDisplay = resolveProjectDisplay(
        provider: provider, group: jsonObject(main["group"]), project: jsonObject(main["project"]))
      let localShared = sharedByTask[taskKey] ?? []

      let uncertain = members.contains {
        $0["accountingMode"] as? String == "missing" || $0["partial"] as? Bool == true
      }
      let cumulative = members.contains { $0["accountingMode"] as? String == "cumulative" }
      let ambiguous = cumulative && members.count > 1
      let hostTokens: Double? =
        members.allSatisfy { nonnegative($0["hostTokensUsed"]) != nil }
        ? members.reduce(0) { $0 + (nonnegative($1["hostTokensUsed"]) ?? 0) } : nil

      var memberRequests = [(member: JSONObject, records: [JSONObject])]()
      for member in members {
        let key = identifier(member["key"])
        let recs = resolved.owned[key] ?? []
        if !recs.isEmpty { memberRequests.append((member, recs)) }
      }

      func emitObservedRequests() {
        let fallbackUpdated = nonnegative(main["updatedAt"]).flatMap { $0 > 0 ? $0 : nil }
        let fallbackModel = SessionTitle.nonempty(main["model"])
        for (member, recs) in memberRequests {
          let memberTime =
            nonnegative(member["updatedAt"]).flatMap { $0 > 0 ? $0 : nil } ?? fallbackUpdated
          let memberModel = SessionTitle.nonempty(member["model"]) ?? fallbackModel
          for rec in recs {
            appendEntry(
              timestampMs: nonnegative(rec["time"]) ?? memberTime,
              model: SessionTitle.nonempty(rec["model"]) ?? memberModel,
              project: projectDisplay,
              sessionKey: taskKey, sessionTitle: sessionTitle, archived: archived,
              isSharedCrossSession: false, source: .requests,
              input: nonnegative(rec["input"]) ?? 0,
              cacheRead: nonnegative(rec["cacheRead"]) ?? 0,
              cacheWrite: nonnegative(rec["cacheWrite"]) ?? 0,
              output: nonnegative(rec["output"]) ?? 0,
              totalTokens: nonnegative(rec["totalTokens"]) ?? 0,
              requestCount: 1)
          }
        }
        for rec in localShared {
          appendEntry(
            timestampMs: nonnegative(rec["time"]) ?? fallbackUpdated,
            model: SessionTitle.nonempty(rec["model"]) ?? fallbackModel,
            project: projectDisplay,
            sessionKey: taskKey, sessionTitle: sessionTitle, archived: archived,
            isSharedCrossSession: false, source: .requests,
            input: nonnegative(rec["input"]) ?? 0,
            cacheRead: nonnegative(rec["cacheRead"]) ?? 0,
            cacheWrite: nonnegative(rec["cacheWrite"]) ?? 0,
            output: nonnegative(rec["output"]) ?? 0,
            totalTokens: nonnegative(rec["totalTokens"]) ?? 0,
            requestCount: 1)
        }
      }

      if ambiguous {
        ambiguousSessions += 1
        partialSessions += 1
        if !memberRequests.isEmpty || !localShared.isEmpty {
          emitObservedRequests()
        }
        continue
      }

      if !memberRequests.isEmpty || !localShared.isEmpty {
        emitObservedRequests()
        let parsedTotal =
          memberRequests.reduce(0.0) { acc, item in acc + sum(item.records, "totalTokens") }
          + sum(localShared, "totalTokens")
        if uncertain {
          partialSessions += 1
          if let hostTokens, localShared.isEmpty, hostTokens > parsedTotal {
            hostFallbackSessions += 1
            let updated = nonnegative(main["updatedAt"]).flatMap { $0 > 0 ? $0 : nil }
            let m = SessionTitle.nonempty(main["model"])
            appendEntry(
              timestampMs: updated, model: m, project: projectDisplay,
              sessionKey: taskKey, sessionTitle: sessionTitle, archived: archived,
              isSharedCrossSession: false, source: .hostCounter,
              input: 0, cacheRead: 0, cacheWrite: 0, output: 0,
              totalTokens: hostTokens - parsedTotal, requestCount: 0)
          }
        } else if let hostTokens, abs(parsedTotal - hostTokens) > max(2000, hostTokens * 0.02) {
          partialSessions += 1
        }
      } else if !uncertain && cumulative {
        let member = members[0]
        let key = identifier(member["key"])
        if let journal = journalsByKey[key], let cum = journal.cumulative {
          let t =
            nonnegative(journal.cumulativeTime)
            ?? nonnegative(member["updatedAt"]).flatMap { $0 > 0 ? $0 : nil }
          let m = SessionTitle.nonempty(member["model"])
          appendEntry(
            timestampMs: t, model: m, project: projectDisplay,
            sessionKey: taskKey, sessionTitle: sessionTitle, archived: archived,
            isSharedCrossSession: false, source: .cumulative,
            input: nonnegative(cum["input"]) ?? 0,
            cacheRead: nonnegative(cum["cacheRead"]) ?? 0,
            cacheWrite: nonnegative(cum["cacheWrite"]) ?? 0,
            output: nonnegative(cum["output"]) ?? 0,
            totalTokens: nonnegative(cum["totalTokens"]) ?? 0,
            requestCount: 0)
        }
      } else {
        partialSessions += 1
        if let hostTokens {
          hostFallbackSessions += 1
          let updated = nonnegative(main["updatedAt"]).flatMap { $0 > 0 ? $0 : nil }
          let m = SessionTitle.nonempty(main["model"])
          appendEntry(
            timestampMs: updated, model: m, project: projectDisplay,
            sessionKey: taskKey, sessionTitle: sessionTitle, archived: archived,
            isSharedCrossSession: false, source: .hostCounter,
            input: 0, cacheRead: 0, cacheWrite: 0, output: 0,
            totalTokens: hostTokens, requestCount: 0)
        }
      }
    }

    for rec in crossSessionShared {
      let projectDisplay = resolveProjectDisplay(
        provider: provider, group: [:], project: jsonObject(rec["project"]))
      appendEntry(
        timestampMs: nonnegative(rec["time"]),
        model: SessionTitle.nonempty(rec["model"]),
        project: projectDisplay,
        sessionKey: "__shared__",
        sessionTitle: "跨会话共享历史（去重）",
        archived: false,
        isSharedCrossSession: true,
        source: .requests,
        input: nonnegative(rec["input"]) ?? 0,
        cacheRead: nonnegative(rec["cacheRead"]) ?? 0,
        cacheWrite: nonnegative(rec["cacheWrite"]) ?? 0,
        output: nonnegative(rec["output"]) ?? 0,
        totalTokens: nonnegative(rec["totalTokens"]) ?? 0,
        requestCount: 1)
    }

    let entries = bucketOrder.map { key -> TokenUsageEntry in
      let val = buckets[key]!
      return TokenUsageEntry(
        provider: provider,
        timestampMs: key.bucketTime,
        model: key.model,
        projectKey: key.projectKey,
        projectTitle: val.projectTitle,
        projectSubtitle: val.projectSubtitle,
        sessionKey: key.sessionKey,
        sessionTitle: val.sessionTitle,
        archived: key.archived,
        isSharedCrossSession: key.isSharedCrossSession,
        source: key.source,
        input: val.input,
        cacheRead: val.cacheRead,
        cacheWrite: val.cacheWrite,
        output: val.output,
        totalTokens: val.totalTokens,
        requestCount: val.requestCount)
    }

    return ProviderTokenCorpus(
      provider: provider,
      collectedAt: now,
      entries: entries,
      totalSessions: totalSessions,
      archivedSessions: archivedSessions,
      ambiguousSessions: ambiguousSessions,
      hostFallbackSessions: hostFallbackSessions,
      partialSessions: partialSessions)
  }

  private func resolveProjectDisplay(
    provider: StatsProvider, group: JSONObject, project: JSONObject
  ) -> (key: String, title: String, subtitle: String?) {
    let groupID = group["id"] as? String
    let groupTitle = SessionTitle.nonempty(group["title"])
    let cwd = project["cwd"] as? String
    let workspace = project["workspace"] as? String

    if let cwd, !cwd.isEmpty {
      let key = "cwd:" + cwd
      if let groupID, groupID != StatsGroup.ungroupedID, let groupTitle {
        return (key, groupTitle, cwd)
      }
      let last = URL(fileURLWithPath: cwd).lastPathComponent
      return (key, (last.isEmpty || last == "/") ? cwd : last, cwd)
    }
    if let groupID, groupID != StatsGroup.ungroupedID, let groupTitle {
      return ("\(provider.rawValue):group:\(groupID)", groupTitle, nil)
    }
    if let workspace, !workspace.isEmpty {
      return ("\(provider.rawValue):ws:\(workspace)", "工作区 · " + workspace, nil)
    }
    return ("\(provider.rawValue):unknown", "未归属项目", nil)
  }
}

package final class LiveTokenHistoryService: TokenHistoryServing {
  private let queue = DispatchQueue(label: "\(Product.bundleID).token-history", qos: .utility)
  private let uiScheduler: StatsScheduling
  private let clock: StatsClock
  private var reader: UsageHistoryReader?
  private var inFlight = false
  private var pendingCompletions = [([StatsProvider: ProviderTokenCorpus]) -> Void]()

  package init(clock: StatsClock, uiScheduler: StatsScheduling) {
    self.clock = clock
    self.uiScheduler = uiScheduler
  }

  package func loadAll(
    now: Double, completion: @escaping ([StatsProvider: ProviderTokenCorpus]) -> Void
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      self.pendingCompletions.append(completion)
      guard !self.inFlight else { return }
      self.inFlight = true
      let instance = self.reader ?? UsageHistoryReader(clock: self.clock)
      self.reader = instance
      let result = instance.scanAll(now: now)
      let callbacks = self.pendingCompletions
      self.pendingCompletions.removeAll()
      self.inFlight = false
      self.uiScheduler.execute {
        for callback in callbacks { callback(result) }
      }
    }
  }
}
