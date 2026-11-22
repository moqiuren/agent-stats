import StatsCore
import Foundation

// Shared incremental I/O and persistent parse cache. Provider readers own their
// metrics factory and metadata; this store never selects a provider algorithm.
final class SessionLogStore {
    let root: URL
    private let provider: StatsProvider
    private let makeMetrics: (String?) -> SessionMetrics
    private let parseCache: ParseCacheStore?
    private var cache = [String: IncrementalLog]()
    private var storedRevision = [String: UInt64]()
    private(set) var restoredLogs = 0
    private(set) var parsedBytes: UInt64 = 0

    init(root: URL, provider: StatsProvider, cache: ParseCacheStore?,
         makeMetrics: @escaping (String?) -> SessionMetrics) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.provider = provider; parseCache = cache; self.makeMetrics = makeMetrics
    }
    func journal(at file: URL) -> UsageJournal? { cache[file.path]?.journal }
    func version(at file: URL) -> UsageLedgerVersion? { cache[file.path]?.version }
    func finishScan(livePaths: Set<String>) {
        cache = cache.filter { livePaths.contains($0.key) }
        storedRevision = storedRevision.filter { cache[$0.key] != nil }
        parseCache?.removeAll(except: livePaths)
        parseCache?.flushIfDue(interval: 60)
    }
    func safeLog(_ url: URL) -> Bool {
        let path = FileManager.default.fileExists(atPath:url.path) ? url.standardizedFileURL.resolvingSymlinksInPath().path:url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
        return ["sessions","archived_sessions"].contains { path.hasPrefix(root.appendingPathComponent($0).path+"/") }
    }
    func load(_ url: URL, now: Double, agentID: String = "main", sessionID: String? = nil) throws -> JSONObject {
        try load([LogPageSlice(url: url)], now: now, agentID: agentID, sessionID: sessionID)
    }
    func load(_ urls: [URL], now: Double, agentID: String = "main", sessionID: String? = nil) throws -> JSONObject {
        try load(urls.map { LogPageSlice(url: $0) }, now: now, agentID: agentID, sessionID: sessionID)
    }
    // One logical log can span several rollout pages; they share one accumulator,
    // so the cache is keyed by the first (chronological) page of the set.
    func load(_ slices: [LogPageSlice], now: Double, agentID: String = "main", sessionID: String? = nil) throws -> JSONObject {
        guard let key = slices.first?.url.path else { return [:] }
        if cache[key] == nil {
            let log = IncrementalLog(provider: provider.rawValue, fileIdentity: key,
                                     agentID: agentID, sessionID: sessionID) { [makeMetrics] in makeMetrics(sessionID) }
            // A restored log continues from its stored offsets, so an unchanged page
            // set costs no parsing at all and a grown file only reads its new bytes.
            if let entry = parseCache?.entry(for: key), log.restore(entry, at: slices) { restoredLogs += 1 }
            cache[key] = log
        }
        let loaded = try cache[key]!.read(slices, now: now)
        parsedBytes += cache[key]!.readBytes
        // Persist only logs whose accumulators actually changed; rewriting an
        // unchanged multi-megabyte cache on every scan would be pure overhead.
        if let log = cache[key], storedRevision[key] != log.revisionValue, let entry = log.cacheEntry {
            parseCache?.store(key, entry)
            storedRevision[key] = log.revisionValue
        }
        return loaded
    }
}
