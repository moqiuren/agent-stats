@testable import StatsCore
import Foundation

enum StatsSnapshotTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let large = 9_007_199_254_740_993
        let agent: JSONObject = ["id": "child", "key": "child-key", "sessionID": "session",
                                 "parentID": "main", "role": "subagent", "totalTokens": large,
                                 "cacheWrite": NSNull(), "tps": 2.5, "pendingQuestions": 0]
        let fields: JSONObject = ["id": "session", "title": "A\nB", "model": "model",
                                  "input": 0, "cacheRead": 3.0, "output": NSNull(), "totalTokens": large,
                                  "totalMs": 1000, "toolMs": 0.0, "contextTokens": NSNull(),
                                  "lastTurn": ["id": 0, "ttftMs": 0, "durationMs": NSNull(), "tps": 2.5],
                                  "updatedAt": 1_792_080_000_123, "partial": true, "archived": false,
                                  "agents": [agent], "backgroundItems": [["description": "Task", "startedAt": 123]],
                                  "group": ["id": "group", "title": "Group"]]
        let session = SessionSnapshot(fields)
        let statistics = session.statistics
        check(statistics.id == "session" && statistics.model == "model" && statistics.partial,
              "typed identity and completeness preserve source metadata")
        check(statistics.usage.input.value == 0 && statistics.usage.input.nativeValue is Int,
              "a measured zero remains a native integer")
        check(statistics.usage.totalTokens.nativeValue as? Int == large,
              "integers above Double's exact range survive without numeric or JSON round trips")
        if case .unknown = statistics.usage.output { checks += 1 } else { preconditionFailure("explicit unknown lost") }
        if case .absent = statistics.usage.cacheWrite { checks += 1 } else { preconditionFailure("absent field lost") }
        check(statistics.timing.totalMs.nativeValue is Int && statistics.timing.toolMs.nativeValue is Double,
              "native timing representations are retained")
        check(statistics.lastTurn?.timing.ttftMs.value == 0 && statistics.lastTurn?.legacyJSON["id"] as? Int == 0,
              "zero turn IDs and zero TTFT survive the nested typed boundary")
        check(session.agents?.first?.parentID == "main" && session.agents?.first?.role == "subagent",
              "child identities remain separate from their parent session")
        check(session.agents?.first?.statistics.usage.totalTokens.nativeValue as? Int == large,
              "nested agent usage keeps exact native counters")
        func bytes(_ value: JSONObject) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
        check(try bytes(session.legacyJSON) == bytes(fields), "the valid session compatibility payload is byte-identical")
        check(try bytes(AgentSnapshot(agent).legacyJSON) == bytes(agent), "the agent payload is lossless")
        check(try bytes(ProjectSnapshot(fields).legacyJSON) == bytes(fields), "project totals preserve nested agents and metadata")
        for raw: Any in [true, false, Double.infinity, Double.nan, "12"] {
            if case .unknown = MetricValue(raw) { checks += 1 } else { preconditionFailure("invalid measurement accepted") }
        }
        let unsigned = MetricValue(UInt64.max)
        check(unsigned.nativeValue as? UInt64 == UInt64.max, "unsigned values are not truncated")
        for raw: JSONObject in [[:], ["lastTurn": NSNull(), "agents": NSNull()], ["agents": [] as [JSONObject]]] {
            check(try bytes(SessionSnapshot(raw).legacyJSON) == bytes(raw), "missing, null and empty arrays stay distinct")
        }
        let snapshot = StatsSnapshot(provider: .kimi, collectedAt: 1_792_080_000_123,
                                     sessions: [session], agents: [AgentSnapshot(agent)],
                                     projects: [ProjectSnapshot(fields)],
                                     groups: [SessionGroupSnapshot(["id": "group", "title": "Group"])],
                                     coverageNote: "recorded only")
        let envelope = snapshot.legacyJSON
        check(snapshot.provider == .kimi && number(envelope["time"]) == 1_792_080_000_123,
              "provider identity and millisecond timestamps travel with the result")
        check(number(envelope["version"]) == 5 && envelope["coverageNote"] as? String == "recorded only",
              "CLI schema version and accounting boundary stay compatible")
        print("\(checks) typed collection snapshot checks passed")
    }
}
