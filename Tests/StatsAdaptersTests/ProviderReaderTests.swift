@testable import StatsCore
@testable import StatsAdapters
import Foundation

enum ProviderReaderTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("provider-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        func write(_ object: JSONObject, to file: URL, append: Bool = false) throws {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var bytes = append ? try Data(contentsOf: file) : Data()
            bytes.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])); bytes.append(10)
            try bytes.write(to: file)
        }
        func bytes(_ snapshot: StatsSnapshot) throws -> Data {
            try JSONSerialization.data(withJSONObject: snapshot.legacyJSON, options: [.sortedKeys])
        }
        for provider in StatsProvider.allCases {
            let root = base.appendingPathComponent(provider.rawValue)
            let cache = base.appendingPathComponent("\(provider.rawValue)-cache.json")
            let session = "00000000-0000-0000-0000-000000000001"
            let log: URL
            let usage: JSONObject
            if provider == .kimi {
                let folder = root.appendingPathComponent("sessions/workspace/\(session)")
                try write(["title": "Session", "cwd": "/synthetic"], to: folder.appendingPathComponent("state.json"))
                log = folder.appendingPathComponent("agents/main/wire.jsonl")
                usage = ["type": "usage.record", "requestId": "request-1", "time": 10,
                         "usage": ["inputOther": 10, "inputCacheRead": 2, "output": 3]]
                try write(usage, to: log)
            } else {
                log = root.appendingPathComponent("sessions/rollout-\(session).jsonl")
                try write(["type": "session_meta", "payload": ["id": session, "cwd": "/synthetic"]], to: log)
                usage = ["type": "token_usage_record", "timestamp": "2026-01-01T00:00:00Z",
                         "payload": ["response_id": "request-1", "usage": ["input_tokens": 12, "cached_input_tokens": 2, "output_tokens": 3]]]
                try write(usage, to: log, append: true)
            }
            let direct: ProviderSessionReading = provider == .kimi
                ? KimiSessionReader(root: root) : CodexSessionReader(root: root)
            let initial = direct.scan(selected: nil, now: 10000)
            let facade = SessionReader(root: root, provider: provider)
            check(try bytes(initial) == bytes(facade.scan(selected: session, now: 10000)),
                  "the facade and direct provider reader have identical collection semantics")
            check(initial.provider == provider && initial.sessions.count == 1 && initial.agents.count == 1,
                  "each provider reports its own typed identities")
            check(initial.sessions[0].statistics.usage.totalTokens.value == 15,
                  "both providers preserve the existing non-overlapping usage buckets")
            let readBytes = direct.logs.parsedBytes
            _ = direct.scan(selected: "missing-selection", now: 10000)
            check(readBytes > 0 && direct.logs.parsedBytes == readBytes,
                  "selection changes never replay unchanged logs or omit project accounting")

            weak var releasedLogs: SessionLogStore?
            do {
                let reader: ProviderSessionReading = provider == .kimi
                    ? KimiSessionReader(root: root, cache: ParseCacheStore(path: cache))
                    : CodexSessionReader(root: root, cache: ParseCacheStore(path: cache))
                releasedLogs = reader.logs
                _ = reader.scan(selected: nil, now: 10000)
                var next = usage
                if provider == .kimi { next["requestId"] = "request-2" }
                else { var payload = jsonObject(next["payload"]); payload["response_id"] = "request-2"; next["payload"] = payload }
                try write(next, to: log, append: true)
                check(reader.scan(selected: nil, now: 16000).sessions[0].statistics.usage.totalTokens.value == 30,
                      "appended records update the same provider instance exactly once")
                // This second scan is inside the 60-second flush debounce. Releasing
                // the reader must free its logs and flush the still-dirty cache.
            }
            check(releasedLogs == nil, "metrics factories must not retain the shared log store")
            let restored = SessionReader(root: root, provider: provider, cache: ParseCacheStore(path: cache))
            let resumed = restored.scan(selected: nil, now: 16000)
            check(restored.restoredLogs == 1 && restored.parsedBytes == 0,
                  "reader release persists unflushed appends and permits a zero-byte restore")
            let cold = SessionReader(root: root, provider: provider).scan(selected: nil, now: 16000)
            check(try bytes(resumed) == bytes(cold), "the typed cached result equals a complete cold scan")
            check(cold.sessions[0].statistics.usage.totalTokens.value == 30, "cache restoration preserves the new total")
        }
        print("\(checks) provider reader boundary checks passed")
    }
}
