import Foundation

// The collection boundary distinguishes an absent measurement, an explicit
// unknown and a measured zero. Keep the native numeric representation; a JSON
// round trip or converting every Int into Double would weaken UI regressions.
package enum MetricValue {
  case absent, unknown
  case integer(Int)
  case unsigned(UInt64)
  case decimal(Double)

  package init(_ raw: Any?) {
    guard let raw else {
      self = .absent
      return
    }
    guard number(raw) != nil, let value = raw as? NSNumber else {
      self = .unknown
      return
    }
    switch String(cString: value.objCType) {
    case "f", "d": self = .decimal(value.doubleValue)
    case "Q": self = .unsigned(value.uint64Value)
    default: self = .integer(value.intValue)
    }
  }
  package var value: Double? {
    switch self {
    case .absent, .unknown: return nil
    case .integer(let value): return Double(value)
    case .unsigned(let value): return Double(value)
    case .decimal(let value): return value
    }
  }
  package var nativeValue: Any? {
    switch self {
    case .absent: return nil
    case .unknown: return jsonNull
    case .integer(let value): return value
    case .unsigned(let value): return value
    case .decimal(let value): return value
    }
  }
}

// Token counts retain the existing accounting buckets; cacheHit is a percentage.
package struct TokenUsage {
  package let input: MetricValue
  package let cacheRead: MetricValue
  package let cacheWrite: MetricValue
  package let output: MetricValue
  package let totalTokens: MetricValue
  package let cacheHit: MetricValue
  package let ownTokens: MetricValue
  package let sharedHistoryTokens: MetricValue
  package let observedRequestTokens: MetricValue
  package init(_ fields: JSONObject) {
    input = MetricValue(fields["input"])
    cacheRead = MetricValue(fields["cacheRead"])
    cacheWrite = MetricValue(fields["cacheWrite"])
    output = MetricValue(fields["output"])
    totalTokens = MetricValue(fields["totalTokens"])
    cacheHit = MetricValue(fields["cacheHit"])
    ownTokens = MetricValue(fields["ownTokens"])
    sharedHistoryTokens = MetricValue(fields["sharedHistoryTokens"])
    observedRequestTokens = MetricValue(fields["observedRequestTokens"])
  }
  fileprivate static let keys = [
    "input", "cacheRead", "cacheWrite", "output", "totalTokens", "cacheHit", "ownTokens",
    "sharedHistoryTokens", "observedRequestTokens",
  ]
  fileprivate func write(to fields: inout JSONObject) {
    fields["input"] = input.nativeValue
    fields["cacheRead"] = cacheRead.nativeValue
    fields["cacheWrite"] = cacheWrite.nativeValue
    fields["output"] = output.nativeValue
    fields["totalTokens"] = totalTokens.nativeValue
    fields["cacheHit"] = cacheHit.nativeValue
    fields["ownTokens"] = ownTokens.nativeValue
    fields["sharedHistoryTokens"] = sharedHistoryTokens.nativeValue
    fields["observedRequestTokens"] = observedRequestTokens.nativeValue
  }
}

// Durations are milliseconds; tps is tokens per second. No provider formula changes.
package struct TimingMetrics {
  package let tps: MetricValue
  package let avgTtftMs: MetricValue
  package let avgTurnMs: MetricValue
  package let ttftMs: MetricValue
  package let durationMs: MetricValue
  package let totalMs: MetricValue
  package let toolMs: MetricValue
  package let modelMs: MetricValue
  package let decodeMs: MetricValue
  package let reasoningMs: MetricValue
  package let llmMs: MetricValue
  package let firstTokenWaitMs: MetricValue
  package init(_ fields: JSONObject) {
    tps = MetricValue(fields["tps"])
    avgTtftMs = MetricValue(fields["avgTtftMs"])
    avgTurnMs = MetricValue(fields["avgTurnMs"])
    ttftMs = MetricValue(fields["ttftMs"])
    durationMs = MetricValue(fields["durationMs"])
    totalMs = MetricValue(fields["totalMs"])
    toolMs = MetricValue(fields["toolMs"])
    modelMs = MetricValue(fields["modelMs"])
    decodeMs = MetricValue(fields["decodeMs"])
    reasoningMs = MetricValue(fields["reasoningMs"])
    llmMs = MetricValue(fields["llmMs"])
    firstTokenWaitMs = MetricValue(fields["firstTokenWaitMs"])
  }
  fileprivate static let keys = [
    "tps", "avgTtftMs", "avgTurnMs", "ttftMs", "durationMs", "totalMs", "toolMs", "modelMs",
    "decodeMs", "reasoningMs", "llmMs", "firstTokenWaitMs",
  ]
  fileprivate func write(to fields: inout JSONObject) {
    fields["tps"] = tps.nativeValue
    fields["avgTtftMs"] = avgTtftMs.nativeValue
    fields["avgTurnMs"] = avgTurnMs.nativeValue
    fields["ttftMs"] = ttftMs.nativeValue
    fields["durationMs"] = durationMs.nativeValue
    fields["totalMs"] = totalMs.nativeValue
    fields["toolMs"] = toolMs.nativeValue
    fields["modelMs"] = modelMs.nativeValue
    fields["decodeMs"] = decodeMs.nativeValue
    fields["reasoningMs"] = reasoningMs.nativeValue
    fields["llmMs"] = llmMs.nativeValue
    fields["firstTokenWaitMs"] = firstTokenWaitMs.nativeValue
  }
}

package struct TurnSnapshot {
  package let timing: TimingMetrics
  private let metadata: JSONObject
  package init(_ fields: JSONObject) {
    timing = TimingMetrics(fields)
    metadata = fields.filter { !TimingMetrics.keys.contains($0.key) }
  }
  package var legacyJSON: JSONObject {
    var fields = metadata
    timing.write(to: &fields)
    return fields
  }
}

// Common data consumed by new features is typed. Provider-specific presentation
// metadata remains lossless in this compatibility adapter until the UI is migrated;
// it never substitutes for the canonical usage, timing or last-turn fields.
package struct StatisticsSnapshot {
  package let id: String?
  package let key: String?
  package let sessionID: String?
  package let title: String?
  package let model: String?
  package let partial: Bool
  package let archived: Bool
  package let usage: TokenUsage
  package let timing: TimingMetrics
  package let contextTokens: MetricValue
  package let lastTurn: TurnSnapshot?
  private let metadata: JSONObject

  package init(_ fields: JSONObject) {
    id = fields["id"] as? String
    key = fields["key"] as? String
    sessionID = fields["sessionID"] as? String
    title = fields["title"] as? String
    model = fields["model"] as? String
    partial = fields["partial"] as? Bool == true
    archived = fields["archived"] as? Bool == true
    usage = TokenUsage(fields)
    timing = TimingMetrics(fields)
    contextTokens = MetricValue(fields["contextTokens"])
    lastTurn = (fields["lastTurn"] as? JSONObject).map(TurnSnapshot.init)
    var remaining = fields
    for key in TokenUsage.keys + TimingMetrics.keys + ["contextTokens"] {
      remaining.removeValue(forKey: key)
    }
    if lastTurn != nil { remaining.removeValue(forKey: "lastTurn") }
    metadata = remaining
  }
  package var legacyJSON: JSONObject {
    var fields = metadata
    usage.write(to: &fields)
    timing.write(to: &fields)
    fields["contextTokens"] = contextTokens.nativeValue
    if let lastTurn { fields["lastTurn"] = lastTurn.legacyJSON }
    return fields
  }
}

package struct AgentSnapshot {
  package let statistics: StatisticsSnapshot
  package let parentID: String?
  package let role: String?
  package init(_ fields: JSONObject) {
    statistics = StatisticsSnapshot(fields)
    parentID = fields["parentID"] as? String
    role = fields["role"] as? String
  }
  package var legacyJSON: JSONObject { statistics.legacyJSON }
}

package struct SessionSnapshot {
  package let statistics: StatisticsSnapshot
  package let agents: [AgentSnapshot]?
  package init(_ fields: JSONObject) {
    agents = (fields["agents"] as? [JSONObject]).map { $0.map(AgentSnapshot.init) }
    var remaining = fields
    if agents != nil { remaining.removeValue(forKey: "agents") }
    statistics = StatisticsSnapshot(remaining)
  }
  package var legacyJSON: JSONObject {
    var fields = statistics.legacyJSON
    if let agents { fields["agents"] = agents.map(\.legacyJSON) }
    return fields
  }
}

package struct ProjectSnapshot {
  package let statistics: StatisticsSnapshot
  package let agents: [AgentSnapshot]?
  package init(_ fields: JSONObject) {
    agents = (fields["agents"] as? [JSONObject]).map { $0.map(AgentSnapshot.init) }
    var remaining = fields
    if agents != nil { remaining.removeValue(forKey: "agents") }
    statistics = StatisticsSnapshot(remaining)
  }
  package var legacyJSON: JSONObject {
    var fields = statistics.legacyJSON
    if let agents { fields["agents"] = agents.map(\.legacyJSON) }
    return fields
  }
}

package struct SessionGroupSnapshot {
  package let id: String
  package let title: String
  package init(_ fields: JSONObject) {
    id = identifier(fields["id"])
    title = identifier(fields["title"])
  }
  package var legacyJSON: JSONObject { ["id": id, "title": title] }
}

// Every collector returns this value directly. The provider travels with its data,
// so a consumer cannot accidentally label an old tool's results as the current one.
// collectedAt retains the existing milliseconds-since-epoch convention.
package struct StatsSnapshot {
  package let provider: StatsProvider
  package let collectedAt: Double
  package var sessions: [SessionSnapshot] = []
  package var agents: [AgentSnapshot] = []
  package var projects: [ProjectSnapshot] = []
  package var groups: [SessionGroupSnapshot] = []
  package var coverageNote: String = ""

  // Only the command-line/test boundary needs the original version-5 envelope.
  // NativeStatsService passes this struct to StatsUpdate without serializing it.
  package var legacyJSON: JSONObject {
    [
      "version": 5, "provider": provider.rawValue, "time": collectedAt,
      "sessions": sessions.map(\.legacyJSON), "agents": agents.map(\.legacyJSON),
      "projects": projects.map(\.legacyJSON), "sessionGroups": groups.map(\.legacyJSON),
      "coverageNote": coverageNote,
    ]
  }
  package init(
    provider: StatsProvider, collectedAt: Double, sessions: [SessionSnapshot] = [],
    agents: [AgentSnapshot] = [], projects: [ProjectSnapshot] = [],
    groups: [SessionGroupSnapshot] = [], coverageNote: String = ""
  ) {
    self.provider = provider
    self.collectedAt = collectedAt
    self.sessions = sessions
    self.agents = agents
    self.projects = projects
    self.groups = groups
    self.coverageNote = coverageNote
  }
}
