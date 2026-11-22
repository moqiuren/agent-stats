import StatsCore
import Foundation
import SQLite3

// One thread can span several rollout pages: a continuation page keeps running
// ordinals after a compaction, a revision page restarts at zero and supersedes
// older takes. Pages are grouped by the first UUID in the rollout file name and
// merged only along one branch: the newest zero-ordinal head plus its
// continuations. Compressed pages are resolved through their `.zst` twin when
// the plain path is gone, which is how the host stores cold rollouts.
struct RolloutPages {
    // Ordered page slices of the chosen branch; the first one keys the parse cache.
    var slices = [LogPageSlice]()
    // Candidates rejected as superseded revision heads or abandoned takes, kept for diagnostics.
    var droppedRevisions = [URL]()
    // Identity of the candidate set the resolution was computed from.
    var signature = ""
}

private struct RolloutPageHeader {
    var firstOrdinal: Int = -1
    var parentPageID: String?
    var endOrdinalExclusive: Int?
}

final class CodexRolloutCatalog {
    private let logs: SessionLogStore
    private var root: URL { logs.root }
    private var groups: ProjectCatalog?
    private var groupsFingerprint: String?
    private var catalog = [JSONObject](), pageIndex = [String: [URL]](),
        catalogAt = -Double.infinity
    private var pageBranches = [String: RolloutPages]()

    init(logs: SessionLogStore) {
        self.logs = logs
    }

    func projectGroups() -> ProjectCatalog {
        let fingerprint = ProjectCatalog.fingerprint(root: root, provider: "codex")
        if let groups, groupsFingerprint == fingerprint { return groups }
        let loaded = ProjectCatalog.codex(root: root)
        groups = loaded; groupsFingerprint = fingerprint
        return loaded
    }

    func entries(now: Double) -> [JSONObject] {
        if now - catalogAt < 5000 { return catalog }
        let fm = FileManager.default
        let titles = codexIndexedTitles()
        // Rollout pages are grouped by the first UUID in their file name, which
        // is the owning thread; `_child` suffixes mark continuation pages.
        var index = [String: [URL]]()
        let namePattern = try! NSRegularExpression(
            pattern: "^rollout-.*?([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})")
        for directory in ["sessions", "archived_sessions"] {
            guard let enumerator = fm.enumerator(
                at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
            else { continue }
            for case let file as URL in enumerator {
                let name = file.lastPathComponent
                guard name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst") else { continue }
                let range = NSRange(name.startIndex..., in: name)
                guard let match = namePattern.firstMatch(in: name, range: range),
                    let idRange = Range(match.range(at: 1), in: name)
                else { continue }
                index[String(name[idRange]), default: []].append(file)
            }
        }
        for key in index.keys { index[key]?.sort { $0.lastPathComponent < $1.lastPathComponent } }

        let files = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter {
            $0.range(of: "^state_[0-9]+\\.sqlite$", options: .regularExpression) != nil
        }.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        var rows: [JSONObject]?
        var transientFailure = false
        if let file = files.first {
            var db: OpaquePointer?
            if sqlite3_open_v2(root.appendingPathComponent(file).path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK {
                sqlite3_busy_timeout(db, 1000)
                var columns = Set<String>(), schema: OpaquePointer?
                if sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1, &schema, nil) == SQLITE_OK {
                    while sqlite3_step(schema) == SQLITE_ROW {
                        if let name = sqlite3_column_text(schema, 1) { columns.insert(String(cString: name)) }
                    }
                }
                sqlite3_finalize(schema)
                let displayName = columns.contains("name") ? "name" : "NULL"
                let initialMessage = columns.contains("first_user_message") ? "first_user_message" : "NULL"
                let extraKeys = ["cwd", "project_id", "thread_source", "source", "parent_thread_id", "agent_nickname", "agent_role", "tokens_used", "attached_thread_parent_id", "model"]
                let extra = extraKeys.map { columns.contains($0) ? $0 : "NULL" }.joined(separator: ",")
                let sql = "SELECT id,title,rollout_path,archived,updated_at*1000 AS updatedAt,\(displayName),\(initialMessage),\(extra) FROM threads ORDER BY updated_at DESC"
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                    var result = [JSONObject](), status = sqlite3_step(statement)
                    while status == SQLITE_ROW {
                        func text(_ col: Int32) -> String { sqlite3_column_text(statement, col).map { String(cString: $0) } ?? "" }
                        let id = text(0), legacyTitle = SessionTitle.nonempty(text(1)), firstMessage = SessionTitle.nonempty(text(6))
                        let title = SessionTitle.nonempty(text(5)) ?? titles[id]
                            ?? (legacyTitle != firstMessage ? legacyTitle : nil) ?? SessionTitle.unnamed(id)
                        var row: JSONObject = [
                            "id": id, "title": title, "rollout_path": text(2),
                            "archived": sqlite3_column_int(statement, 3) != 0,
                            "updatedAt": sqlite3_column_double(statement, 4), "catalogued": true,
                        ]
                        for (offset, key) in extraKeys.enumerated() {
                            let value = text(Int32(7 + offset))
                            if !value.isEmpty {
                                row[key] =
                                    key == "source"
                                    ? ((try? JSONSerialization.jsonObject(with: Data(value.utf8))) ?? value)
                                    : (key == "tokens_used" ? (Double(value) ?? 0) : value)
                            }
                        }
                        if row["parent_thread_id"] == nil, let edge = spawnEdge(db: db, child: id) {
                            row["parent_thread_id"] = edge
                        }
                        result.append(row)
                        status = sqlite3_step(statement)
                    }
                    if status == SQLITE_DONE { rows = result }
                    else { transientFailure = true }
                }
                sqlite3_finalize(statement)
            }
            sqlite3_close(db)
        }
        if transientFailure {
            if !catalog.isEmpty { catalogAt = now; return catalog }
            catalog = []; pageIndex = index; catalogAt = now; return catalog
        }
        if rows == nil {
            rows = []
            for directory in ["sessions", "archived_sessions"] {
                if let files = fm.enumerator(
                    at: root.appendingPathComponent(directory),
                    includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
                {
                    for case let file as URL in files
                    where (file.pathExtension == "jsonl" || file.lastPathComponent.hasSuffix(".jsonl.zst"))
                        && logs.safeLog(file)
                    {
                        let regex = try! NSRegularExpression(pattern: "[a-fA-F0-9]{8}-[0-9a-fA-F-]{27,}")
                        let name = file.lastPathComponent, range = NSRange(name.startIndex..., in: name)
                        let match = regex.firstMatch(in: name, range: range).flatMap { Range($0.range, in: name) }
                        let id = match.map { String(name[$0]) } ?? name
                        let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                        rows?.append([
                            "id": id, "title": titles[id] ?? SessionTitle.unnamed(id),
                            "rollout_path": file.path, "archived": false,
                            "updatedAt": (date?.timeIntervalSince1970 ?? 0) * 1000,
                        ])
                    }
                }
            }
        }
        catalog = (rows ?? []).filter { row in
            guard let path = row["rollout_path"] as? String else { return false }
            return logs.safeLog(URL(fileURLWithPath: path)) || logs.safeLog(URL(fileURLWithPath: path + ".zst"))
        }.sorted { (number($0["updatedAt"]) ?? 0) > (number($1["updatedAt"]) ?? 0) }
        pageIndex = index
        catalogAt = now
        return catalog
    }

    func branch(for id: String, primary: String?) -> RolloutPages {
        func canonical(_ path: String) -> URL {
            URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        }
        var candidates = (pageIndex[id] ?? []).map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        if let primary {
            for path in [primary, primary + ".zst"] {
                let url = canonical(path)
                if logs.safeLog(url) && !candidates.contains(url) { candidates.append(url) }
            }
        }
        candidates = candidates.filter {
            logs.safeLog($0) && FileManager.default.fileExists(atPath: $0.path)
        }
        candidates.sort { $0.lastPathComponent < $1.lastPathComponent }
        var primaryURL: URL?
        if let primary {
            let candidate = canonical(
                FileManager.default.fileExists(atPath: primary) ? primary : primary + ".zst")
            if logs.safeLog(candidate) && FileManager.default.fileExists(atPath: candidate.path) {
                primaryURL = candidate
            }
        }
        var byPageID = [String: URL]()
        var deduped = [URL]()
        for url in candidates {
            let pid = Self.pageID(for: url)
            if let existing = byPageID[pid] {
                let keepNew = (url == primaryURL)
                    || (existing != primaryURL && !url.lastPathComponent.hasSuffix(".zst")
                        && existing.lastPathComponent.hasSuffix(".zst"))
                if keepNew {
                    byPageID[pid] = url
                    if let idx = deduped.firstIndex(of: existing) { deduped[idx] = url }
                }
            } else {
                byPageID[pid] = url
                deduped.append(url)
            }
        }
        candidates = deduped
        let signature = (primaryURL?.path ?? "") + "::" + candidates.map(\.path).joined(separator: "|")
        if let cached = pageBranches[id], cached.signature == signature { return cached }
        var resolved = RolloutPages(signature: signature)
        guard candidates.count > 1 else {
            resolved.slices = candidates.map { LogPageSlice(url: $0) }
            pageBranches[id] = resolved
            return resolved
        }
        var headers = [URL: RolloutPageHeader]()
        for url in candidates { headers[url] = Self.pageHeader(url) }
        let tip = primaryURL.flatMap { url in candidates.contains(url) ? url : nil } ?? candidates.last!
        if headers[tip]?.parentPageID != nil {
            var chain = [LogPageSlice]()
            var visited = Set<URL>()
            var current: URL? = tip
            var cutoff: Int? = nil
            while let page = current, !visited.contains(page) {
                visited.insert(page)
                chain.append(LogPageSlice(url: page, endOrdinalExclusive: cutoff))
                if let parentID = headers[page]?.parentPageID, let parentURL = byPageID[parentID],
                    parentURL != page
                {
                    cutoff = headers[page]?.endOrdinalExclusive
                    current = parentURL
                } else {
                    break
                }
            }
            resolved.slices = chain.reversed()
            resolved.droppedRevisions = candidates.filter { !visited.contains($0) }
        } else {
            var heads = [URL](), continuations = [URL]()
            for url in candidates {
                if (headers[url]?.firstOrdinal ?? -1) > 0 { continuations.append(url) }
                else { heads.append(url) }
            }
            let chosenHead = primaryURL.flatMap { url in heads.first { $0.path == url.path } } ?? heads.last
            var keptContinuations = continuations
            if let primaryURL, let chosenHead, chosenHead.path == primaryURL.path {
                keptContinuations = continuations.filter {
                    $0.lastPathComponent > chosenHead.lastPathComponent
                }
            }
            let chosen = (chosenHead.map { [$0] } ?? []) + keptContinuations
            let chosenSet = Set(chosen)
            resolved.slices = chosen.map { LogPageSlice(url: $0) }
            resolved.droppedRevisions = candidates.filter { !chosenSet.contains($0) }
        }
        pageBranches[id] = resolved
        return resolved
    }

    private static let pageNamePattern = try! NSRegularExpression(
        pattern: "^rollout-.*?([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(?:_([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}))?$")

    private static func pageID(for url: URL) -> String {
        var name = url.lastPathComponent
        if name.hasSuffix(".zst") { name = String(name.dropLast(4)) }
        if name.hasSuffix(".jsonl") { name = String(name.dropLast(6)) }
        let range = NSRange(name.startIndex..., in: name)
        if let match = pageNamePattern.firstMatch(in: name, range: range) {
            let group = match.range(at: 2).location != NSNotFound ? 2 : 1
            if let idRange = Range(match.range(at: group), in: name) {
                return String(name[idRange]).lowercased()
            }
        }
        return name.lowercased()
    }

    private static func pageHeader(_ file: URL) -> RolloutPageHeader {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return RolloutPageHeader() }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 65536)) ?? Data()
        var text = String(decoding: prefix, as: UTF8.self)
        if LogDecoding.encoding(of: prefix) == .zstd {
            guard let inflated = try? inflatePrefix(file) else { return RolloutPageHeader() }
            text = inflated
        }
        guard let line = text.split(separator: "\n", omittingEmptySubsequences: true).first,
            let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? JSONObject
        else { return RolloutPageHeader() }
        var header = RolloutPageHeader(firstOrdinal: Int(number(object["ordinal"]) ?? -1))
        if object["type"] as? String == "session_meta" {
            let payload = jsonObject(object["payload"])
            let base = jsonObject(payload["history_base"])
            header.parentPageID = structuralText(base["thread_id"])?.lowercased()
            header.endOrdinalExclusive = nonnegative(base["end_ordinal_exclusive"]).map { Int($0) }
        }
        return header
    }

    private static func inflatePrefix(_ file: URL) throws -> String {
        var text = ""
        _ = try LogDecoding.inflate(file: file, maxBytes: 65536) { chunk in
            if text.isEmpty { text = String(decoding: chunk, as: UTF8.self) }
        }
        return text
    }

    private func codexIndexedTitles() -> [String: String] {
        guard let index = try? String(contentsOf: root.appendingPathComponent("session_index.jsonl"), encoding: .utf8) else { return [:] }
        var titles = [String: String](), dates = [String: Date]()
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for line in index.split(separator: "\n") {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? JSONObject,
                let id = o["id"] as? String,
                let title = SessionTitle.nonempty(o["thread_name"]) ?? SessionTitle.nonempty(o["title"])
            else { continue }
            let stamp = o["updated_at"] as? String ?? ""
            let date = fractional.date(from: stamp) ?? plain.date(from: stamp)
            if let previous = dates[id] {
                guard let date, date >= previous else { continue }
            }
            titles[id] = title; dates[id] = date
        }
        return titles
    }

    private func spawnEdge(db: OpaquePointer?, child: String) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT parent_thread_id FROM thread_spawn_edges WHERE child_thread_id = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(statement, 1, child, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            return nil
        }
        return String(cString: text)
    }
}

final class CodexSessionReader: ProviderSessionReading {
    let logs: SessionLogStore
    private let rolloutCatalog: CodexRolloutCatalog
    private let aggregation = SessionAggregation()

    init(root: URL, cache: ParseCacheStore? = nil) {
        let store = SessionLogStore(root: root, provider: .codex, cache: cache) { CodexMetrics(sessionID: $0) }
        logs = store
        rolloutCatalog = CodexRolloutCatalog(logs: store)
    }

    func scan(selected: String?, now: Double) -> StatsSnapshot {
        let groups = rolloutCatalog.projectGroups()
        let rows = rolloutCatalog.entries(now: now)
        // Host-side identity resolves parents and ownership before any log is
        // read, so provably hidden history never costs a parse.
        var dbParent = [String: String](), dbChild = [String: Bool](), dbMeta = [String: JSONObject]()
        for meta in rows {
            let id = identifier(meta["id"])
            dbMeta[id] = meta
            dbParent[id] = UsageAccounting.parent(meta)
            dbChild[id] = UsageAccounting.isChild(meta)
        }
        var dbTaskKey = [String: String]()
        for id in dbMeta.keys {
            var current = id, visited = Set<String>(), valid = true
            while let parent = dbParent[current] {
                guard parent != current, !visited.contains(parent), dbMeta[parent] != nil else {
                    valid = false; break
                }
                visited.insert(current); current = parent
            }
            dbTaskKey[id] = valid ? current : id
        }
        let dbRoots = Set(
            dbMeta.filter { !dbChild[$0.key, default: false] && $0.value["archived"] as? Bool != true }
                .map(\.key))

        var agents = [JSONObject](), ledgers = [String: [JSONObject]](), livePaths = Set<String>()
        var ledgerVersions = [String: UsageLedgerVersion]()
        for meta in rows {
            let id = identifier(meta["id"])
            let hidden =
                meta["archived"] as? Bool == true
                && !(dbTaskKey[id].map { dbRoots.contains($0) } ?? false)
                // An unresolvable child may name an active parent inside its own
                // log, so only provably rooted history is skipped outright.
                && !(dbChild[id, default: false] && dbParent[id] == nil)
            let pages = hidden ? RolloutPages() : rolloutCatalog.branch(for: id, primary: meta["rollout_path"] as? String)
            let key = pages.slices.first?.url.path
            var loaded: JSONObject?, journal: UsageJournal?
            if let key, logs.safeLog(URL(fileURLWithPath: key)) {
                livePaths.insert(key)
                loaded = try? logs.load(pages.slices, now: now, sessionID: meta["catalogued"] as? Bool == true ? id : nil)
                journal = loaded == nil ? nil : logs.journal(at: URL(fileURLWithPath: key))
                if loaded != nil { ledgerVersions[id] = logs.version(at: URL(fileURLWithPath: key)) }
            }
            var facts = meta
            facts.merge(journal?.metadata ?? [:]) { old, new in new is NSNull ? old : new }
            let child = UsageAccounting.isChild(facts), parent = UsageAccounting.parent(facts)
            let isForked = structuralText(facts["forked_from_id"]) != nil || structuralText(facts["attached_thread_parent_id"]) != nil
            let inherited = isForked ? (journal?.inheritedTokens ?? 0) : 0
            let hostTokens: Any = nonnegative(facts["tokens_used"]).map { rawHost in
                loaded != nil && inherited > 0 ? max(0, rawHost - inherited) : rawHost
            } ?? jsonNull
            var row = loaded ?? [:]
            row.merge([
                "id": child ? "__agent__:" + id : id, "key": id, "sessionID": id, "agentID": id,
                "title": meta["title"] ?? SessionTitle.unnamed(id),
                "nickname": facts["agent_nickname"] ?? jsonNull, "agentRole": facts["agent_role"] ?? jsonNull,
                "group": groups.group(for: id),
                "project": usageProject(cwd: facts["cwd"], workspace: facts["project_id"]),
                "provider": "codex", "role": child ? "subagent" : "main", "parentID": nullable(parent),
                "archived": meta["archived"] ?? false, "loaded": true,
                "accountingMode": journal?.mode ?? "missing",
                "partial": loaded == nil || journal?.partial == true || (number(loaded?["malformedLines"]) ?? 0) > 0,
                "hostTokensUsed": hostTokens,
                "rolloutPages": Double(max(1, pages.slices.count)),
                "droppedRevisionPages": Double(pages.droppedRevisions.count),
                "updatedAt": meta["updatedAt"] ?? row["updatedAt"] ?? 0,
            ]) { _, new in new }
            if let journal, journal.mode == "cumulative" {
                UsageAccounting.apply(journal.cumulative ?? [:], to: &row)
            }
            if let journal, let cumulative = journal.cumulative, !journal.records.isEmpty,
                journal.requestTokens + inherited < (number(cumulative["totalTokens"]) ?? 0)
            {
                row["partial"] = true
            }
            ledgers[id] = journal?.values ?? []
            agents.append(row)
        }
        let known = Dictionary(agents.map { (identifier($0["key"]), $0) }, uniquingKeysWith: { $1 })
        for i in agents.indices {
            var current = identifier(agents[i]["key"]), visited = Set<String>(), valid = true
            while let parent = structuralText(known[current]?["parentID"]) {
                guard parent != current, !visited.contains(parent), known[parent] != nil else {
                    valid = false; break
                }
                visited.insert(current); current = parent
            }
            let child = agents[i]["role"] as? String == "subagent"
            if child && structuralText(agents[i]["parentID"]) == nil { valid = false }
            agents[i]["taskKey"] = valid ? current : identifier(agents[i]["key"])
            if valid { agents[i]["group"] = groups.group(for: current) }
            agents[i]["relationship"] = child ? (valid ? "recorded" : "unknown") : "root"
            if !valid { agents[i]["parentID"] = jsonNull }
        }
        let activeRoots = Set(
            agents.filter { $0["role"] as? String == "main" && $0["archived"] as? Bool != true }
                .map { identifier($0["key"]) })
        agents = agents.filter {
            $0["archived"] as? Bool != true || activeRoots.contains(identifier($0["taskKey"]))
        }
        logs.finishScan(livePaths: livePaths)
        return aggregation.aggregate(agents: agents, ledgers: ledgers, versions: ledgerVersions)
            .snapshot(provider: .codex, now: now, groups: groups)
    }
}
