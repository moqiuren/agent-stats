import CryptoKit
import Foundation

package func usageHash(_ value: String) -> String {
  SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
    .description
}
package func structuralText(_ value: Any?) -> String? {
  guard let s = value as? String, !s.isEmpty, s.count <= 2048,
    !s.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  else { return nil }
  return s
}
package func usageProject(cwd: Any?, workspace: Any? = nil) -> JSONObject {
  let wd = structuralText(workspace)
  if let raw = structuralText(cwd), raw.hasPrefix("/") {
    let path = URL(fileURLWithPath: raw).standardizedFileURL.path
    return [
      "id": usageHash("cwd:" + path), "title": path, "cwd": path, "workspace": nullable(wd),
      "known": true,
    ]
  }
  if let wd {
    return [
      "id": usageHash("workspace:" + wd), "title": "工作区 · " + wd, "workspace": wd, "cwd": jsonNull,
      "known": true,
    ]
  }
  return ["id": "unknown", "title": "项目未知", "cwd": jsonNull, "workspace": jsonNull, "known": false]
}

package struct UsageLedgerVersion: Equatable {
  package let identity: UUID
  package let revision: UInt64
  package init(identity: UUID, revision: UInt64) {
    self.identity = identity
    self.revision = revision
  }
}

package struct ResolvedUsage {
  package var totals = [String: JSONObject]()
  package var rawTokens = [String: Double]()
  package var shared = [JSONObject]()
  package var sharedByTask = [String: [JSONObject]]()
  package init() {}
}

// Accounting depends on journal revisions and explicit ownership, not on the
// clock used by live timing metrics. Keep this cache separate from UI snapshots.
package final class UsageResolutionCache {
  package init() {}
  private struct Source: Equatable {
    let key: String
    let task: String
    let project: NSDictionary
    let version: UsageLedgerVersion?
  }
  private var sources: [Source]?
  private var cached = ResolvedUsage()

  package func resolve(
    _ rows: [JSONObject], ledgers: [String: [JSONObject]],
    versions: [String: UsageLedgerVersion]
  ) -> ResolvedUsage {
    let next = rows.map { row in
      let key = identifier(row["key"])
      return Source(
        key: key, task: identifier(row["taskKey"]),
        project: jsonObject(row["project"]) as NSDictionary, version: versions[key])
    }
    if sources == next { return cached }

    let resolved = UsageAccounting.resolve(rows, ledgers: ledgers)
    var result = ResolvedUsage()
    for source in next {
      result.totals[source.key] = UsageAccounting.total(resolved.owned[source.key] ?? [])
      result.rawTokens[source.key] = sum(ledgers[source.key] ?? [], "totalTokens")
    }
    result.shared = resolved.shared
    for record in resolved.shared {
      for task in record["taskKeys"] as? [String] ?? [] {
        result.sharedByTask[task, default: []].append(record)
      }
    }
    sources = next
    cached = result
    return result
  }
}

package enum UsageAccounting {
  package static let counters = ["input", "cacheRead", "cacheWrite", "output", "totalTokens"]
  package static let boundary = "仅统计本机可见记录。Ultra 服务端内部未公开的代理和消耗无法拆分，也不能据此确认账单完整。"
  package static func total(_ records: [JSONObject]) -> JSONObject {
    Dictionary(uniqueKeysWithValues: counters.map { ($0, sum(records, $0)) })
  }
  package static func isChild(_ meta: JSONObject) -> Bool {
    parent(meta) != nil
      || ["subagent", "guardian_review"].contains(meta["thread_source"] as? String ?? "")
      || jsonObject(meta["source"])["subagent"] != nil
      || (meta["source"] as? String ?? "").contains("subagent")
  }
  package static func parent(_ meta: JSONObject) -> String? {
    if let id = structuralText(meta["parent_thread_id"]) { return id }
    let sub = jsonObject(jsonObject(meta["source"])["subagent"])
    return structuralText(jsonObject(sub["thread_spawn"])["parent_thread_id"])
  }
  // Shared copied history is counted once, with ambiguous ownership exposed.
  // This deliberately avoids assigning a request to whichever fork was scanned first.
  package static func resolve(_ rows: [JSONObject], ledgers: [String: [JSONObject]]) -> (
    owned: [String: [JSONObject]], shared: [JSONObject]
  ) {
    var seen = [String: JSONObject]()
    var owners = [String: Set<String>]()
    let byID = Dictionary(rows.map { (identifier($0["key"]), $0) }, uniquingKeysWith: { $1 })
    for row in rows {
      let key = identifier(row["key"])
      for record in ledgers[key] ?? [] {
        let id = identifier(record["id"])
        seen[id] = record
        owners[id, default: []].insert(key)
      }
    }
    var owned = [String: [JSONObject]]()
    var shared = [JSONObject]()
    for id in seen.keys.sorted() {
      let keys = owners[id]!
      let record = seen[id]!
      if keys.count == 1 {
        owned[keys.first!, default: []].append(record)
      } else {
        let projects = Set(keys.map { identifier(jsonObject(byID[$0]?["project"])["id"]) })
        var item = record
        item["project"] =
          projects.count == 1 ? byID[keys.first!]?["project"] : usageProject(cwd: nil)
        item["taskKeys"] = Set(keys.map { identifier(byID[$0]?["taskKey"]) }).sorted()
        shared.append(item)
      }
    }
    return (owned, shared)
  }
  package static func apply(_ totals: JSONObject, to row: inout JSONObject) {
    for key in counters { row[key] = totals[key] ?? jsonNull }
  }
  package static func aggregate(_ agents: [JSONObject], extra: [JSONObject] = []) -> JSONObject {
    var result = total(agents + extra)
    let uncertain = agents.contains {
      $0["accountingMode"] as? String == "missing" || $0["partial"] as? Bool == true
    }
    let cumulative = agents.contains { $0["accountingMode"] as? String == "cumulative" }
    let ambiguous = cumulative && agents.count > 1
    // The host keeps its own per-thread token counter. When every member carries
    // one it is the only authoritative total left for a parse that is missing or
    // that contradicts the counter; the parsed breakdown stays unknown rather
    // than being stretched to match a number it cannot support.
    let hostTokens: Double? =
      agents.allSatisfy { nonnegative($0["hostTokensUsed"]) != nil }
      ? agents.reduce(0) { $0 + (nonnegative($1["hostTokensUsed"]) ?? 0) } : nil
    if uncertain || ambiguous { for key in counters { result[key] = jsonNull } }
    result["observedRequestTokens"] =
      sum(agents.filter { $0["accountingMode"] as? String == "requests" }, "totalTokens")
      + sum(extra, "totalTokens")
    result["partial"] = uncertain || ambiguous
    let input =
      (number(result["input"]) ?? 0) + (number(result["cacheRead"]) ?? 0)
      + (number(result["cacheWrite"]) ?? 0)
    result["cacheHit"] =
      uncertain || ambiguous || input == 0
      ? jsonNull : ((number(result["cacheRead"]) ?? 0) * 100 / input) as Any
    result["coverageNote"] =
      ambiguous
      ? "包含累计快照，是否与其他代理重叠未知；合计未相加。"
      : uncertain ? "部分日志缺失或不完整，合计未知；可查看已记录的代理明细。" : "逐请求记录已去重；不包含未公开的服务端消耗。"
    if let hostTokens {
      if nonnegative(result["totalTokens"]) == nil {
        // No parsed total at all: the host counter is strictly better than nothing.
        // Ambiguous cumulative snapshots stay unresolved, because their host
        // counters may each carry the same copied history.
        if uncertain && !ambiguous && extra.isEmpty {
          result["totalTokens"] = hostTokens
          result["totalSource"] = "host"
          result["coverageNote"] = "日志不可读，总计采用宿主本机计数；拆分与耗时未知。仅统计本机可见记录。"
        }
      } else {
        let parsed = number(result["totalTokens"]) ?? 0
        if abs(parsed - hostTokens) > max(2000, hostTokens * 0.02) {
          result["partial"] = true
          result["hostTokensUsed"] = hostTokens
          result["coverageNote"] =
            "逐请求合计与宿主计数不一致（宿主计数 "
            + String(format: "%.0f", hostTokens) + "），可能存在未合并的历史页；以明细为准。"
        }
      }
    }
    return result
  }
  package static func projects(_ agents: [JSONObject], shared: [JSONObject]) -> [JSONObject] {
    var catalog = [String: JSONObject]()
    var groups = [String: [JSONObject]]()
    var extra = [String: [JSONObject]]()
    for row in agents {
      let p = jsonObject(row["project"])
      let id = identifier(p["id"])
      catalog[id] = p
      groups[id, default: []].append(row)
    }
    for row in shared {
      let p = jsonObject(row["project"])
      let id = identifier(p["id"])
      catalog[id] = p
      extra[id, default: []].append(row)
    }
    return catalog.keys.sorted().map { id in
      var p = catalog[id]!
      p.merge(aggregate(groups[id] ?? [], extra: extra[id] ?? [])) { _, new in new }
      p["id"] = "__project__:" + id
      p["projectID"] = id
      p["agents"] = groups[id] ?? []
      p["sharedHistoryTokens"] = sum(extra[id] ?? [], "totalTokens")
      p["loaded"] = true
      p["isProject"] = true
      return p
    }.sorted { identifier($0["title"]) < identifier($1["title"]) }
  }
}
