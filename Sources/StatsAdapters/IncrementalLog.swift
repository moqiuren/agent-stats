import StatsCore
import Foundation
import CryptoKit

struct LogPageSlice: Equatable {
    var url: URL
    var endOrdinalExclusive: Int? = nil
}

// A log page set: one logical thread can span several rollout pages (a
// continuation page keeps running ordinals, a revision page restarts at zero),
// and every page shares one accumulator so request-level de-duplication works
// across pages. Text pages append incrementally; compressed pages are inflated
// whole whenever they change, because a zstd stream is only meaningful from its
// first frame. Any rewind re-reads every page in order so a warm scan always
// produces the same records as a cold scan.
final class IncrementalLog {
    private(set) var metrics: SessionMetrics
    private let factory: () -> SessionMetrics
    private let journalFactory: () -> UsageJournal?
    private(set) var journal: UsageJournal?
    private let identity = UUID()
    private let agentID: String
    private let sessionID: String?
    private var revision: UInt64 = 0
    var version: UsageLedgerVersion { UsageLedgerVersion(identity: identity, revision: revision) }
    // Bumped whenever the accumulators change, so a caller can persist only real work.
    var revisionValue: UInt64 { revision }
    // Bytes actually parsed from the files during the last read(). A restored page
    // whose fingerprints still match reads nothing, which is the point of the cache.
    private(set) var readBytes: UInt64 = 0

    // Digest of a fixed-length file prefix, used to reject a persisted state whose
    // file was rewritten in place. The hashed length travels with the digest so a
    // later append cannot change which bytes the digest covers.
    struct FileHead: Equatable { let digest: String; let count: Int }

    struct Page {
        var url: URL
        var endOrdinalExclusive: Int? = nil
        var encoding: LogEncoding?
        var offset: UInt64 = 0
        var inode: UInt64 = 0
        var modified: Date?
        var pending = Data()
        var dropping = false
        var tailOffset: UInt64 = .max
        var tailValue: String?
        var head: FileHead?
    }
    private var pages = [Page]()

    init(
        provider: String? = nil, fileIdentity: String = "", agentID: String = "main",
        sessionID: String? = nil, factory: @escaping () -> SessionMetrics
    ) {
        self.factory = factory; self.agentID = agentID; self.sessionID = sessionID
        metrics = factory()
        journalFactory = {
            provider.map { UsageJournal(provider: $0, fileIdentity: fileIdentity, agentID: agentID, sessionID: sessionID) }
        }
        journal = journalFactory()
    }

    func read(_ file: URL, now: Double) throws -> JSONObject {
        try read([LogPageSlice(url: file)], now: now)
    }

    func read(_ files: [URL], now: Double) throws -> JSONObject {
        try read(files.map { LogPageSlice(url: $0) }, now: now)
    }

    func read(_ slices: [LogPageSlice], now: Double) throws -> JSONObject {
        readBytes = 0
        // A different page set or slice cutoff is structural: only a full replay of
        // every page can keep the shared accumulators identical to a cold parse.
        if slices != pages.map({ LogPageSlice(url: $0.url, endOrdinalExclusive: $0.endOrdinalExclusive) }) {
            pages = slices.map { Page(url: $0.url, endOrdinalExclusive: $0.endOrdinalExclusive) }
            rewind()
        }
        struct Facts { var size: UInt64; var inode: UInt64; var modified: Date? }
        var facts = [Facts]()
        for page in pages {
            let attrs = try FileManager.default.attributesOfItem(atPath: page.url.path)
            facts.append(
                Facts(
                    size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
                    inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                    modified: attrs[.modificationDate] as? Date))
        }
        for index in pages.indices where pages[index].encoding == nil {
            pages[index].encoding = LogDecoding.encoding(at: pages[index].url)
        }
        var needsReplay = false
        for index in pages.indices {
            // Size, mtime and inode catch truncation, append and replacement. A
            // same-size in-place rewrite that also restores mtime is only rejected by
            // the head/tail digests on a cold restore; a warm scan trusts these
            // attributes to avoid re-reading every unchanged log every tick.
            let invalid =
                facts[index].size < pages[index].offset
                || (facts[index].size == pages[index].offset && pages[index].modified != nil
                    && facts[index].modified != pages[index].modified)
                || pages[index].inode != facts[index].inode
            // A compressed page is only parseable as a whole stream, so any growth
            // replays it from the first frame and, with it, every sibling page.
            if invalid || (pages[index].encoding == .zstd && pages[index].offset < facts[index].size) {
                needsReplay = true
            }
        }
        if needsReplay { rewind() }
        for index in pages.indices {
            let size = facts[index].size
            pages[index].inode = facts[index].inode
            if pages[index].head == nil { pages[index].head = Self.fileHead(pages[index].url) }
            switch pages[index].encoding ?? .text {
            case .zstd:
                if pages[index].offset < size {
                    // Compressed pages restart from the first frame on every change.
                    let target = pages[index].url
                    pages[index].offset = 0
                    let consumed = try LogDecoding.inflate(file: target) { [self] chunk in
                        consume(chunk, page: index)
                    }
                    pages[index].offset = size
                    readBytes += consumed
                    revision &+= 1
                }
            case .unsupported:
                throw LogDecodingError.corruptStream("unsupported log encoding")
            case .text:
                if pages[index].offset < size { try readTail(page: index, upTo: size) }
            }
            pages[index].modified = facts[index].modified
            if pages[index].tailOffset != pages[index].offset {
                pages[index].tailOffset = pages[index].offset
                pages[index].tailValue = Self.tailDigest(pages[index].url, endingAt: pages[index].offset)
            }
        }
        return metrics.snapshot(now: now)
    }

    // Every rewind starts the shared accumulators over, so a replayed page set
    // can never double count a sample, span or call index.
    private func rewind() {
        metrics = factory(); journal = journalFactory()
        for index in pages.indices {
            pages[index].offset = 0; pages[index].pending = Data(); pages[index].dropping = false
            pages[index].tailOffset = .max; pages[index].tailValue = nil
        }
        revision &+= 1
    }

    private func readTail(page index: Int, upTo size: UInt64) throws {
        let handle = try FileHandle(forReadingFrom: pages[index].url); defer { try? handle.close() }
        try handle.seek(toOffset: pages[index].offset)
        while pages[index].offset < size {
            let bytes = try handle.read(upToCount: Int(min(262144, size - pages[index].offset))) ?? Data()
            if bytes.isEmpty { break }
            pages[index].offset += UInt64(bytes.count); readBytes += UInt64(bytes.count)
            revision &+= 1
            consume(bytes, page: index)
        }
    }

    // Consume complete lines with a cursor and trim the buffer once per chunk.
    // Removing every line from the front would shift all remaining bytes for
    // each of them, which is quadratic in the size of a cold full-file read.
    private func consume(_ bytes: Data, page index: Int) {
        pages[index].pending.append(bytes)
        var consumed = pages[index].pending.startIndex
        while let end = pages[index].pending[consumed...].firstIndex(of: 10) {
            let line = pages[index].pending[consumed..<end]; consumed = pages[index].pending.index(after: end)
            if pages[index].dropping { pages[index].dropping = false; continue }
            if line.allSatisfy({ [9, 13, 32].contains($0) }) { continue }
            if let object = (try? JSONSerialization.jsonObject(with: line)) as? JSONObject {
                if let limit = pages[index].endOrdinalExclusive, let ordinal = number(object["ordinal"]),
                    Int(ordinal) >= limit
                {
                    continue
                }
                metrics.accept(object); journal?.accept(object)
            } else { metrics.issues += 1 }
        }
        if consumed > pages[index].pending.startIndex {
            pages[index].pending.removeSubrange(..<consumed)
        }
        // A corrupt or unbounded line must not grow the resident process indefinitely.
        if pages[index].pending.count > 16 * 1024 * 1024 {
            pages[index].pending.removeAll(keepingCapacity: false)
            if !pages[index].dropping { metrics.issues += 1 }
            pages[index].dropping = true
        }
    }

    // A restorable entry carries the constructor identity, every page's identity
    // and both accumulators. The head and tail digests pin the bytes the parse
    // depends on: a matching prefix proves the log was only appended to, so the
    // tail can be read from the stored offset. Without a validated identity
    // nothing is persisted.
    var cacheEntry: JSONObject? {
        guard let metricsState = metrics.cacheState else { return nil }
        var pagesOut = [JSONObject]()
        for page in pages {
            guard let head = page.head, let tailValue = page.tailValue, let encoding = page.encoding else {
                return nil
            }
            var item: JSONObject = [
                "path": page.url.path, "encoding": encoding.rawValue, "offset": page.offset,
                "inode": page.inode, "head": head.digest, "headBytes": head.count, "tail": tailValue,
                "dropping": page.dropping,
            ]
            if let limit = page.endOrdinalExclusive { item["endOrdinalExclusive"] = limit }
            if !page.pending.isEmpty { item["pending"] = page.pending.base64EncodedString() }
            pagesOut.append(item)
        }
        guard !pagesOut.isEmpty else { return nil }
        var entry: JSONObject = ["agentID": agentID, "sessionID": nullable(sessionID), "pages": pagesOut]
        if let journal {
            guard let journalState = journal.cacheState else { return nil }
            entry["journal"] = journalState
        }
        entry["metrics"] = metricsState
        return entry
    }

    @discardableResult func restore(_ entry: JSONObject, at file: URL) -> Bool {
        restore(entry, at: [LogPageSlice(url: file)])
    }

    @discardableResult func restore(_ entry: JSONObject, at files: [URL]) -> Bool {
        restore(entry, at: files.map { LogPageSlice(url: $0) })
    }

    @discardableResult func restore(_ entry: JSONObject, at slices: [LogPageSlice]) -> Bool {
        // A legacy entry is single-page: its page identity lives on the entry.
        let legacy = entry["pages"] == nil
        let storedPages: [JSONObject]
        if let list = entry["pages"] as? [JSONObject], !list.isEmpty {
            storedPages = list
        } else if entry["offset"] != nil, let first = slices.first {
            storedPages = [entry.merging(["path": first.url.path]) { _, new in new }]
        } else {
            return false
        }
        guard storedPages.count == slices.count else { return false }
        // Validate everything before mutating, so a rejected state leaves no partial trace.
        var restored = [Page]()
        for (index, item) in storedPages.enumerated() {
            let slice = slices[index]
            let file = slice.url
            let storedLimit = number(item["endOrdinalExclusive"]).map { Int($0) }
            guard item["path"] as? String == file.path,
                storedLimit == slice.endOrdinalExclusive,
                let storedHead = item["head"] as? String,
                let headBytes = number(item["headBytes"]), headBytes > 0, headBytes <= 1_048_576,
                let computedHead = Self.fileHead(file, limit: Int(headBytes)),
                computedHead.count == Int(headBytes), computedHead.digest == storedHead
            else { return false }
            let encoding = LogDecoding.encoding(of: Self.filePrefix(file, count: 8))
            if let storedEncoding = item["encoding"] as? String {
                guard storedEncoding == encoding.rawValue else { return false }
            } else {
                // A legacy entry predates encoding tracking; only clean text state
                // may resume, since compressed pages used to parse as garbage.
                guard encoding == .text else { return false }
            }
            guard legacy ? item["agentID"] as? String == agentID : true,
                legacy ? item["sessionID"] as? String == sessionID : true,
                let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                let fileInode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
                // Keep the attribute's own Date: rebuilding it from a Double seconds
                // round trip can differ by one ULP, which would fail read()'s exact
                // mtime comparison and silently re-parse the whole log.
                let fileModified = attrs[.modificationDate] as? Date,
                UInt64(max(0, number(item["inode"]) ?? -1)) == fileInode,
                let storedOffset = number(item["offset"]), storedOffset >= 0,
                let storedTail = item["tail"] as? String,
                let fileSize = (attrs[.size] as? NSNumber)?.uint64Value,
                UInt64(storedOffset) <= fileSize,
                Self.tailDigest(file, endingAt: UInt64(storedOffset)) == storedTail
            else { return false }
            var page = Page(url: file, endOrdinalExclusive: slice.endOrdinalExclusive, encoding: encoding)
            page.head = computedHead
            page.offset = UInt64(storedOffset); page.inode = fileInode; page.modified = fileModified
            page.tailOffset = page.offset; page.tailValue = storedTail
            page.dropping = item["dropping"] as? Bool ?? false
            page.pending = (item["pending"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
            restored.append(page)
        }
        guard entry["agentID"] as? String == agentID, entry["sessionID"] as? String == sessionID,
            let metricsState = entry["metrics"] as? JSONObject, let journal,
            let journalState = entry["journal"] as? JSONObject
        else { return false }
        // Validate both accumulators before committing either, so a rejected entry
        // leaves a fresh log rather than half of a previous parse.
        guard journal.restore(journalState), metrics.restore(metricsState) else {
            metrics = factory(); self.journal = journalFactory()
            return false
        }
        pages = restored
        revision &+= 1
        return true
    }

    static func fileHead(_ file: URL, limit: Int = 4096) -> FileHead? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit) else { return nil }
        return FileHead(digest: digest(data), count: data.count)
    }

    private static func filePrefix(_ file: URL, count: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: count)) ?? Data()
    }

    // Digest of the final bytes before the stored offset: unchanged by an append and
    // changed by any in-place rewrite that ends where the log previously ended.
    static func tailDigest(_ file: URL, endingAt offset: UInt64, limit: UInt64 = 4096) -> String? {
        guard offset > 0 else { return digest(Data()) }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let start = offset > limit ? offset - limit : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.read(upToCount: Int(offset - start)) else { return nil }
        return digest(data)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }
}
