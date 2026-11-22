import test from 'node:test';
import assert from 'node:assert/strict';
import {Metrics, spanMs} from './metrics.mjs';
const event=(type, rest, time)=>({type:'context.append_loop_event',time,event:{type,...rest}});
test('weighted throughput and zero TTFT, no double-count of duplicated events',()=>{
 const m=new Metrics();
 m.accept({type:'agent.turn.started',turnId:0,time:0});
 for (let i=0;i<2;i++) {
  const e=event('step.end',{uuid:`s${i}`,turnId:0,step:i+1,finishReason:'end_turn',llmFirstTokenLatencyMs:i*2000,llmStreamDurationMs:i ? 3000:1000,usage:{output:100}},10);
  m.accept(e);m.accept(e);
 }
 const u={type:'usage.record',requestId:'request-one',time:10,model:'m',usageScope:'turn',usage:{inputOther:20,inputCacheRead:80,output:200}};
 m.accept(u);m.accept(u);
 const s=m.snapshot(10000);assert.equal(s.avgTtftMs,1000);assert.equal(s.tps,50);assert.equal(s.tpsTokens,200);assert.equal(s.tpsDurationMs,4000);assert.equal(s.totalTokens,300);assert.equal(s.cacheHit,80);assert.equal(s.steps,2);
});
test('parallel tools count union, completed results are idempotent',()=>{
 assert.equal(spanMs([[0,100],[50,120],[200,250]]),170);
 const m=new Metrics();
 for(const [id,start,end] of [['a',0,100],['b',50,120]]){m.accept(event('tool.call',{toolCallId:id,turnId:0},start));m.accept(event('tool.result',{toolCallId:id},end));m.accept(event('tool.result',{toolCallId:id},end));}
 assert.equal(m.snapshot().toolMs,120);
});
test('missing timing remains unknown and failed steps do not affect TPS',()=>{
 const m=new Metrics();m.accept(event('step.end',{uuid:'a',turnId:0,step:1,finishReason:'end_turn'},100));
 m.accept(event('step.end',{uuid:'b',turnId:0,step:2,finishReason:'error',llmFirstTokenLatencyMs:100,llmStreamDurationMs:1,usage:{output:10000}},200));
 const s=m.snapshot();assert.equal(s.tps,null);assert.equal(s.avgTtftMs,null);assert.equal(s.tpsSamples,0);assert.equal(s.ttftSamples,0);
});
test('cancelled turn does not keep accumulating tool waiting',()=>{
 const m=new Metrics();m.accept({type:'agent.turn.started',turnId:0,time:0});m.accept(event('tool.call',{toolCallId:'a',turnId:0},10));
 m.accept({type:'turn.ended',turnId:0,time:100,durationMs:100,reason:'cancelled'});
 assert.equal(m.snapshot(50000).active,false);assert.equal(m.snapshot(50000).totalMs,100);
});
test('turn.prompt with turnId opens a turn while untagged turn.prompt does not',()=>{
 const m=new Metrics();
 m.accept({type:'turn.prompt',time:0});
 assert.equal(m.snapshot(1000).turns,0);assert.equal(m.snapshot(1000).active,false);
 m.accept({type:'turn.prompt',turnId:1,time:1000});
 assert.equal(m.snapshot(4000).turns,1);assert.equal(m.snapshot(4000).active,true);assert.equal(m.snapshot(4000).totalMs,3000);
 m.accept({type:'turn.ended',turnId:1,time:5000,durationMs:4000,reason:'completed'});
 assert.equal(m.snapshot(10000).active,false);assert.equal(m.snapshot(10000).totalMs,4000);
});
test('buffered sub-50ms and zero-output steps are excluded from TPS while keeping decodeMs',()=>{
 const m=new Metrics();
 m.accept({type:'turn.prompt',turnId:0,time:0});
 m.accept(event('step.end',{uuid:'tiny',turnId:0,step:1,finishReason:'tool_use',llmStreamDurationMs:12,usage:{output:80}},100));
 m.accept(event('step.end',{uuid:'empty',turnId:0,step:2,finishReason:'tool_use',llmStreamDurationMs:200,usage:{output:0}},400));
 m.accept(event('step.end',{uuid:'real',turnId:0,step:3,finishReason:'end_turn',llmStreamDurationMs:1000,usage:{output:50}},1500));
 const s=m.snapshot(2000);
 assert.equal(s.tpsSamples,1);assert.equal(s.tpsTokens,50);assert.equal(s.tpsDurationMs,1000);
 assert.equal(s.tps,50);assert.equal(s.lastTurn.tps,50);assert.equal(s.decodeMs,1212);
});
