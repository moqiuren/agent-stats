// Kimi Code adapter for the DSH StatsPills metric definitions.
// Reads timing and usage metadata only; no prompt, reply, tool argument or credential is retained.
export function spanMs(spans) {
  let end = -Infinity, total = 0;
  for (const [a, b] of [...spans].sort((a, b) => a[0] - b[0])) {
    if (!Number.isFinite(a) || !Number.isFinite(b) || b < a) continue;
    total += Math.max(0, b - Math.max(a, end)); end = Math.max(end, b);
  }
  return total;
}
// Union coverage of spans clipped into [start, end]. Codex item rows can carry a
// completed_at_ms that is really the log-write time (a completed command whose
// rows arrive with the next record), so an unclipped interval swallows unrelated
// items and fabricates huge tool spans; every turn-scoped projection must clamp.
export function windowedSpanMs(spans, start, end) {
  return spanMs(spans.map(([a, b]) => [Math.max(a, start), Math.min(b, end)]).filter(([a, b]) => b >= a));
}
// True when the instant falls inside any span clipped to [start, end].
export function inSpans(spans, x, start, end) {
  return spans.some(([a, b]) => Math.max(a, start) <= x && x <= Math.min(b, end));
}
export class Metrics {
  constructor() {
    this.steps = new Map(); this.turns = new Map(); this.calls = new Map(); this.spans = [];
    this.usage = new Map(); this.models = new Map(); this.model = null; this.updatedAt = 0;
    this.issues = 0;
    // Context length exactly as the host measured it: no ratio and no limit are
    // derived, and Kimi Code already displays this number itself.
    this.contextTokens = null;
    this.openInteractions = new Map(); this.lastTurnEnd = null; this.permissionMode = null;
  }
  accept(o) {
    if (!o || typeof o !== 'object') return;
    const t = o.time;
    if (Number.isFinite(t)) this.updatedAt = Math.max(this.updatedAt, t);
    if (o.type === 'profile.bind') this.model = o.modelAlias || this.model;
    if ((o.type === 'token_counting.measured' || o.type === 'token_counting.turn_recorded') && finite(o.tokens) !== null) this.contextTokens = finite(o.tokens);
    if (o.type === 'permission.set_mode' && typeof o.mode === 'string' && o.mode !== '' && o.mode.length <= 32) this.permissionMode = o.mode;
    if (o.type === 'interaction.request' && ['approval', 'question'].includes(o.kind) && Number.isFinite(t)) this.openInteractions.set(String(o.id), {kind: o.kind, time: t});
    if (o.type === 'interaction.resolved') this.openInteractions.delete(String(o.id));
    if (o.type === 'llm.request' && o.kind === 'loop') {
      this.model = o.modelAlias || o.model || this.model;
      this.models.set(o.turnStep, this.model);
    }
    if (o.type === 'usage.record') {
      // usage.record is the durable accounting record, not step.end. Never count both.
      const request=o.requestId ?? o.responseId ?? o.request_id ?? o.response_id;
      const key = request ? `request:${request}` : `event:${this.usage.size}:${JSON.stringify([o.time, o.model, o.usageScope, o.usage])}`;
      if (!this.usage.has(key)) this.usage.set(key, o.usage || {});
    }
    if (o.type === 'agent.turn.started' || (o.type === 'turn.prompt' && o.turnId !== undefined && o.turnId !== null)) {
      const key = String(o.turnId);
      if (!this.turns.has(key)) this.turns.set(key, {id: key, start: t, end: null, durationMs: null});
    }
    if (o.type === 'turn.ended') {
      const key = String(o.turnId), prior = this.turns.get(key) || {id: key, start: t - o.durationMs};
      this.turns.set(key, {...prior, end: t, durationMs: o.durationMs, reason: o.reason});
      if (Number.isFinite(t)) this.lastTurnEnd = Math.max(this.lastTurnEnd ?? 0, t);
      this.closeCalls(key, t);
    }
    // A host that ends a turn without turn.ended (interrupted runs) still emits
    // agent.turn.ended; closing the turn there keeps its clock from ticking on.
    if (o.type === 'agent.turn.ended') {
      const key = String(o.turnId), prior = this.turns.get(key) || {id: key, start: null, end: null, durationMs: null};
      if (prior.end === null) this.turns.set(key, {...prior, end: t, reason: prior.reason ?? o.outcome ?? null});
      if (Number.isFinite(t)) this.lastTurnEnd = Math.max(this.lastTurnEnd ?? 0, t);
      this.closeCalls(key, t);
    }
    if (o.type !== 'context.append_loop_event') return;
    const e = o.event || {};
    if (e.type === 'step.begin' && !this.steps.has(e.uuid)) this.steps.set(e.uuid, {id: e.uuid, turn: String(e.turnId), number: e.step, start: t});
    if (e.type === 'step.end') {
      const prev = this.steps.get(e.uuid) || {id: e.uuid, turn: String(e.turnId), number: e.step};
      this.steps.set(e.uuid, {...prev, end: t, finish: e.finishReason,
        model: this.models.get(`${e.turnId}.${e.step}`) || this.model,
        ttftMs: finite(e.llmFirstTokenLatencyMs), streamMs: finite(e.llmStreamDurationMs),
        output: finite(e.usage?.output)});
    }
    if (e.type === 'tool.call' && !this.calls.has(e.toolCallId)) this.calls.set(e.toolCallId, {start: t, end: null, turn: String(e.turnId)});
    if (e.type === 'tool.result') {
      const c = this.calls.get(e.toolCallId);
      if (c && c.end === null) {c.end = t; this.spans.push([c.start, t]);}
    }
  }
  closeCalls(turn, t) {
    if (!Number.isFinite(t)) return;
    for (const c of this.calls.values()) if (c.turn === turn && c.end === null && Number.isFinite(c.start)) {c.end = t; this.spans.push([c.start, t]);}
  }
  // Live clocks may tick only while the log keeps writing: a dead host must not
  // inflate durations forever, so at most 120s of silence is ever charged.
  clockNow(now) {return Math.min(now, this.updatedAt + 120000);}
  snapshot(now = Date.now()) {
    const steps = [...this.steps.values()];
    const completed = steps.filter(s => ['tool_use', 'end_turn'].includes(s.finish));
    const timed = completed.filter(s => s.ttftMs !== null && s.ttftMs !== undefined);
    const streamed = completed.filter(s => s.streamMs > 0 && s.output !== null && s.output !== undefined);
    const decoded = streamed.filter(s => s.streamMs >= 50 && s.output > 0);
    const sum = (xs, key) => xs.reduce((n, s) => n + (s[key] || 0), 0);
    const decodeMs = sum(streamed, 'streamMs');
    const tpsDurationMs = sum(decoded, 'streamMs'), decodeTokens = sum(decoded, 'output');
    const usage = [...this.usage.values()];
    const input = sum(usage, 'inputOther'), cacheRead = sum(usage, 'inputCacheRead'), cacheWrite = sum(usage, 'inputCacheCreation'), output = sum(usage, 'output');
    const calls = [...this.calls.values()];
    const turns = [...this.turns.values()];
    const durations = turns.filter(t=>t.end!==null).map(t=>finite(t.durationMs)).filter(d=>d!==null);
    const active = turns.filter(t => t.end === null).at(-1);
    const pending = calls.filter(c => c.end === null && active && c.turn === active.id);
    const live = this.clockNow(now);
    // A duration stays unknown unless something measured it: a turn window, a
    // closed tool span, or a completed step. A measured zero still reads zero.
    const toolBasis = durations.length > 0 || this.spans.length > 0;
    const stepBasis = durations.length > 0 || completed.length > 0;
    const toolMs = pending.length ? spanMs([...this.spans, ...pending.map(c => [c.start, live])])
      : (toolBasis ? spanMs(this.spans) : null);
    const last = turns.at(-1);
    const lastSteps = completed.filter(s => s.turn === last?.id).sort((a,b) => a.number - b.number);
    const lastDecode = lastSteps.filter(s => s.streamMs >= 50 && s.output !== null && s.output !== undefined && s.output > 0);
    const latest = completed.at(-1);
    const waiting = [...this.openInteractions.values()].filter(x => x.time > (this.lastTurnEnd ?? 0));
    const measured = durations.length > 0;
    const runningStarts = turns.filter(t => t.durationMs === null || t.durationMs === undefined)
      .filter(t => t.end === null && Number.isFinite(t.start)).map(t => t.start);
    const tick = runningStarts.reduce((n, s) => n + Math.max(0, live - s), 0);
    const baseTotal = turns.reduce((n,t) => n + (Number.isFinite(t.durationMs) ? t.durationMs : 0), 0);
    const totalMs = runningStarts.length ? (measured ? baseTotal : 0) + tick : (measured ? baseTotal : null);
    const lastDurationUsesClock = Boolean(last) && (last.durationMs === null || last.durationMs === undefined) && last.end === null;
    return {model: latest?.model || this.model, turns: turns.length, completedTurns: turns.filter(t => t.end !== null).length,
      steps: completed.length, active: Boolean(active), pendingTools: pending.length,
      avgTurnMs:durations.length?durations.reduce((a,b)=>a+b,0)/durations.length:null,turnDurationSamples:durations.length,
      ttftSamples:timed.length,tpsSamples:decoded.length,avgTtftMs: timed.length ? sum(timed, 'ttftMs') / timed.length : null,
      tps: tpsDurationMs > 0 ? decodeTokens / (tpsDurationMs / 1000) : null, tpsTokens:decodeTokens,tpsDurationMs,
      decodeMs: stepBasis ? decodeMs : null,
      llmMs: stepBasis ? completed.reduce((n, s) => n + (s.ttftMs || 0) + (s.streamMs || 0), 0) : null,
      firstTokenWaitMs: stepBasis ? sum(timed, 'ttftMs') : null, toolMs,
      totalMs,
      input, cacheRead, cacheWrite, output, totalTokens: input + cacheRead + cacheWrite + output,
      cacheHit: input + cacheRead + cacheWrite > 0 ? cacheRead / (input + cacheRead + cacheWrite) * 100 : null,
      lastTurn: last ? {id:last.id,
        durationMs: Number.isFinite(last.durationMs) ? last.durationMs
          : (lastDurationUsesClock ? (Number.isFinite(last.start) ? Math.max(0, live - last.start) : 0) : null),
        reason:last.reason || 'running',
        ttftMs:lastSteps[0]?.ttftMs ?? null, tps:sum(lastDecode,'streamMs') > 0 ? sum(lastDecode,'output') / (sum(lastDecode,'streamMs')/1000) : null} : null,
      updatedAt: this.updatedAt, malformedLines:this.issues,
      contextTokens: this.contextTokens ?? null, permissionMode: this.permissionMode ?? null,
      pendingApprovals: waiting.filter(x => x.kind === 'approval').length,
      pendingQuestions: waiting.filter(x => x.kind === 'question').length};
  }
}
function finite(v) {return Number.isFinite(v) && v >= 0 ? v : null;}
