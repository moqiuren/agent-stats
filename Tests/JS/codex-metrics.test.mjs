import test from 'node:test';import assert from 'node:assert/strict';import {CodexMetrics} from './codex-metrics.mjs';
const row=(type,payload,ms)=>({type,payload,timestamp:new Date(ms).toISOString()});
const ev=(type,payload,ms)=>row('event_msg',{type,...payload},ms);
const item=(id,type,phase,a,b)=>ev('item_completed',{turn_id:'t',item:{id,type,phase},started_at_ms:a,completed_at_ms:b},b);
const usage=(id,output,reasoning,ms=9000)=>row('token_usage_record',{turn_id:'t',response_id:id,usage:{input_tokens:100,cached_input_tokens:80,output_tokens:output,reasoning_output_tokens:reasoning}},ms);
test('Codex preserves TTFT units, measures full output stream decode TPS, avoids token double counting',()=>{
 const m=new CodexMetrics();m.accept(ev('task_started',{turn_id:'t'},0));m.accept(row('turn_context',{turn_id:'t',model:'gpt-6.1-sol'},1));
 m.accept(item('r','Reasoning',null,1000,3000));m.accept(item('a','AgentMessage','final_answer',3000,8000));const u=usage('resp',300,50);m.accept(u);m.accept(u);
 m.accept(ev('token_count',{info:{total_token_usage:{input_tokens:999999,output_tokens:888888}}},9001));m.accept(ev('task_complete',{turn_id:'t',duration_ms:10000,time_to_first_token_ms:1200},10000));
 const s=m.snapshot(10000);assert.equal(s.tps,300/7);assert.equal(s.tpsTokens,300);assert.equal(s.tpsDurationMs,7000);assert.equal(s.tpsKind,'output_stream');assert.equal(s.avgTtftMs,1200);assert.equal(s.totalTokens,400);assert.equal(s.input,20);assert.equal(s.cacheHit,80);assert.equal(s.reasoningMs,2000);assert.equal(s.decodeMs,5000);assert.equal(s.modelMs,10000);assert.equal(s.toolMs,0);assert.equal(s.tpsSamples,1);
});
test('Codex decode TPS handles commentary, trailing tool calls, unanchored calls, server tools and tiny spans',()=>{
 const m=new CodexMetrics();m.accept(item('a','AgentMessage','commentary',0,100));m.accept(item('b','AgentMessage','final_answer',200,1000));m.accept(usage('r',100,0));
 assert.equal(m.snapshot().tpsDurationMs,900);assert.equal(m.snapshot().tps,100/0.9);
 const n=new CodexMetrics();n.accept(item('b','AgentMessage','final_answer',200,1000));n.accept(row('response_item',{type:'function_call',call_id:'x'},1500));n.accept(usage('r',100,0));
 assert.equal(n.snapshot().tpsDurationMs,1300);assert.equal(n.snapshot().tps,100/1.3);
 const unanchored=new CodexMetrics();unanchored.accept(row('response_item',{type:'function_call',call_id:'x'},1500));unanchored.accept(usage('r',100,0));
 assert.equal(unanchored.snapshot().tps,null);
 const serverTool=new CodexMetrics();serverTool.accept(item('r','Reasoning',null,100,400));serverTool.accept(ev('item_completed',{turn_id:'t',item:{id:'ws',type:'WebSearch'},started_at_ms:400,completed_at_ms:900},900));serverTool.accept(item('a','AgentMessage','final_answer',900,1200));serverTool.accept(usage('r',100,0));
 assert.equal(serverTool.snapshot().tps,null);
 const tiny=new CodexMetrics();tiny.accept(item('b','AgentMessage','final_answer',100,120));tiny.accept(usage('r',100,0));
 assert.equal(tiny.snapshot().tps,null);
});
test('Codex overlapping tool waits use union and task_aborted or turn_aborted closes pending waits',()=>{
 for(const abortType of ['task_aborted','turn_aborted']){
  const m=new CodexMetrics();m.accept(ev('task_started',{turn_id:'t'},0));
  for(const [id,a,b] of [['a',100,500],['b',200,600]]){m.accept(row('response_item',{type:'function_call',call_id:id},a));m.accept(row('response_item',{type:'function_call_output',call_id:id},b));}
  m.accept(row('response_item',{type:'custom_tool_call',call_id:'c'},700));m.accept(ev(abortType,{turn_id:'t'},1000));
  const s=m.snapshot(100000);assert.equal(s.toolMs,1000);assert.equal(s.active,false);assert.equal(s.completedTurns,1);assert.equal(s.totalMs,1000);
 }
});
test('legacy token totals stay available without fabricated throughput',()=>{const m=new CodexMetrics();m.accept(ev('token_count',{info:{total_token_usage:{input_tokens:100,cached_input_tokens:40,output_tokens:20}}},1));const s=m.snapshot();assert.equal(s.totalTokens,120);assert.equal(s.tps,null);assert.equal(s.avgTtftMs,null);});
test('Codex inherited metadata cannot replace the owning subagent or fork identity',()=>{
 for(const child of [false,true]){
  const m=new CodexMetrics(),source=child?{subagent:{thread_spawn:{parent_thread_id:'parent'}}}:'vscode';
  m.accept(row('session_meta',{id:'owner',source,thread_source:child?'subagent':'user'},0));
  m.accept(row('session_meta',{id:'parent',source:child?'vscode':{subagent:{thread_spawn:{parent_thread_id:'ancestor'}}},thread_source:child?'user':'subagent'},1));
  m.accept(row('session_meta',{id:'owner',agent_nickname:'renamed'},2));
  m.accept(usage('own-request',20,0));
  assert.equal(m.snapshot(10000).excluded,child);
  assert.equal(m.snapshot(10000).totalTokens,120);
 }
});
test('tool item spans clamp to their turn window and residual splits between model and tool',()=>{
 // A CommandExecution whose completed_at_ms is really the next record's write time
 // must not swallow unrelated spans; the clamp leaves the true tool coverage.
 const m=new CodexMetrics();
 m.accept(ev('task_started',{turn_id:'t'},0));
 m.accept(usage('r1',20,5,1000));
 m.accept(item('r','Reasoning',null,2000,2500));
 m.accept(ev('item_completed',{turn_id:'t',item:{id:'c',type:'CommandExecution'},started_at_ms:1500,completed_at_ms:9500},9500));
 m.accept(row('response_item',{type:'function_call',call_id:'c1'},3000));
 m.accept(row('response_item',{type:'function_call_output',call_id:'c1'},3400));
 m.accept(ev('task_complete',{turn_id:'t',duration_ms:10000},10000));
 const s=m.snapshot(11000);
 // The only two buckets: model time (reasoning plus any untracked request
 // overhead) and tool time (clamped tool items plus call spans).
 assert.equal(s.reasoningMs,500);assert.equal(s.toolMs,8500);
 assert.equal(s.modelMs,1500);assert.equal(s.totalMs,10000);
 assert.equal(s.modelMs+s.toolMs,s.totalMs,'the two buckets always sum to the turn duration');
});
test('residual time is attributed to model or tool by the nearest recorded span',()=>{
 // A long stretch with no tool span at all stays model time, whatever its shape.
 const m=new CodexMetrics();
 m.accept(ev('task_started',{turn_id:'t'},0));
 m.accept(usage('r1',20,5,1000));
 m.accept(item('r','Reasoning',null,201000,201500));
 m.accept(ev('task_complete',{turn_id:'t',duration_ms:202000},202000));
 const s=m.snapshot(203000);
 assert.equal(s.modelMs,202000);assert.equal(s.toolMs,0);
 // A gap right after a tool span is tool time (waiting on the command); the rest
 // is model time preparing the next request.
 const n=new CodexMetrics();
 n.accept(ev('task_started',{turn_id:'t'},0));
 n.accept(usage('r1',20,5,1000));
 n.accept(ev('item_completed',{turn_id:'t',item:{id:'c',type:'CommandExecution'},started_at_ms:1000,completed_at_ms:2000},2000));
 n.accept(item('r','Reasoning',null,5000,5500));
 n.accept(ev('task_complete',{turn_id:'t',duration_ms:6000},6000));
 const t=n.snapshot(7000);
 assert.equal(t.toolMs,2000);assert.equal(t.modelMs,4000);assert.equal(t.reasoningMs,500);
});
