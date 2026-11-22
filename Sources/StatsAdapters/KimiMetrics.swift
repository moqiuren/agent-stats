import Foundation
import StatsCore

package final class KimiMetrics: SessionMetrics {
  package var issues = 0 { didSet { cachedSnapshot = nil } }
  private var steps = OrderedRecords(), turns = OrderedRecords(), calls = OrderedRecords(),
    usage = OrderedRecords()
  private var usageOrdinal = 0
  // Call ids indexed by turn. Closing a turn must not rescan every call ever seen:
  // that made a long agentic session quadratic in turns times tool calls.
  private var callsByTurn = [String: [String]]()
  private var spans = [(Double, Double)](), models = [String: String]()
  private var model: String?, updatedAt = 0.0
  private var cachedSnapshot: JSONObject?
  private var runningStarts = [Double](), pendingToolStarts = [Double]()
  private var lastDurationUsesClock = false, lastStart: Double?
  // Context length as the host itself measured it. Kimi Code already shows this
  // number, so it is reported as a length only: no occupancy ratio and no limit
  // are derived from it, and no token count is estimated from text length.
  private var contextTokens: Double?
  // A pending interaction only counts while its turn has not ended. The log records
  // no cancellation, so a session whose host died still ends on its last open
  // request; the UI labels the value as the last recorded state, never as live.
  private var openInteractions = [String: (kind: String, time: Double)]()
  private var lastTurnEnd: Double?, permissionMode: String?

  package func accept(_ o: JSONObject) {
    cachedSnapshot = nil
    let time = number(o["time"])
    let type = o["type"] as? String ?? ""
    if let time { updatedAt = max(updatedAt, time) }
    if type == "profile.bind" { model = o["modelAlias"] as? String ?? model }
    if type == "token_counting.measured" || type == "token_counting.turn_recorded",
      let tokens = nonnegative(o["tokens"])
    {
      contextTokens = tokens
    }
    if type == "permission.set_mode", let mode = o["mode"] as? String, !mode.isEmpty,
      mode.count <= 32
    {
      permissionMode = mode
    }
    if type == "interaction.request", let kind = o["kind"] as? String,
      ["approval", "question"].contains(kind), let time
    {
      openInteractions[identifier(o["id"])] = (kind, time)
    }
    if type == "interaction.resolved" { openInteractions.removeValue(forKey: identifier(o["id"])) }
    if type == "llm.request", o["kind"] as? String == "loop" {
      model = o["modelAlias"] as? String ?? o["model"] as? String ?? model
      models[identifier(o["turnStep"])] = model
    }
    if type == "usage.record" {
      let parts: [Any] = [
        o["time"] ?? jsonNull, o["model"] ?? jsonNull, o["usageScope"] ?? jsonNull,
        o["usage"] ?? jsonNull,
      ]
      if let data = try? JSONSerialization.data(withJSONObject: parts, options: [.sortedKeys]) {
        usageOrdinal += 1
        let request = ["requestId", "responseId", "request_id", "response_id"].compactMap {
          o[$0] as? String
        }.first
        let key = request.map { "request:" + $0 } ?? data.base64EncodedString() + ":\(usageOrdinal)"
        if usage[key] == nil { usage[key] = jsonObject(o["usage"]) }
      }
    }
    let hasTurnID = o["turnId"] != nil && !(o["turnId"] is NSNull)
    let turn = identifier(o["turnId"])
    if (type == "agent.turn.started" || (type == "turn.prompt" && hasTurnID)), turns[turn] == nil {
      turns[turn] = ["id": turn, "start": nullable(time)]
    }
    if type == "turn.ended" {
      turns.update(turn) { record in
        record["id"] = turn
        if record["start"] == nil, let time, let duration = number(o["durationMs"]) {
          record["start"] = time - duration
        }
        record["end"] = nullable(time)
        record["durationMs"] = o["durationMs"]
        record["reason"] = o["reason"]
      }
      if let time { lastTurnEnd = max(lastTurnEnd ?? 0, time) }
      closeCalls(of: turn, at: time)
    }
    // A host that ends a turn without turn.ended (interrupted runs) still emits
    // agent.turn.ended; closing the turn there keeps its clock from ticking on.
    if type == "agent.turn.ended" {
      turns.update(turn) { record in
        record["id"] = turn
        if record["end"] == nil {
          record["end"] = nullable(time)
          if record["reason"] == nil { record["reason"] = o["outcome"] ?? jsonNull }
        }
      }
      if let time { lastTurnEnd = max(lastTurnEnd ?? 0, time) }
      closeCalls(of: turn, at: time)
    }
    guard type == "context.append_loop_event" else { return }
    let e = jsonObject(o["event"])
    let event = e["type"] as? String ?? ""
    let id = identifier(e["uuid"])
    let eventTurn = identifier(e["turnId"])
    if event == "step.begin", steps[id] == nil {
      steps[id] = [
        "id": id, "turn": eventTurn, "number": e["step"] ?? jsonNull, "start": nullable(time),
      ]
    }
    if event == "step.end" {
      steps.update(id) { s in
        s["id"] = id
        s["turn"] = eventTurn
        s["number"] = e["step"]
        s["end"] = nullable(time)
        s["finish"] = e["finishReason"]
        s["model"] = models["\(eventTurn).\(identifier(e["step"]))"] ?? model
        s["ttftMs"] = nullable(nonnegative(e["llmFirstTokenLatencyMs"]))
        s["streamMs"] = nullable(nonnegative(e["llmStreamDurationMs"]))
        s["output"] = nullable(nonnegative(jsonObject(e["usage"])["output"]))
      }
    }
    let callID = identifier(e["toolCallId"])
    if event == "tool.call", calls[callID] == nil {
      calls[callID] = ["id": callID, "start": nullable(time), "turn": eventTurn]
      callsByTurn[eventTurn, default: []].append(callID)
    }
    if event == "tool.result", let call = calls[callID], number(call["end"]) == nil, let time,
      let start = number(call["start"])
    {
      calls.update(callID) { $0["end"] = time }
      spans.append((start, time))
    }
  }
  private func closeCalls(of turn: String, at time: Double?) {
    for id in callsByTurn[turn] ?? [] where number(calls[id]?["end"]) == nil {
      if let time, let start = number(calls[id]?["start"]) {
        calls.update(id) { $0["end"] = time }
        spans.append((start, time))
      }
    }
  }

  // Live clocks may tick only while the log keeps writing: a dead host must not
  // inflate durations forever, so at most 120s of silence is ever charged.
  private func clockNow(_ now: Double) -> Double { min(now, updatedAt + 120_000) }

  // Only accumulated state is persisted; running clocks and pending tool spans are
  // recomputed on every snapshot so a restored session keeps ticking.
  package var cacheState: JSONObject? {
    [
      "schemaVersion": 2,
      "issues": issues, "steps": steps.cacheState, "turns": turns.cacheState,
      "calls": calls.cacheState, "usage": usage.cacheState,
      "callsByTurn": callsByTurn,
      "usageOrdinal": usageOrdinal, "spans": spans.map { [$0.0, $0.1] }, "models": models,
      "model": nullable(model), "updatedAt": updatedAt,
      "contextTokens": nullable(contextTokens), "lastTurnEnd": nullable(lastTurnEnd),
      "permissionMode": nullable(permissionMode),
      "openInteractions": openInteractions.mapValues { ["kind": $0.kind, "time": $0.time] },
    ]
  }
  package func restore(_ state: JSONObject) -> Bool {
    guard number(state["schemaVersion"]) == 2 else { return false }
    var steps = OrderedRecords()
    var turns = OrderedRecords()
    var calls = OrderedRecords()
    var usage = OrderedRecords()
    guard let stepState = state["steps"] as? JSONObject,
      let turnState = state["turns"] as? JSONObject,
      let callState = state["calls"] as? JSONObject,
      let usageState = state["usage"] as? JSONObject,
      let callsByTurn = state["callsByTurn"] as? [String: [String]],
      let rawSpans = state["spans"] as? [[Double]],
      let models = state["models"] as? [String: String],
      let rawInteractions = state["openInteractions"] as? [String: JSONObject]
    else { return false }
    // Validate everything before mutating, so a rejected state leaves no partial trace.
    let restoredSpans = rawSpans.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    var restoredInteractions = [String: (kind: String, time: Double)]()
    for (id, value) in rawInteractions {
      guard let kind = value["kind"] as? String, let time = number(value["time"]) else {
        return false
      }
      restoredInteractions[id] = (kind, time)
    }
    guard restoredSpans.count == rawSpans.count,
      steps.restore(stepState), turns.restore(turnState), calls.restore(callState),
      usage.restore(usageState)
    else { return false }
    self.steps = steps
    self.turns = turns
    self.calls = calls
    self.usage = usage
    self.callsByTurn = callsByTurn
    spans = restoredSpans
    self.models = models
    model = state["model"] as? String
    updatedAt = number(state["updatedAt"]) ?? 0
    usageOrdinal = Int(number(state["usageOrdinal"]) ?? 0)
    issues = Int(number(state["issues"]) ?? 0)
    contextTokens = nonnegative(state["contextTokens"])
    lastTurnEnd = nonnegative(state["lastTurnEnd"])
    permissionMode = state["permissionMode"] as? String
    openInteractions = restoredInteractions
    cachedSnapshot = nil
    return true
  }
  package func snapshot(now: Double) -> JSONObject {
    if cachedSnapshot == nil { rebuildSnapshot() }
    var result = cachedSnapshot!
    let live = clockNow(now)
    if !runningStarts.isEmpty {
      result["totalMs"] =
        (number(result["totalMs"]) ?? 0) + runningStarts.reduce(0) { $0 + max(0, live - $1) }
    }
    if !pendingToolStarts.isEmpty {
      result["toolMs"] = spanMilliseconds(spans + pendingToolStarts.map { ($0, live) })
    }
    if lastDurationUsesClock, var last = result["lastTurn"] as? JSONObject {
      last["durationMs"] = lastStart.map { max(0, live - $0) } ?? 0
      result["lastTurn"] = last
    }
    return result
  }

  private func rebuildSnapshot() {
    let completed = steps.values.filter {
      ["tool_use", "end_turn"].contains($0["finish"] as? String ?? "")
    }
    let timed = completed.filter { number($0["ttftMs"]) != nil }
    let streamed = completed.filter {
      (number($0["streamMs"]) ?? 0) > 0 && number($0["output"]) != nil
    }
    let decoded = streamed.filter {
      (number($0["streamMs"]) ?? 0) >= 50 && (number($0["output"]) ?? 0) > 0
    }
    let decode = sum(streamed, "streamMs")
    let tpsDuration = sum(decoded, "streamMs")
    let tokens = sum(decoded, "output")
    let ttft = sum(timed, "ttftMs")
    let inputs = sum(usage.values, "inputOther")
    let read = sum(usage.values, "inputCacheRead")
    let write = sum(usage.values, "inputCacheCreation")
    let output = sum(usage.values, "output")
    let durations = turns.values.filter { number($0["end"]) != nil }.compactMap {
      nonnegative($0["durationMs"])
    }
    let active = turns.values.last { number($0["end"]) == nil }
    let last = turns.values.last
    let pending = calls.values.filter {
      number($0["end"]) == nil && active != nil && $0["turn"] as? String == active?["id"] as? String
    }
    pendingToolStarts = pending.compactMap { number($0["start"]) }
    runningStarts = turns.values.compactMap { turn in
      guard number(turn["durationMs"]) == nil, number(turn["end"]) == nil else { return nil }
      return number(turn["start"])
    }
    // Only a still-open turn may run on the live clock; an ended turn without a
    // recorded duration stays unknown instead of counting the time since it began.
    lastDurationUsesClock = last != nil && number(last?["durationMs"]) == nil && number(last?["end"]) == nil
    lastStart = number(last?["start"])
    let lastSteps = completed.filter { $0["turn"] as? String == last?["id"] as? String }.sorted {
      (number($0["number"]) ?? 0) < (number($1["number"]) ?? 0)
    }
    let lastDecoded = lastSteps.filter {
      (number($0["streamMs"]) ?? 0) >= 50 && (number($0["output"]) ?? 0) > 0
    }
    let waiting = openInteractions.values.filter { $0.time > (lastTurnEnd ?? 0) }
    var lastTurn: JSONObject?
    if let last {
      let ms = sum(lastDecoded, "streamMs")
      var lastDuration: Any = jsonNull
      if let duration = number(last["durationMs"]) { lastDuration = duration }
      else if lastDurationUsesClock { lastDuration = 0.0 }
      lastTurn = [
        "id": last["id"] ?? jsonNull,
        "durationMs": lastDuration,
        "reason": last["reason"] ?? "running",
        "ttftMs": lastSteps.first?["ttftMs"] ?? jsonNull,
        "tps": ms > 0 ? sum(lastDecoded, "output") / (ms / 1000) : jsonNull,
      ]
    }
    // A duration stays unknown unless something measured it: a turn window, a
    // closed tool span, or a completed step. A measured zero still reads zero.
    let measured = !durations.isEmpty
    let toolBasis = measured || !spans.isEmpty
    let stepBasis = measured || !completed.isEmpty
    cachedSnapshot = [
      "model": completed.last?["model"] ?? model as Any? ?? jsonNull, "turns": turns.count,
      "completedTurns": turns.values.filter { number($0["end"]) != nil }.count,
      "steps": completed.count, "active": active != nil, "pendingTools": pending.count,
      "ttftSamples": timed.count, "tpsSamples": decoded.count,
      "avgTurnMs": durations.isEmpty ? jsonNull : durations.reduce(0, +) / Double(durations.count),
      "turnDurationSamples": durations.count,
      "avgTtftMs": timed.isEmpty ? jsonNull : ttft / Double(timed.count),
      "tps": tpsDuration > 0 ? tokens / (tpsDuration / 1000) : jsonNull,
      "tpsTokens": tokens, "tpsDurationMs": tpsDuration,
      "decodeMs": stepBasis ? decode : jsonNull,
      "llmMs": stepBasis ? sum(completed, "ttftMs") + sum(completed, "streamMs") : jsonNull,
      "firstTokenWaitMs": stepBasis ? ttft : jsonNull,
      "toolMs": toolBasis ? spanMilliseconds(spans) : jsonNull,
      "totalMs": measured ? turns.values.reduce(0.0) { $0 + (number($1["durationMs"]) ?? 0) } : jsonNull,
      "input": inputs, "cacheRead": read, "cacheWrite": write, "output": output,
      "totalTokens": inputs + read + write + output,
      "cacheHit": inputs + read + write > 0 ? read / (inputs + read + write) * 100 : jsonNull,
      "lastTurn": nullable(lastTurn), "updatedAt": updatedAt, "malformedLines": issues,
      "contextTokens": nullable(contextTokens), "permissionMode": nullable(permissionMode),
      "pendingApprovals": Double(waiting.filter { $0.kind == "approval" }.count),
      "pendingQuestions": Double(waiting.filter { $0.kind == "question" }.count),
    ]
  }
}
