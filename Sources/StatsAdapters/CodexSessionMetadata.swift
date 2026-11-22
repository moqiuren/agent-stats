import Foundation
import StatsCore

// Forked Codex rollouts contain the owner's header followed by session_meta
// records copied from ancestors. Only the owner may update its identity.
struct CodexSessionMetadata {
    private var sessionID: String?
    private(set) var values = JSONObject()
    init(sessionID: String? = nil) { self.sessionID = sessionID }
    mutating func accept(_ payload: JSONObject) {
        let id = (payload["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let sessionID, id != sessionID { return }
        if let id { sessionID = id }
        for key in ["id","cwd","source","thread_source","parent_thread_id","project_id","forked_from_id","agent_nickname","agent_role"] {
            if let value = payload[key] { values[key] = value }
        }
    }
    var isExcluded: Bool {
        ["subagent","guardian_review"].contains(values["thread_source"] as? String ?? "")
            || (values["source"] as? String ?? "").contains("subagent")
            || jsonObject(values["source"])["subagent"] != nil
    }
    var cacheState: JSONObject { ["sessionID": nullable(sessionID), "values": values] }
    mutating func restore(_ state: JSONObject) -> Bool {
        guard let values = state["values"] as? JSONObject else { return false }
        sessionID = state["sessionID"] as? String
        self.values = values
        return true
    }
}

