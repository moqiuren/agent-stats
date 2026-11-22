import Foundation
import StatsCore

package final class CodexMetrics: SessionMetrics {
  // Item types that are tool execution (including extension tools like web.search
  // and clock.sleep). Reasoning/AgentMessage are model output; UserMessage is input.
  package static let toolItemTypes: Set<String> = [
    "CommandExecution", "McpToolCall", "Extension", "FileChange", "ImageView", "ContextCompaction",
    "SubAgentActivity", "WebSearch", "DynamicToolCall", "CollabAgentToolCall", "ImageGeneration",
  ]
  package var issues = 0 { didSet { cachedSnapshot = nil } }
  private var turns = OrderedRecords(), records = OrderedRecords(), items = OrderedRecords(),
    calls = OrderedRecords()
  private var callIDsByTurn = [String: [String]]()
  private var cachedSnapshot: JSONObject?
  private var closedToolSpans = [(Double, Double)](), pendingToolStarts = [Double]()
  private var hasOpenTurn = false
  private var segment = [JSONObject](), samples = [JSONObject](), segmentToolEnds = [Double](),
    segmentBlocked = false, openSegmentCalls = Set<String>()
  private var currentTurn = "undefined", model: String?, updatedAt = 0.0, fallback: JSONObject?,
    excluded = false
  private var metadata: CodexSessionMetadata
  package init(sessionID: String? = nil) { metadata = CodexSessionMetadata(sessionID: sessionID) }
  private let fractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  private let plain = ISO8601DateFormatter()
  // Compiling the pattern per record dominated the timestamp step; this runs for
  // every line of every rollout log.
  private static let fractionalTrim = try! NSRegularExpression(pattern: "\\.([0-9]{3})[0-9]+")
  private func ensureTurn(_ id: String) { if turns[id] == nil { turns[id] = ["id": id] } }

  package func accept(_ r: JSONObject) {
    cachedSnapshot = nil
    let p = jsonObject(r["payload"])
    let type = r["type"] as? String ?? ""
    let event = p["type"] as? String ?? ""
    let stamp = r["timestamp"] as? String ?? ""
    // Match JSON/JavaScript epoch-millisecond precision, including logs with microseconds.
    let millisecondStamp = Self.fractionalTrim.stringByReplacingMatches(
      in: stamp, range: NSRange(stamp.startIndex..., in: stamp), withTemplate: ".$1")
    let time = (fractional.date(from: millisecondStamp) ?? plain.date(from: millisecondStamp)).map {
      ($0.timeIntervalSince1970 * 1000).rounded()
    }
    if let time { updatedAt = max(updatedAt, time) }
    if type == "session_meta" {
      metadata.accept(p)
      excluded = metadata.isExcluded
    }
    if type == "turn_context" {
      currentTurn = identifier(p["turn_id"])
      model = p["model"] as? String ?? model
      ensureTurn(currentTurn)
      turns.update(currentTurn) { $0["model"] = model }
    }
    let turn = p["turn_id"].map(identifier) ?? currentTurn
    if type == "event_msg", event == "task_started" {
      currentTurn = turn
      ensureTurn(turn)
      turns.update(turn) { if $0["start"] == nil { $0["start"] = nullable(time) } }
      segment = []
      segmentToolEnds = []
      segmentBlocked = false
      openSegmentCalls.removeAll()
    }
    if type == "event_msg", ["task_complete", "task_aborted", "turn_aborted"].contains(event) {
      ensureTurn(turn)
      turns.update(turn) { t in
        t["end"] = nullable(time)
        t["reason"] = event == "task_complete" ? "completed" : "cancelled"
        let elapsed = time.flatMap { end in number(t["start"]).map { max(0, end - $0) } }
        t["durationMs"] = nullable(nonnegative(p["duration_ms"]) ?? elapsed)
        t["ttftMs"] = nullable(nonnegative(p["time_to_first_token_ms"]))
      }
      for id in callIDsByTurn[turn] ?? [] where number(calls[id]?["end"]) == nil {
        calls.update(id) { $0["end"] = nullable(time) }
      }
      segment = []
      segmentToolEnds = []
      segmentBlocked = false
      openSegmentCalls.removeAll()
    }
    if type == "event_msg", event == "item_completed" {
      let item = jsonObject(p["item"])
      let kind = item["type"] as? String ?? ""
      if let id = item["id"] as? String, let a = nonnegative(p["started_at_ms"]),
        let b = nonnegative(p["completed_at_ms"]), b >= a, items[id] == nil
      {
        if ["Reasoning", "AgentMessage"].contains(kind) {
          let value: JSONObject = [
            "id": id, "kind": kind, "phase": item["phase"] ?? jsonNull, "a": a, "b": b,
            "turn": turn,
          ]
          items[id] = value
          segment.append(value)
        } else if Self.toolItemTypes.contains(kind) {
          // Tool items carry their own (a,b) too. Some rows report a zero
          // span (the host logs the command only when it completes) and
          // some report a completed_at_ms that is really the next record's
          // write time; both are clamped to the turn window before they
          // can contribute coverage.
          items[id] = ["id": id, "kind": kind, "a": a, "b": b, "turn": turn]
          if openSegmentCalls.isEmpty { segmentBlocked = true }
        }
      }
    }
    if type == "response_item", ["custom_tool_call", "function_call"].contains(event) {
      // Bind the call to the turn its own record names, like item_completed
      // rows do: a late call tagged with an earlier turn_id must not tick as
      // the running turn's tool.
      if let id = p["call_id"] as? String {
        openSegmentCalls.insert(id)
        if calls[id] == nil {
          calls[id] = ["id": id, "start": nullable(time), "turn": turn]
          callIDsByTurn[turn, default: []].append(id)
        }
      }
      if let time { segmentToolEnds.append(time) }
    }
    if type == "response_item", ["custom_tool_call_output", "function_call_output"].contains(event) {
      if let id = p["call_id"] as? String {
        openSegmentCalls.remove(id)
        if let call = calls[id], number(call["end"]) == nil {
          calls.update(id) { $0["end"] = nullable(time) }
        }
      }
      if !segment.isEmpty || !segmentToolEnds.isEmpty { segmentBlocked = true }
    }
    if type == "event_msg", event == "token_count",
      let value = jsonObject(p["info"])["total_token_usage"] as? JSONObject
    {
      fallback = value
    }
    if type == "token_usage_record" {
      let id = p["response_id"] as? String ?? "\(identifier(p["turn_id"])):\(stamp)"
      guard records[id] == nil else { return }
      let usage = jsonObject(p["usage"])
      records[id] = usage
      if !segmentBlocked, !segment.isEmpty, let output = nonnegative(usage["output_tokens"]),
        output > 0
      {
        var spans: [(Double, Double)] = segment.compactMap { entry in
          guard let a = number(entry["a"]), let b = number(entry["b"]) else { return nil }
          return (a, b)
        }
        if let lastModelEnd = spans.map(\.1).max() {
          if let maxToolEnd = segmentToolEnds.max(), maxToolEnd >= lastModelEnd {
            spans.append((lastModelEnd, maxToolEnd))
          }
          let ms = spanMilliseconds(spans)
          if ms >= 50 { samples.append(["turn": turn, "tokens": output, "ms": ms]) }
        }
      }
      segment = []
      segmentToolEnds = []
      segmentBlocked = false
    }
  }
  private func rate(_ xs: [JSONObject]) -> Any {
    let ms = sum(xs, "ms")
    return ms > 0 ? sum(xs, "tokens") / (ms / 1000) : jsonNull
  }
  // Only state that a later accept() or rebuildSnapshot() reads is persisted. The
  // clock and span projections are recomputed, so a restored session still ticks.
  package var cacheState: JSONObject? {
    [
      "schemaVersion": 2,
      "issues": issues, "turns": turns.cacheState, "records": records.cacheState,
      "items": items.cacheState, "calls": calls.cacheState,
      "callIDsByTurn": callIDsByTurn, "segment": segment, "samples": samples,
      "segmentToolEnds": segmentToolEnds, "segmentBlocked": segmentBlocked,
      "openSegmentCalls": openSegmentCalls.sorted(),
      "currentTurn": currentTurn, "model": nullable(model), "updatedAt": updatedAt,
      "fallback": nullable(fallback),
      "excluded": excluded, "metadata": metadata.cacheState,
    ]
  }
  package func restore(_ state: JSONObject) -> Bool {
    guard number(state["schemaVersion"]) == 2 else { return false }
    var turns = OrderedRecords()
    var records = OrderedRecords()
    var items = OrderedRecords()
    var calls = OrderedRecords()
    guard let turnState = state["turns"] as? JSONObject,
      let recordState = state["records"] as? JSONObject,
      let itemState = state["items"] as? JSONObject,
      let callState = state["calls"] as? JSONObject,
      let callIDs = state["callIDsByTurn"] as? [String: [String]],
      let segment = state["segment"] as? [JSONObject],
      let samples = state["samples"] as? [JSONObject],
      let segmentToolEnds = state["segmentToolEnds"] as? [Double],
      let segmentBlocked = state["segmentBlocked"] as? Bool,
      let openCalls = state["openSegmentCalls"] as? [String],
      let currentTurn = state["currentTurn"] as? String,
      let metadataState = state["metadata"] as? JSONObject
    else { return false }
    // Validate everything before mutating, so a rejected state leaves no partial trace.
    var restoredMetadata = metadata
    guard turns.restore(turnState), records.restore(recordState), items.restore(itemState),
      calls.restore(callState),
      restoredMetadata.restore(metadataState)
    else { return false }
    self.turns = turns
    self.records = records
    self.items = items
    self.calls = calls
    callIDsByTurn = callIDs
    self.segment = segment
    self.samples = samples
    self.segmentToolEnds = segmentToolEnds
    self.segmentBlocked = segmentBlocked
    openSegmentCalls = Set(openCalls)
    self.currentTurn = currentTurn
    model = state["model"] as? String
    updatedAt = number(state["updatedAt"]) ?? 0
    fallback = state["fallback"] as? JSONObject
    excluded = state["excluded"] as? Bool ?? false
    metadata = restoredMetadata
    issues = Int(number(state["issues"]) ?? 0)
    cachedSnapshot = nil
    return true
  }
  package func snapshot(now: Double) -> JSONObject {
    if cachedSnapshot == nil { rebuildSnapshot() }
    var result = cachedSnapshot!
    let active = hasOpenTurn && now - updatedAt < 120000
    result["active"] = active
    if active && !pendingToolStarts.isEmpty {
      // The ticking call stays outside the turn-window projection: it may
      // belong to the running turn whose window is not known yet.
      result["toolMs"] =
        (number(result["toolMs"]) ?? 0) - spanMilliseconds(closedToolSpans)
        + spanMilliseconds(closedToolSpans + pendingToolStarts.map { ($0, now) })
    }
    return result
  }

  // Every span of the turn is classified into exactly one bucket so the two
  // totals always sum to the turn duration. A merged block that touches a tool
  // span is tool time (the tool is running or the model is waiting on it); any
  // other block is model time. Gaps are attributed to the bucket of the nearest
  // recorded span: a gap right after a tool span is the model waiting on that
  // tool, a gap with no tool span nearby is model request overhead.
  private static func attributeResidual(
    _ start: Double, _ end: Double, spans: [(Double, Double, String)]
  ) -> (model: Double, tool: Double) {
    let modelSpans = spans.filter { $0.2 == "model" }.map { ($0.0, $0.1) }
    let toolSpans = spans.filter { $0.2 == "tool" }.map { ($0.0, $0.1) }
    var merged = [(Double, Double, String)]()
    for (a, b, kind) in spans.sorted(by: { $0.0 < $1.0 }) where b >= a {
      if let last = merged.last, a <= last.1 {
        merged[merged.count - 1].1 = max(last.1, b)
        if kind == "tool" { merged[merged.count - 1].2 = "tool" }
      } else {
        merged.append((a, b, kind))
      }
    }
    var model = 0.0
    var tool = 0.0
    var prev = start
    for (a, b, kind) in merged + [(end, end, "end")] {
      let gapStart = prev
      let gapEnd = min(a, end)
      if gapEnd > gapStart {
        let gap = gapEnd - gapStart
        let nearModel = modelSpans.contains { gapStart <= $0.1 + 2000 && $0.0 - 2000 <= gapEnd }
        let nearTool = toolSpans.contains { gapStart <= $0.1 + 2000 && $0.0 - 2000 <= gapEnd }
        if nearTool && !nearModel { tool += gap } else { model += gap }
      }
      if b > a {
        let covered = min(b, end) - a
        if kind == "tool" { tool += covered } else { model += covered }
      }
      prev = max(prev, b)
    }
    return (model, tool)
  }

  // Historical metrics change only when records arrive. Clock-dependent tool
  // waits and the activity timeout are applied separately on every snapshot.
  private func rebuildSnapshot() {
    let turnValues = turns.values
    let itemValues = items.values
    let callValues = calls.values
    let completed = turnValues.filter { number($0["end"]) != nil }
    let ttfts = completed.filter { number($0["ttftMs"]) != nil }
    let last = turnValues.last
    let durations = completed.compactMap { nonnegative($0["durationMs"]) }
    hasOpenTurn = last != nil && number(last?["end"]) == nil
    func itemSpans(_ xs: [JSONObject]) -> [(Double, Double)] {
      xs.compactMap { x in
        guard let a = number(x["a"]), let b = number(x["b"]) else { return nil }
        return (a, b)
      }
    }
    closedToolSpans = callValues.compactMap { call in
      guard let start = number(call["start"]), let end = number(call["end"]) else { return nil }
      return (start, end)
    }
    pendingToolStarts = callValues.compactMap { call in
      guard number(call["end"]) == nil, call["turn"] as? String == last?["id"] as? String else {
        return nil
      }
      return number(call["start"])
    }
    let itemsByTurn = Dictionary(grouping: itemValues, by: { identifier($0["turn"]) })
    let callsByTurn = Dictionary(grouping: callValues, by: { identifier($0["turn"]) })
    let usages = records.count > 0 ? records.values : fallback.map { [$0] } ?? []
    let inputs = sum(usages, "input_tokens")
    let read = sum(usages, "cached_input_tokens")
    let write = sum(usages, "cache_write_input_tokens")
    let output = sum(usages, "output_tokens")
    var modelTotal = 0.0
    var reasoningTotal = 0.0
    var decodeTotal = 0.0
    var toolTotal = 0.0
    for t in completed {
      guard let duration = number(t["durationMs"]), let end = number(t["end"]) else { continue }
      let start = end - duration
      let id = identifier(t["id"])
      let ownItems = itemsByTurn[id] ?? []
      let toolSpans: [(Double, Double)] = (callsByTurn[id] ?? []).compactMap { c in
        guard let a = number(c["start"]), let b = number(c["end"]) else { return nil }
        return (a, b)
      }
      func clip(_ xs: [(Double, Double)]) -> [(Double, Double)] {
        xs.map { (max($0.0, start), min($0.1, end)) }.filter { $0.1 >= $0.0 }
      }
      let reasoningSpans = clip(itemSpans(ownItems.filter { $0["kind"] as? String == "Reasoning" }))
      let messageSpans = clip(
        itemSpans(ownItems.filter { $0["kind"] as? String == "AgentMessage" }))
      let toolItemSpans = clip(
        itemSpans(ownItems.filter { Self.toolItemTypes.contains($0["kind"] as? String ?? "") }))
      let callSpans = clip(toolSpans)
      reasoningTotal += windowedSpanMilliseconds(reasoningSpans, start, end)
      decodeTotal += windowedSpanMilliseconds(messageSpans, start, end)
      let tagged =
        (reasoningSpans + messageSpans).map { ($0.0, $0.1, "model") }
        + (toolItemSpans + callSpans).map { ($0.0, $0.1, "tool") }
      let split = Self.attributeResidual(start, end, spans: tagged)
      modelTotal += split.model
      toolTotal += split.tool
    }
    let lastTurn = last.map { t -> JSONObject in
      [
        "id": t["id"] ?? jsonNull, "durationMs": t["durationMs"] ?? jsonNull,
        "reason": t["reason"] ?? "running", "ttftMs": t["ttftMs"] ?? jsonNull,
        "tps": rate(samples.filter { $0["turn"] as? String == t["id"] as? String }),
      ]
    }
    // A session without a single completed turn has no measured turn window, so
    // every turn-scoped duration stays unknown instead of reading as zero.
    let measured = !completed.isEmpty
    cachedSnapshot = [
      "provider": "codex", "model": nullable(model), "excluded": excluded, "turns": turns.count,
      "completedTurns": completed.count, "steps": records.count > 0 ? records.count : jsonNull,
      "active": false,
      "avgTurnMs": durations.isEmpty ? jsonNull : durations.reduce(0, +) / Double(durations.count),
      "turnDurationSamples": durations.count,
      "avgTtftMs": ttfts.isEmpty ? jsonNull : sum(ttfts, "ttftMs") / Double(ttfts.count),
      "ttftSamples": ttfts.count, "tps": rate(samples), "tpsSamples": samples.count,
      "tpsTokens": sum(samples, "tokens"), "tpsDurationMs": sum(samples, "ms"),
      "tpsKind": "output_stream",
      "llmMs": jsonNull, "firstTokenWaitMs": jsonNull,
      "decodeMs": measured ? decodeTotal : jsonNull,
      "reasoningMs": measured ? reasoningTotal : jsonNull,
      "toolMs": measured ? toolTotal : jsonNull,
      "modelMs": measured ? modelTotal : jsonNull,
      "totalMs": measured ? sum(completed, "durationMs") : jsonNull,
      "input": max(0, inputs - read - write), "cacheRead": read, "cacheWrite": write,
      "output": output, "totalTokens": inputs + output,
      "cacheHit": inputs > 0 ? read / inputs * 100 : jsonNull,
      "reasoningTokens": sum(usages, "reasoning_output_tokens"), "lastTurn": nullable(lastTurn),
      "updatedAt": updatedAt, "malformedLines": issues,
    ]
  }
}
