import Foundation
import StatsCore

// A journal of accounting metadata, separate from display/timing metrics.
// Completion summaries and context measurements are deliberately not sources.
final class UsageJournal {
    private static let fractionalTrim = try! NSRegularExpression(pattern: "\\.([0-9]{3})[0-9]+")
    private let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let plain = ISO8601DateFormatter()
    let provider: String, fileIdentity: String, agentID: String
    private(set) var records=[String:JSONObject]()
    private var order=[String](), occurrences=[String:Int]()
    private var sessionMetadata: CodexSessionMetadata
    var metadata: JSONObject { sessionMetadata.values }
    private(set) var cumulative: JSONObject?, cumulativeTime: Double?, partial=false
    private(set) var currentModel: String?
    private var turnModels = [String: String]()
    private var origin: String?
    private var cachedValues: [JSONObject]?
    private(set) var requestTokens = 0.0
    private(set) var inheritedTokens = 0.0
    init(provider:String,fileIdentity:String,agentID:String,sessionID:String?=nil){self.provider=provider;self.fileIdentity=fileIdentity;self.agentID=agentID;sessionMetadata=CodexSessionMetadata(sessionID:sessionID)}
    private func parseTimestamp(_ value: Any?) -> Double? {
        if let n = nonnegative(value) { return n }
        guard let stamp = value as? String, !stamp.isEmpty else { return nil }
        let msStamp = Self.fractionalTrim.stringByReplacingMatches(
            in: stamp, range: NSRange(stamp.startIndex..., in: stamp), withTemplate: ".$1")
        return (fractional.date(from: msStamp) ?? plain.date(from: msStamp)).map {
            ($0.timeIntervalSince1970 * 1000).rounded()
        }
    }
    func accept(_ object: JSONObject) {
        let type=object["type"] as? String ?? "", p=jsonObject(object["payload"])
        if provider == "kimi",type == "metadata",origin == nil { origin=object["created_at"].map { String(describing:$0) } }
        if provider == "kimi" {
            if type == "profile.bind", let m = structuralText(object["modelAlias"]) {
                currentModel = m
            } else if type == "llm.request", object["kind"] as? String == "loop",
                      let m = structuralText(object["modelAlias"]) ?? structuralText(object["model"]) {
                currentModel = m
            }
        }
        if provider == "codex",type == "session_meta" {
            sessionMetadata.accept(p)
            // Keep copied-record provenance separate from the owning identity:
            // anonymous inherited requests must still deduplicate across forks.
            origin=structuralText(p["id"]) ?? origin
        }
        if provider == "codex",type == "turn_context" {
            if let m = structuralText(p["model"]) {
                currentModel = m
                if let tid = structuralText(p["turn_id"]) { turnModels[tid] = m }
            }
        }
        if provider == "codex",type == "event_msg",p["type"] as? String == "token_count" {
            if let u=jsonObject(p["info"])["total_token_usage"] as? JSONObject {
                cumulative=buckets(u)
                cumulativeTime = parseTimestamp(object["timestamp"]) ?? cumulativeTime
            }
            return
        }
        guard type == (provider == "kimi" ? "usage.record":"token_usage_record") else{return}
        let event=provider == "kimi" ? object:p
        guard var row=buckets(jsonObject(event["usage"])) else{partial=true;return}
        let explicit=["response_id","request_id","responseId","requestId"].compactMap { structuralText(event[$0]) }.first
        let recordedAgent=structuralText(event["agentId"]) ?? agentID
        let values: [Any]=[origin ?? fileIdentity,recordedAgent,object["time"] ?? object["timestamp"] ?? jsonNull,event["model"] ?? jsonNull,event["usageScope"] ?? jsonNull,event["usage"] ?? jsonNull]
        let encoded=(try? JSONSerialization.data(withJSONObject:values,options:[.sortedKeys])) ?? Data()
        let fingerprint=usageHash(String(data:encoded,encoding:.utf8) ?? "")
        occurrences[fingerprint,default:0] += 1
        let id=explicit.map { "request:"+$0 } ?? "event:\(fingerprint):\(occurrences[fingerprint]!)"
        if records[id] != nil { return }
        if provider == "codex", records.isEmpty,
           let threadTotal = nonnegative(jsonObject(event["thread_token_usage"])["total_tokens"]),
           let ownTotal = number(row["totalTokens"]), threadTotal > ownTotal
        {
            inheritedTokens = threadTotal - ownTotal
        }
        let resolvedTime: Double? = provider == "kimi" ? nonnegative(object["time"]) : parseTimestamp(object["timestamp"])
        let resolvedModel: String? = provider == "kimi"
            ? (structuralText(event["model"]) ?? currentModel)
            : (structuralText(event["model"]) ?? structuralText(event["turn_id"]).flatMap { turnModels[$0] } ?? currentModel)
        row["id"]=id;row["model"]=resolvedModel ?? jsonNull;row["time"]=nullable(resolvedTime)
        records[id]=row;order.append(id);cachedValues=nil
        requestTokens += number(row["totalTokens"]) ?? 0
    }
    private func buckets(_ u: JSONObject) -> JSONObject? {
        let kimi=provider == "kimi"
        guard let input=nonnegative(u[kimi ? "inputOther":"input_tokens"]),let output=nonnegative(u[kimi ? "output":"output_tokens"]) else{return nil}
        for key in [kimi ? "inputCacheRead":"cached_input_tokens",kimi ? "inputCacheCreation":"cache_write_input_tokens"] {
            if u[key] != nil && nonnegative(u[key]) == nil {partial=true;return nil}
        }
        let read=nonnegative(u[kimi ? "inputCacheRead":"cached_input_tokens"]) ?? 0
        let write=nonnegative(u[kimi ? "inputCacheCreation":"cache_write_input_tokens"]) ?? 0
        if !kimi && read+write>input {partial=true;return nil}
        return ["input":kimi ? input:max(0,input-read-write),"cacheRead":read,"cacheWrite":write,"output":output,"totalTokens":(kimi ? input+read+write:input)+output]
    }
    var values: [JSONObject] {
        if let cachedValues { return cachedValues }
        let values = order.compactMap { records[$0] }
        cachedValues = values
        return values
    }
    var mode: String { !records.isEmpty ? "requests":cumulative == nil ? "missing":"cumulative" }
    var cacheState: JSONObject? {
        ["schemaVersion": 3, "records":records, "order":order, "occurrences":occurrences, "sessionMetadata":sessionMetadata.cacheState,
         "cumulative":nullable(cumulative), "cumulativeTime":nullable(cumulativeTime), "currentModel":nullable(currentModel),
         "turnModels":turnModels, "partial":partial, "origin":nullable(origin), "requestTokens":requestTokens,
         "inheritedTokens":inheritedTokens]
    }
    func restore(_ state: JSONObject) -> Bool {
        guard number(state["schemaVersion"]) == 3,
              let records = state["records"] as? [String:JSONObject], let order = state["order"] as? [String],
              let occurrences = state["occurrences"] as? [String:Int],
              let turnModels = state["turnModels"] as? [String:String],
              let metadataState = state["sessionMetadata"] as? JSONObject else { return false }
        var restoredMetadata = sessionMetadata
        guard restoredMetadata.restore(metadataState) else { return false }
        self.records = records; self.order = order; self.occurrences = occurrences; sessionMetadata = restoredMetadata
        self.turnModels = turnModels
        currentModel = state["currentModel"] as? String
        cumulative = state["cumulative"] as? JSONObject
        cumulativeTime = nonnegative(state["cumulativeTime"])
        partial = state["partial"] as? Bool ?? false
        origin = state["origin"] as? String
        requestTokens = number(state["requestTokens"]) ?? 0
        inheritedTokens = nonnegative(state["inheritedTokens"]) ?? 0
        cachedValues = nil
        return true
    }
}

