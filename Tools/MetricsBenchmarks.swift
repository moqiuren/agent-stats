import StatsCore
import StatsAdapters
import Foundation
import Dispatch

@main enum MetricsBenchmarks {
    static var checksum = 0.0

    static func measure(_ run: () -> JSONObject) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = run()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        checksum += number(result["totalTokens"]) ?? Double((result["sessions"] as? [JSONObject])?.count ?? 0)
        return elapsed
    }

    static func report(_ value: JSONObject) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    static func event(_ type: String, _ payload: JSONObject, end: Bool = false) -> JSONObject {
        var payload = payload
        payload["type"] = type
        return ["type": "event_msg", "payload": payload,
                "timestamp": end ? "2026-10-06T00:00:10.000Z" : "2026-10-06T00:00:00.000Z"]
    }

    static func main() throws {
        for count in [100, 300, 1000] {
            let metrics = CodexMetrics()
            for i in 0..<count {
                let id = "t\(i)"
                metrics.accept(event("task_started", ["turn_id": id]))
                metrics.accept(event("item_completed", ["turn_id": id,
                    "item": ["id": "m\(i)", "type": "AgentMessage", "phase": "final_answer"],
                    "started_at_ms": 1000, "completed_at_ms": 9000]))
                metrics.accept(["type": "response_item", "payload": ["type": "function_call", "call_id": "c\(i)"],
                                "timestamp": "2026-10-06T00:00:01.000Z"])
                metrics.accept(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "c\(i)"],
                                "timestamp": "2026-10-06T00:00:02.000Z"])
                metrics.accept(["type": "token_usage_record", "payload": ["turn_id": id, "response_id": "r\(i)",
                    "usage": ["input_tokens": 100, "output_tokens": 20]], "timestamp": "2026-10-06T00:00:09.000Z"])
                metrics.accept(event("task_complete", ["turn_id": id, "duration_ms": 10000], end: true))
            }
            _ = metrics.snapshot(now: 1_800_000_000_000)
            for changed in [false, true] {
                let times = (0..<3).map { _ in measure {
                    if changed { metrics.accept(["type": "session_meta", "payload": ["source": "vscode"]]) }
                    return metrics.snapshot(now: 1_800_000_000_000)
                }}.sorted()
                try report(["case": changed ? "codex_changed_snapshot" : "codex_unchanged_snapshot",
                            "turns": count, "median_ms": times[1], "samples_ms": times])
            }
        }

        let base = URL(fileURLWithPath: CommandLine.arguments[1])
        for count in [20, 100, 300] {
            let root = base.appendingPathComponent("kimi-\(count)")
            for session in 0..<count {
                let folder = root.appendingPathComponent("sessions/workspace/session_\(session)")
                try FileManager.default.createDirectory(at: folder.appendingPathComponent("agents/main"), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: ["title": "Synthetic \(session)", "archived": false])
                    .write(to: folder.appendingPathComponent("state.json"))
                var log = Data()
                for request in 0..<100 {
                    let row: JSONObject = ["type": "usage.record", "requestId": "\(session)-\(request)", "time": request,
                                           "usage": ["inputOther": 10, "inputCacheRead": 20, "output": 30]]
                    log.append(try JSONSerialization.data(withJSONObject: row)); log.append(10)
                }
                try log.write(to: folder.appendingPathComponent("agents/main/wire.jsonl"))
            }
            #if LEGACY_COLLECTION
            let reader = SessionReader(root: root, provider: "kimi")
            func scan() -> JSONObject { reader.scan(selected: "session_0", now: 1_800_000_000_000) }
            #else
            let reader = SessionReader(root: root, provider: .kimi)
            func scan() -> JSONObject { reader.scan(selected: "session_0", now: 1_800_000_000_000).legacyJSON }
            #endif
            let cold = measure(scan)
            let times = (0..<3).map { _ in measure(scan) }.sorted()
            try report(["case": "kimi_unchanged_scan", "sessions": count, "requests": count * 100,
                        "cold_ms": cold, "median_ms": times[1], "samples_ms": times])
        }
        try report(["checksum": checksum])
    }
}
