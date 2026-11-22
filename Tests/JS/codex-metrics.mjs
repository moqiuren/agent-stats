import {spanMs, windowedSpanMs, inSpans} from './metrics.mjs';
const numeric = v => Number.isFinite(v) && v >= 0 ? v : null;
const sum=(xs,key)=>xs.reduce((n,x)=>n+(numeric(x[key])??0),0);
// Item types that are tool execution (including extension tools like web.search
// and clock.sleep). Reasoning/AgentMessage are model output; UserMessage is input.
const TOOL_ITEMS=new Set(['CommandExecution','McpToolCall','Extension','FileChange','ImageView','ContextCompaction','SubAgentActivity','WebSearch','DynamicToolCall','CollabAgentToolCall','ImageGeneration']);
export class CodexMetrics {
 constructor(sessionID=null){this.turns=new Map();this.records=new Map();this.items=new Map();this.calls=new Map();this.segment=[];this.segmentToolEnds=[];this.segmentBlocked=false;this.openSegmentCalls=new Set();this.samples=[];this.currentTurn=null;this.model=null;this.updatedAt=0;this.issues=0;this.fallback=null;this.excluded=false;this.sessionID=sessionID;this.sessionMeta={};}
 turn(id){if(!this.turns.has(id))this.turns.set(id,{id,start:null,end:null,durationMs:null,ttftMs:null});return this.turns.get(id);}
 accept(r){
  const p=r.payload||{},time=Date.parse(r.timestamp),type=r.type;
  if(Number.isFinite(time))this.updatedAt=Math.max(this.updatedAt,time);
  if(type==='session_meta'){
   const id=typeof p.id==='string'&&p.id.length?p.id:null;
   if(this.sessionID===null||this.sessionID===id){
    if(id!==null)this.sessionID=id;
    for(const key of ['source','thread_source'])if(Object.hasOwn(p,key))this.sessionMeta[key]=p[key];
    const meta=this.sessionMeta;
    this.excluded=['subagent','guardian_review'].includes(meta.thread_source)||String(meta.source).includes('subagent')||(typeof meta.source==='object' && !!meta.source?.subagent);
   }
  }
  if(type==='turn_context'){this.currentTurn=p.turn_id;this.model=p.model??this.model;this.turn(this.currentTurn).model=this.model;}
  if(type==='event_msg' && p.type==='task_started'){
   this.currentTurn=p.turn_id;const t=this.turn(p.turn_id);if(t.start===null)t.start=time;
   this.segment=[];this.segmentToolEnds=[];this.segmentBlocked=false;this.openSegmentCalls.clear();
  }
  if(type==='event_msg' && ['task_complete','task_aborted','turn_aborted'].includes(p.type)){
   const t=this.turn(p.turn_id||this.currentTurn);t.end=time;t.reason=p.type==='task_complete'?'completed':'cancelled';t.durationMs=numeric(p.duration_ms)??(Number.isFinite(t.start)?Math.max(0,time-t.start):null);t.ttftMs=numeric(p.time_to_first_token_ms);
   for(const c of this.calls.values())if(c.turn===t.id&&c.end===null)c.end=time;
   this.segment=[];this.segmentToolEnds=[];this.segmentBlocked=false;this.openSegmentCalls.clear();
  }
  if(type==='event_msg' && p.type==='item_completed'){
   const i=p.item||{},id=i.id;const a=numeric(p.started_at_ms),b=numeric(p.completed_at_ms);
   if(id && a!==null && b!==null && b>=a && ['Reasoning','AgentMessage'].includes(i.type) && !this.items.has(id)){
    const entry={id,kind:i.type,phase:i.phase,a,b,turn:p.turn_id||this.currentTurn};this.items.set(id,entry);this.segment.push(entry);
   }
   // Tool items carry their own (a,b) too. Some rows report a zero span (the host
   // logs the command only when it completes) and some report a completed_at_ms
   // that is really the next record's write time; both are clamped to the turn
   // window before they can contribute coverage.
   if(id && a!==null && b!==null && b>=a && TOOL_ITEMS.has(i.type) && !this.items.has(id)){
    this.items.set(id,{id,kind:i.type,a,b,turn:p.turn_id||this.currentTurn});
    if(this.openSegmentCalls.size===0)this.segmentBlocked=true;
   }
  }
  if(type==='response_item' && ['custom_tool_call','function_call'].includes(p.type)){
   // Bind the call to the turn its own record names, like item_completed rows do:
   // a late call tagged with an earlier turn_id must not tick as the running turn's tool.
   if(p.call_id){
    this.openSegmentCalls.add(p.call_id);
    if(!this.calls.has(p.call_id))this.calls.set(p.call_id,{start:time,end:null,turn:p.turn_id||this.currentTurn});
   }
   if(Number.isFinite(time))this.segmentToolEnds.push(time);
  }
  if(type==='response_item' && ['custom_tool_call_output','function_call_output'].includes(p.type)){
   if(p.call_id){
    this.openSegmentCalls.delete(p.call_id);
    const c=this.calls.get(p.call_id);if(c && c.end===null)c.end=time;
   }
   if(this.segment.length||this.segmentToolEnds.length)this.segmentBlocked=true;
  }
  if(type==='event_msg' && p.type==='token_count')this.fallback=p.info?.total_token_usage??this.fallback;
  if(type==='token_usage_record'){
   const id=p.response_id||`${p.turn_id}:${r.timestamp}`;
   if(this.records.has(id))return;
   const usage=p.usage||{};this.records.set(id,usage);
   const output=numeric(usage.output_tokens);
   // Measure full output decode throughput (reasoning + commentary + final text + tool args)
   // whenever a local stream start anchor exists and no mid-response tool execution intervened.
   if(!this.segmentBlocked && this.segment.length && output!==null && output>0){
    const spans=this.segment.map(i=>[i.a,i.b]).filter(([a,b])=>Number.isFinite(a)&&Number.isFinite(b));
    if(spans.length){
     const lastModelEnd=Math.max(...spans.map(s=>s[1]));
     if(this.segmentToolEnds.length){
      const maxToolEnd=Math.max(...this.segmentToolEnds);
      if(maxToolEnd>=lastModelEnd)spans.push([lastModelEnd,maxToolEnd]);
     }
     const elapsed=spanMs(spans);
     if(elapsed>=50)this.samples.push({turn:p.turn_id||this.currentTurn,tokens:output,ms:elapsed});
    }
   }
   this.segment=[];this.segmentToolEnds=[];this.segmentBlocked=false;
  }
 }
 // Every span of the turn is classified into exactly one bucket so the two
 // totals always sum to the turn duration. A merged block that touches a tool
 // span is tool time (the tool is running or the model is waiting on it); any
 // other block is model time. Gaps are attributed to the bucket of the nearest
 // recorded span: a gap right after a tool span is the model waiting on that
 // tool, a gap with no tool span nearby is model request overhead.
 attributeResidual(start,end,spans){
  const modelSpans=spans.filter(s=>s[2]==='model').map(s=>[s[0],s[1]]);
  const toolSpans=spans.filter(s=>s[2]==='tool').map(s=>[s[0],s[1]]);
  const merged=[];for(const [a,b,k] of [...spans].sort((x,y)=>x[0]-y[0])){
   if(b<a)continue;
   if(merged.length&&a<=merged.at(-1)[1]){merged.at(-1)[1]=Math.max(merged.at(-1)[1],b);if(k==='tool')merged.at(-1)[2]='tool';}
   else merged.push([a,b,k]);
  }
  let modelMs=0,toolMs=0,prev=start;
  for(const [a,b,k] of [...merged,[end,end,'end']]){
   const gapStart=prev,gapEnd=Math.min(a,end);
   if(gapEnd>gapStart){
    const gap=gapEnd-gapStart;
    const nearModel=modelSpans.some(([x,y])=>gapStart<=y+2000&&x-2000<=gapEnd);
    const nearTool=toolSpans.some(([x,y])=>gapStart<=y+2000&&x-2000<=gapEnd);
    if(nearTool&&!nearModel)toolMs+=gap;else modelMs+=gap;
   }
   if(b>a){if(k==='tool')toolMs+=Math.min(b,end)-a;else modelMs+=Math.min(b,end)-a;}
   prev=Math.max(prev,b);
  }
  return {modelMs,toolMs};
 }
 snapshot(now=Date.now()){
  const turns=[...this.turns.values()],completed=turns.filter(t=>t.end!==null),ttfts=completed.filter(t=>t.ttftMs!==null);
  const durations=completed.map(t=>numeric(t.durationMs)).filter(d=>d!==null);
  const items=[...this.items.values()];
  const calls=[...this.calls.values()],last=turns.at(-1);
  // The running clock only ticks while the log keeps writing: a dead session
  // must not keep accumulating tool time.
  const active=Boolean(last?.end===null&&now-this.updatedAt<120000);
  const closedSpans=calls.filter(c=>c.end!==null&&Number.isFinite(c.start)&&Number.isFinite(c.end)).map(c=>[c.start,c.end]);
  const usages=this.records.size ? [...this.records.values()] : this.fallback ? [this.fallback]:[];
  const inputTotal=sum(usages,'input_tokens'),cacheRead=sum(usages,'cached_input_tokens'),cacheWrite=sum(usages,'cache_write_input_tokens'),output=sum(usages,'output_tokens');
  const totalMs=sum(completed,'durationMs');
  let modelMs=0,toolMs=0,decodeMs=0,reasoningMs=0;
  for(const t of completed){
   if(t.durationMs===null)continue;
   const start=t.end-t.durationMs,end=t.end;
   const ownItems=items.filter(i=>i.turn===t.id);
   const ownCalls=calls.filter(c=>c.turn===t.id&&c.end!==null).map(c=>[c.start,c.end]);
   const clip=xs=>xs.map(([a,b])=>[Math.max(a,start),Math.min(b,end)]).filter(([a,b])=>b>=a);
   const modelSpans=clip(ownItems.filter(i=>i.kind==='Reasoning'||i.kind==='AgentMessage').map(i=>[i.a,i.b]));
   const toolSpans=clip([...ownItems.filter(i=>TOOL_ITEMS.has(i.kind)).map(i=>[i.a,i.b]),...ownCalls]);
   reasoningMs+=windowedSpanMs(clip(ownItems.filter(i=>i.kind==='Reasoning').map(i=>[i.a,i.b])),start,end);
   decodeMs+=windowedSpanMs(clip(ownItems.filter(i=>i.kind==='AgentMessage').map(i=>[i.a,i.b])),start,end);
   const split=this.attributeResidual(start,end,[...modelSpans.map(s=>[...s,'model']),...toolSpans.map(s=>[...s,'tool'])]);
   modelMs+=split.modelMs;toolMs+=split.toolMs;
  }
  // A call still open on the running turn keeps ticking outside any turn window,
  // matching the native projection.
  const ticking=calls.filter(c=>c.end===null&&active&&c.turn===last?.id&&Number.isFinite(c.start)).map(c=>[c.start,now]);
  // A session without a single completed turn has no measured turn window, so
  // every turn-scoped duration stays unknown instead of reading as zero.
  const measured=completed.length>0;
  // A call still open on the running turn keeps ticking outside any turn window,
  // matching the native projection.
  if(ticking.length)toolMs=(toolMs||0)-spanMs(closedSpans)+spanMs([...closedSpans,...ticking]);
  const tps=xs=>{const ms=sum(xs,'ms');return ms>0?sum(xs,'tokens')/(ms/1000):null;};
  return {provider:'codex',model:this.model,excluded:this.excluded,turns:turns.length,completedTurns:completed.length,steps:this.records.size||null,
   active,avgTurnMs:durations.length?durations.reduce((a,b)=>a+b,0)/durations.length:null,turnDurationSamples:durations.length,avgTtftMs:ttfts.length?sum(ttfts,'ttftMs')/ttfts.length:null,ttftSamples:ttfts.length,tps:tps(this.samples),tpsSamples:this.samples.length,tpsTokens:sum(this.samples,'tokens'),tpsDurationMs:sum(this.samples,'ms'),tpsKind:'output_stream',
   llmMs:null,firstTokenWaitMs:null,
   decodeMs:measured?decodeMs:null,reasoningMs:measured?reasoningMs:null,
   modelMs:measured?modelMs:null,toolMs:(measured||ticking.length)?toolMs:null,totalMs:measured?totalMs:null,
   input:Math.max(0,inputTotal-cacheRead-cacheWrite),cacheRead,cacheWrite,output,totalTokens:inputTotal+output,
   cacheHit:inputTotal>0?cacheRead/inputTotal*100:null,reasoningTokens:sum(usages,'reasoning_output_tokens'),
   lastTurn:last?{id:last.id,durationMs:last.durationMs,reason:last.reason||'running',ttftMs:last.ttftMs,tps:tps(this.samples.filter(s=>s.turn===last.id))}:null,
   updatedAt:this.updatedAt,malformedLines:this.issues};
 }
}
