import test, {before, after} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import net from 'node:net';
import {createHash} from 'node:crypto';
import {spawnSync, spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {Metrics} from './metrics.mjs';
import {CodexMetrics} from './codex-metrics.mjs';

const work = fs.mkdtempSync(path.join(os.tmpdir(),'stats-native-tests-'));
const binary = path.join(work,'agent-stats-native');
const supportScript = fileURLToPath(new URL('../../Scripts/swiftpm_support.py', import.meta.url));
before(() => {
  const result = spawnSync('python3',[supportScript,'native-driver','--output',binary],{encoding:'utf8'});
  assert.equal(result.status,0,result.stderr);
});
after(() => fs.rmSync(work,{recursive:true,force:true}));
function native(input) {
  const result = spawnSync(binary,[],{input:JSON.stringify(input),encoding:'utf8'});
  assert.equal(result.status,0,result.stderr); return JSON.parse(result.stdout);
}
function parity(provider,records,now=20000) {
  const old = provider==='kimi'?new Metrics():new CodexMetrics();
  records.forEach(r=>old.accept(r));
  const expected=JSON.parse(JSON.stringify(old.snapshot(now))), actual=native({provider,records,now});
  assert.deepEqual(actual,expected);
}
const loop=(type,rest,time)=>({type:'context.append_loop_event',time,event:{type,...rest}});
const row=(type,payload,time)=>({type,payload,timestamp:new Date(time).toISOString()});
const event=(type,payload,time)=>row('event_msg',{type,...payload},time);
function timelineParity(provider, actions) {
  const reference = provider === 'codex' ? new CodexMetrics() : new Metrics();
  const expected = actions.map(action => {
    (action.records ?? []).forEach(record => reference.accept(record));
    if (action.issues !== undefined) reference.issues = action.issues;
    return JSON.parse(JSON.stringify(reference.snapshot(action.now)));
  });
  assert.deepEqual(native({mode:'metrics-timeline', provider, actions}).snapshots, expected);
}
test('cached Codex snapshots preserve ticking tools, expiry, late events and corrected completions', () => {
  const actions = [{now:1000, records:[event('task_started',{turn_id:'a'},0),
    row('response_item',{type:'function_call',call_id:'tool-a'},500)]},
    {now:2000}, {now:120500}, {now:3000},
    {now:4000, records:[event('task_complete',{turn_id:'a',duration_ms:4000,time_to_first_token_ms:0},4000)]},
    {now:5000},
    {now:6000, records:[event('item_completed',{turn_id:'a',item:{id:'late',type:'AgentMessage',phase:'final_answer'},started_at_ms:2000,completed_at_ms:3000},3000),
      row('token_usage_record',{turn_id:'a',response_id:'usage-a',usage:{input_tokens:100,cached_input_tokens:10,output_tokens:20}},3500)]},
    {now:6500, records:[event('task_complete',{turn_id:'a',duration_ms:5000,time_to_first_token_ms:100},5000)]},
    {now:7000, issues:2}];
  for(let i=0;i<20;i++) {
    const start=10000+i*1000, id='b'+i;
    actions.push({now:start+100,records:[event('task_started',{turn_id:id},start),
      row('response_item',{type:'function_call',call_id:id},start+10)]},
      {now:start+200},
      {now:start+300,records:[event(i%2?'task_complete':'task_aborted',{turn_id:id,duration_ms:300},start+300)]},
      {now:start+500});
  }
  timelineParity('codex',actions);
});
test('cached Kimi snapshots preserve running clocks, overlapping tools and revised step metrics', () => {
  const actions=[{now:1000,records:[{type:'agent.turn.started',turnId:0,time:0},
    loop('tool.call',{toolCallId:'a',turnId:0},100),loop('tool.call',{toolCallId:'b',turnId:0},200)]},
    {now:2000}, {now:50},
    {now:2500,records:[loop('tool.result',{toolCallId:'a',turnId:0},2200)]},
    {now:3000,records:[loop('step.end',{uuid:'step',turnId:0,step:0,finishReason:'end_turn',llmFirstTokenLatencyMs:0,llmStreamDurationMs:100,usage:{output:10}},2800)]},
    {now:4000,records:[loop('step.end',{uuid:'step',turnId:0,step:0,finishReason:'end_turn',llmFirstTokenLatencyMs:50,llmStreamDurationMs:200,usage:{output:30}},2900)]},
    {now:5000,records:[{type:'turn.ended',turnId:0,time:4000,durationMs:4000,reason:'cancelled'}]},
    {now:6000}, {now:7000,issues:1},
    {now:9000,records:[{type:'agent.turn.started',turnId:1,time:8000}]},
    {now:10000,records:[{type:'agent.turn.started',turnId:2,time:9000}]},
    {now:11000},
    {now:12000,records:[{type:'turn.ended',turnId:2,time:11500,durationMs:2500,reason:'completed'}]},
    {now:13000}];
  timelineParity('kimi',actions);
});
test('a tool call is bound to the turn it names, never the latest turn',()=>{
  // These expected values pin semantics a JS/native parity comparison cannot:
  // both implementations once bound calls to the latest turn_context, so a late
  // call tagged with a finished turn ticked as the running turn's tool.
  const late=[
    row('turn_context',{turn_id:'t1',model:'gpt-5'},1),
    event('task_started',{turn_id:'t1'},2),
    event('task_complete',{turn_id:'t1',duration_ms:100,time_to_first_token_ms:10},3),
    row('turn_context',{turn_id:'t2',model:'gpt-5'},4),
    event('task_started',{turn_id:'t2'},5),
    row('response_item',{type:'function_call',call_id:'c1',turn_id:'t1'},6)];
  assert.equal(native({provider:'codex',records:late,now:20000}).toolMs,0,'a late call for a finished turn must not tick as the running turn tool');
  parity('codex',late,20000);
  const running=[
    row('turn_context',{turn_id:'t1',model:'gpt-5'},1),
    event('task_started',{turn_id:'t1'},2),
    row('response_item',{type:'function_call',call_id:'c1',turn_id:'t1'},6)];
  assert.equal(native({provider:'codex',records:running,now:20000}).toolMs,19994,'a call the running turn names keeps ticking');
  parity('codex',running,20000);
  const closed=[
    row('turn_context',{turn_id:'t1',model:'gpt-5'},25000),
    event('task_started',{turn_id:'t1'},25001),
    row('response_item',{type:'function_call',call_id:'c1',turn_id:'t1'},30000),
    row('response_item',{type:'function_call_output',call_id:'c1',turn_id:'t1'},30004),
    // The turn window has to contain the call: a call outside the completed
    // window is clamped away rather than counted as that turn's tool time.
    event('item_completed',{turn_id:'t1',item:{id:'solo',type:'Reasoning'},started_at_ms:32000,completed_at_ms:32100},32100),
    event('task_complete',{turn_id:'t1',duration_ms:20000,time_to_first_token_ms:10},35000)];
  // The tool span is 4ms of the 20s window and the rest is model time, so the
  // tool bucket must stay at the measured span instead of absorbing the window.
  assert.equal(native({provider:'codex',records:closed,now:40000}).toolMs,4,'the named turn owns the closed call span');
  assert.equal(native({provider:'codex',records:closed,now:40000}).modelMs,20000-4,'the rest of the window is model time');
  parity('codex',closed,40000);
});
test('native Kimi context length and pending interactions match JS',()=>{
  const records=[{type:'agent.turn.started',turnId:0,time:0},
    {type:'token_counting.measured',agentId:'main',length:5,tokens:28790,time:10},
    {type:'token_counting.measured',agentId:'main',length:11,tokens:29820,time:20},
    {type:'permission.set_mode',agentId:'main',mode:'yolo',time:25},
    {type:'interaction.request',id:'approval_1',kind:'approval',toolCallId:'tool-a',time:30},
    {type:'interaction.request',id:'question_1',kind:'question',toolCallId:'tool-b',time:31}];
  parity('kimi',records);
  parity('kimi',[...records,{type:'interaction.resolved',id:'approval_1',time:40}]);
  parity('kimi',[...records,{type:'turn.ended',turnId:0,time:50,durationMs:50,reason:'completed'}]);
  parity('kimi',[...records,{type:'token_counting.turn_recorded',agentId:'main',length:20,tokens:40000,time:60},
    {type:'permission.set_mode',agentId:'main',mode:'auto',time:61}]);
  parity('kimi',[{type:'interaction.request',id:'ignored',kind:'other',time:5}]);
  parity('kimi',[{type:'token_counting.measured',agentId:'main',tokens:null,time:5}]);
});
test('native Kimi metrics match JS for weighted rates, duplicates, cancelled turns and overlap',()=>{
  for(let n=1;n<=12;n++) {
    const records=[{type:'agent.turn.started',turnId:0,time:0},{type:'profile.bind',modelAlias:'kimi-test',time:0}];
    for(let i=0;i<n;i++) {
      records.push({type:'llm.request',kind:'loop',turnStep:`0.${i}`,modelAlias:`model-${i%2}`,time:i*100});
      const s=loop('step.end',{uuid:`s${i}`,turnId:0,step:i,finishReason:i%3===0?'tool_use':'end_turn',llmFirstTokenLatencyMs:i*10,llmStreamDurationMs:100+i*100,usage:{output:20+i}},i*500);
      records.push(s,s);
      const u={type:'usage.record',requestId:`request-${i}`,time:i*500,model:'test',usageScope:'turn',usage:{inputOther:20,inputCacheRead:80,inputCacheCreation:10,output:20+i}};records.push(u,u);
      records.push(loop('tool.call',{toolCallId:`tool-${i}`,turnId:0},i*100));
      if(i%2)records.push(loop('tool.result',{toolCallId:`tool-${i}`},i*100+200));
    }
    parity('kimi',records);
    parity('kimi',[...records,{type:'turn.ended',turnId:0,time:10000,durationMs:10000,reason:'cancelled'}]);
  }
  parity('kimi',[loop('step.end',{uuid:'missing',turnId:0,step:1,finishReason:'end_turn'},100),loop('step.end',{uuid:'failed',turnId:0,step:2,finishReason:'error',llmFirstTokenLatencyMs:4,llmStreamDurationMs:1,usage:{output:10000}},200)]);
});
test('native Codex metrics match JS across final, ambiguous, tool and legacy samples',()=>{
  for(let n=0;n<12;n++) {
    const records=[event('task_started',{turn_id:'t'},0),row('turn_context',{turn_id:'t',model:'model'},1)];
    records.push(event('item_completed',{turn_id:'t',item:{id:'r',type:'Reasoning'},started_at_ms:1000,completed_at_ms:3000},3000));
    records.push(event('item_completed',{turn_id:'t',item:{id:'a',type:'AgentMessage',phase:'final_answer'},started_at_ms:3000,completed_at_ms:8000},8000));
    if(n%3===1)records.push(event('item_completed',{turn_id:'t',item:{id:'c',type:'AgentMessage',phase:'commentary'},started_at_ms:500,completed_at_ms:1000},1000));
    if(n%3===2)records.push(row('response_item',{type:'function_call',call_id:'tool'},6000));
    if(n%4===3)records.push(event('item_completed',{turn_id:'t',item:{id:'ws',type:'WebSearch'},started_at_ms:100,completed_at_ms:200},200));
    const usage=row('token_usage_record',{turn_id:'t',response_id:'response',usage:{input_tokens:100,cached_input_tokens:60,cache_write_input_tokens:20,output_tokens:300+n,reasoning_output_tokens:n%2?undefined:50}},5000);
    records.push(usage,usage,event('token_count',{info:{total_token_usage:{input_tokens:99999,output_tokens:99999}}},9001));
    parity('codex',records,10000);
    const endType=n%3===0?'task_complete':(n%3===1?'task_aborted':'turn_aborted');
    parity('codex',[...records,event(endType,{turn_id:'t',duration_ms:10000,time_to_first_token_ms:n*100},10000)]);
  }
  parity('codex',[event('token_count',{info:{total_token_usage:{input_tokens:100,cached_input_tokens:40,output_tokens:20}}},1)]);
  parity('codex',[{type:'session_meta',payload:{source:'vscode'},timestamp:'2026-10-02T01:02:03.123987Z'}]);
  parity('kimi',[{type:'turn.prompt',time:0},{type:'turn.prompt',turnId:1,time:1000},
    loop('step.end',{uuid:'tiny',turnId:1,step:1,finishReason:'tool_use',llmStreamDurationMs:15,usage:{output:90}},1100),
    loop('step.end',{uuid:'ok',turnId:1,step:2,finishReason:'end_turn',llmStreamDurationMs:1000,usage:{output:50}},2200),
    {type:'turn.ended',turnId:1,time:3000,durationMs:2000,reason:'completed'}],5000);
});
test('native bridge selection preserves focused tab, draft, unknown, expiry and disable states',()=>{
  const data=(clientId,sessionId,focused=true,known=true)=>({clientId,sessionId,focused,known,visible:true});
  const results=native({mode:'selection',actions:[
    {now:0,data:data('a','session_a')},{now:100,data:data('b','session_b',false)},
    {now:200,data:data('a',null)},{now:300,data:data('a',null,true,false)},
    {now:400,data:data('b','session_b')},{now:8400},{now:8500,data:{...data('b','session_b'),extra:'not allowed'}},
    {now:8600,disable:true},{now:8700,data:data('a','session_a')}
  ]}).results;
  assert.equal(results[1].selection.sessionId,'session_a');
  assert.equal(results[2].selection.known,true);assert.equal(results[2].selection.sessionId,null);
  assert.equal(results[3].selection.known,false);assert.equal(results[4].selection.sessionId,'session_b');
  assert.equal(results[5].selection.status,'waiting');assert.equal(results[6].status,400);
  assert.equal(results[7].selection.status,'disabled');assert.equal(results[8].status,410);
});
function scan(provider,root,selected) {
  const r=spawnSync(binary,['--provider',provider,'--scan',root,...(selected?[selected]:[])],{encoding:'utf8'});
  assert.equal(r.status,0,r.stderr);
  const snapshot=JSON.parse(r.stdout);
  // Optional migration check against a collector built before a structural change.
  // Both processes read only the same synthetic fixture; no host data is involved.
  if(process.env.STATS_REFERENCE_BINARY) {
    const reference=spawnSync(process.env.STATS_REFERENCE_BINARY,['--provider',provider,'--scan',root,...(selected?[selected]:[])],{encoding:'utf8'});
    assert.equal(reference.status,0,reference.stderr);
    assert.deepEqual(canonicalSnapshot(snapshot),canonicalSnapshot(JSON.parse(reference.stdout)));
  }
  return snapshot;
}
function watchCatalog(provider, root) {
  const child=spawn(binary,['--provider',provider,'--watch-catalog',root],{stdio:['pipe','pipe','pipe']});
  let pending='',answers=[],errors='';
  child.stdout.on('data',data=>{
    pending+=data;
    let end;
    while((end=pending.indexOf('\n'))>=0) {answers.push(JSON.parse(pending.slice(0,end)));pending=pending.slice(end+1);}
  });
  child.stderr.on('data',data=>errors+=data);
  return {
    async read(now=10000) {
      const count=answers.length;
      child.stdin.write(JSON.stringify({now})+'\n');
      const deadline=Date.now()+3000;
      while(answers.length===count) {
        assert.ok(Date.now()<deadline,errors||'catalog timed out');
        await new Promise(resolve=>setTimeout(resolve,10));
      }
      return answers.at(-1);
    },
    close() {child.kill();}
  };
}
function canonicalSnapshot(value) {
  if(Array.isArray(value))return value.map(canonicalSnapshot).sort((a,b)=>JSON.stringify(a).localeCompare(JSON.stringify(b)));
  if(value && typeof value==='object')return Object.fromEntries(Object.keys(value).filter(key=>key!=='time').sort().map(key=>[key,canonicalSnapshot(value[key])]));
  return value;
}
// A persisted parse state is only trustworthy if resuming it reproduces the exact
// result of parsing the same files from scratch. The restore counters keep the
// comparison honest: a run that silently re-parsed everything would also agree.
function cacheParity(provider,root,cacheFile,{reset=false,restores}={}) {
  const result=spawnSync(binary,['--provider',provider,'--scan-cache-parity',root,cacheFile,reset?'reset':'keep'],{encoding:'utf8'});
  assert.equal(result.status,0,result.stderr);
  const parsed=JSON.parse(result.stdout);
  if(restores)assert.deepEqual(parsed.restored,restores,'the expected logs must resume a stored state instead of re-parsing');
  // A resumed state that still re-reads its file is not cached at all; the byte
  // counter makes that silent fallback visible even though the result is correct.
  assert.equal(parsed.parsed[1],0,'a fully resumed scan must not re-read any log bytes');
  if(reset)assert.ok(parsed.parsed[0]>0,'the first stored scan must read the logs');
  assert.deepEqual(parsed.runs[0],parsed.cold,'the first stored scan must equal a cold scan');
  assert.deepEqual(parsed.runs[1],parsed.cold,'a restored parse state must equal a cold scan');
  if(process.env.STATS_REFERENCE_BINARY && reset) {
    const previousCache=cacheFile+'.previous';
    const previous=spawnSync(process.env.STATS_REFERENCE_BINARY,['--provider',provider,'--scan-cache-parity',root,previousCache,'reset'],{encoding:'utf8'});
    assert.equal(previous.status,0,previous.stderr);
    const upgraded=spawnSync(binary,['--provider',provider,'--scan-cache-parity',root,previousCache,'keep'],{encoding:'utf8'});
    assert.equal(upgraded.status,0,upgraded.stderr);
    const resumed=JSON.parse(upgraded.stdout), baseline=JSON.parse(previous.stdout);
    assert.equal(resumed.parsed[0],0,'a pre-refactor cache must resume without replaying logs');
    assert.equal(resumed.restored[0],baseline.restored[1]);
    assert.deepEqual(canonicalSnapshot(resumed.cold),canonicalSnapshot(baseline.cold));
    assert.deepEqual(resumed.runs[0],resumed.cold);
  }
  return parsed.cold;
}
test('a persisted parse state resumes logs and always matches a cold scan',()=>{
  const cacheFile=path.join(work,'parse-cache-kimi.json');
  const root=fs.mkdtempSync(path.join(work,'parse-cache-kimi-'));
  const folder=path.join(root,'sessions/wd/session_parity');
  const log=path.join(folder,'agents/main/wire.jsonl');
  fs.mkdirSync(path.dirname(log),{recursive:true});
  fs.writeFileSync(path.join(folder,'state.json'),JSON.stringify({title:'Parity',cwd:'/work/parity'}));
  const records=[
    {type:'metadata',created_at:'2026-01-01T00:00:00Z',time:1},
    {type:'profile.bind',modelAlias:'kimi-k2',time:2},
    {type:'llm.request',kind:'loop',turnId:'t1',turnStep:'t1.1',modelAlias:'kimi-k2',time:3},
    {type:'agent.turn.started',turnId:'t1',time:4},
    loop('step.begin',{uuid:'s1',turnId:'t1',step:1},5),
    loop('step.end',{uuid:'s1',turnId:'t1',step:1,finishReason:'tool_use',llmFirstTokenLatencyMs:180,llmStreamDurationMs:900,usage:{output:120}},6),
    loop('tool.call',{toolCallId:'c1',turnId:'t1'},7),
    {type:'usage.record',requestId:'r1',time:9,usage:{inputOther:10,output:20,inputCacheRead:5,inputCacheCreation:1}},
    {type:'usage.record',time:10,usage:{inputOther:7,output:3}},
    // Host-measured context, permission mode and an unresolved approval must all
    // survive a restored parse instead of silently resetting to nothing.
    {type:'token_counting.measured',agentId:'main',length:5,tokens:28790,time:10},
    {type:'permission.set_mode',agentId:'main',mode:'yolo',time:10},
    {type:'interaction.request',id:'a1',kind:'approval',toolCallId:'c1',time:10},
  ];
  // The turn stays open, so closing it after a restored scan proves the per-turn call
  // index survived the round trip; without it the pending call would never close.
  const closeTurn={type:'turn.ended',turnId:'t1',durationMs:4000,reason:'end_turn',time:11};
  const write=rows=>fs.writeFileSync(log,rows.map(r=>JSON.stringify(r)).join('\n')+'\n');
  write(records);
  const cold=cacheParity('kimi',root,cacheFile,{reset:true,restores:[0,1]});
  assert.equal(cold.sessions.length,1,'the fixture must produce one task');
  assert.ok(cold.sessions[0].steps>0,'the fixture must accumulate measured steps');
  assert.equal(cold.sessions[0].contextTokens,28790,'the host-measured context length is reported');
  assert.equal(cold.sessions[0].permissionMode,'yolo','the recorded permission mode is reported');
  assert.equal(cold.sessions[0].pendingApprovals,1,'an unresolved approval is reported while its turn is open');
  // Growth is resumed from the stored offset instead of re-reading the whole log.
  // The repeated no-request-id record only stays distinct if the stored occurrence
  // counters survive, so a missing counter would silently drop it.
  write(records.concat([{type:'usage.record',requestId:'r2',time:12,usage:{inputOther:4,output:6}},records[8],closeTurn]));
  const grown=cacheParity('kimi',root,cacheFile,{restores:[1,1]});
  assert.equal(grown.sessions[0].totalTokens-cold.sessions[0].totalTokens,20,'the appended request and its repeated twin must both be counted');
  assert.equal(grown.sessions[0].completedTurns,1,'the restored pending call must be closed by the appended turn end');
  assert.equal(grown.sessions[0].pendingApprovals,0,'a restored approval expires once its turn end arrives');
  assert.equal(grown.sessions[0].contextTokens,28790,'a restored parse keeps the context length');
  assert.equal(grown.sessions[0].permissionMode,'yolo','a restored parse keeps the permission mode');
  // The next growth restores that state and adds a second, still-open interaction.
  write(records.concat([{type:'usage.record',requestId:'r2',time:12,usage:{inputOther:4,output:6}},records[8],closeTurn,
    {type:'interaction.request',id:'q1',kind:'question',toolCallId:'c1',time:13},
    {type:'token_counting.measured',agentId:'main',length:9,tokens:40000,time:14}]));
  const waiting=cacheParity('kimi',root,cacheFile,{restores:[1,1]});
  assert.equal(waiting.sessions[0].pendingQuestions,1,'a later unresolved question is reported');
  assert.equal(waiting.sessions[0].pendingApprovals,0,'the earlier approval stays expired across restores');
  assert.equal(waiting.sessions[0].contextTokens,40000,'the newest context measurement wins after a restore');
  assert.equal(waiting.sessions[0].permissionMode,'yolo','the permission mode still comes from the restored state');
  // A replacement, a truncation and a removal must all invalidate the stored state.
  write([{type:'usage.record',requestId:'r3',time:20,usage:{inputOther:1,output:1}}]);
  cacheParity('kimi',root,cacheFile,{restores:[0,1]});
  write([]);
  cacheParity('kimi',root,cacheFile,{restores:[0,1]});
  fs.rmSync(log);
  cacheParity('kimi',root,cacheFile,{restores:[0,0]});
  // A restored file that reappears must parse from the beginning again.
  write(records);
  const clean=cacheParity('kimi',root,cacheFile,{restores:[0,1]});
  // Same byte length and a restored timestamp defeat a size/mtime check, so only the
  // content digests can reject the stale state. The rewritten numbers must be
  // re-read rather than served from the stored parse.
  const original=fs.readFileSync(log,'utf8');
  const modified=original.replace('"inputOther":10','"inputOther":90');
  assert.equal(modified.length,original.length,'the rewrite must keep the byte length');
  const stamp=fs.statSync(log).mtime;
  fs.writeFileSync(log,modified);
  fs.utimesSync(log,stamp,stamp);
  const rewritten=cacheParity('kimi',root,cacheFile,{restores:[0,1]});
  assert.notEqual(rewritten.sessions[0].totalTokens,clean.sessions[0].totalTokens,'a same-size in-place rewrite must not reuse the stored parse');
  // Once the log exceeds the digest window, a change confined to its first bytes
  // leaves the tail digest intact: only the head digest can reject the stale state.
  const padding=[];
  for(let i=0;i<120;i++)padding.push({type:'usage.record',requestId:'pad'+i,time:100+i,usage:{inputOther:1,output:1}});
  write(records.concat(padding));
  const padded=cacheParity('kimi',root,cacheFile,{restores:[0,1]});
  const long=fs.readFileSync(log,'utf8');
  assert.ok(long.length>8192,'the fixture must exceed the digest window');
  const tweaked=long.replace('"requestId":"r1"','"requestId":"r7"');
  assert.notEqual(tweaked,long,'the head rewrite must apply');
  assert.equal(tweaked.length,long.length,'the head rewrite must keep the byte length');
  assert.equal(tweaked.slice(-4096),long.slice(-4096),'the head rewrite must leave the tail digest intact');
  const longStamp=fs.statSync(log).mtime;
  fs.writeFileSync(log,tweaked);
  fs.utimesSync(log,longStamp,longStamp);
  const retweaked=cacheParity('kimi',root,cacheFile,{restores:[0,1]});
  assert.equal(retweaked.sessions[0].totalTokens,padded.sessions[0].totalTokens,'a head-only rewrite must be re-parsed');
  // A malformed line must also survive the round trip instead of being forgotten.
  fs.appendFileSync(log,'{"type":"context.append_loop_event"\n');
  cacheParity('kimi',root,cacheFile,{restores:[1,1]});
});
test('a persisted parse state covers Codex inherited metadata, tools and fallbacks',async()=>{
  const {DatabaseSync}=await import('node:sqlite');
  const cacheFile=path.join(work,'parse-cache-codex.json');
  const root=fs.mkdtempSync(path.join(work,'parse-cache-codex-'));
  fs.mkdirSync(path.join(root,'sessions'));
  const db=new DatabaseSync(path.join(root,'state_5.sqlite'));
  db.exec('CREATE TABLE threads(id TEXT,title TEXT,rollout_path TEXT,archived INTEGER,updated_at INTEGER,thread_source TEXT,parent_thread_id TEXT,cwd TEXT)');
  const owner='rollout-2026-10-11T00-00-00-01a10d09-bec0-7c43-934e-681873d9cacb';
  const childLog=path.join(root,'sessions',owner+'.jsonl');
  const log=path.join(root,'sessions','child.jsonl');
  const ownerRows=[
    row('session_meta',{id:owner,cwd:'/work/a',source:'user'},1),
    row('turn_context',{turn_id:'t1',model:'gpt-5'},2),
    event('task_started',{turn_id:'t1'},3),
    event('item_completed',{turn_id:'t1',started_at_ms:10,completed_at_ms:400,item:{id:'m1',type:'AgentMessage',phase:'final_answer'}},4),
    row('response_item',{type:'function_call',call_id:'c1',turn_id:'t1'},5),
    row('response_item',{type:'function_call_output',call_id:'c1',turn_id:'t1'},6),
    row('token_usage_record',{response_id:'req1',turn_id:'t1',usage:{input_tokens:100,cached_input_tokens:20,cache_write_input_tokens:5,output_tokens:40,reasoning_output_tokens:10}},7),
    event('task_complete',{turn_id:'t1',duration_ms:900,time_to_first_token_ms:120},8),
  ];
  fs.writeFileSync(childLog,ownerRows.map(r=>JSON.stringify(r)).join('\n')+'\n');
  // The child inherits its parent's header after its own, which must not rewrite identity.
  const childRows=[
    row('session_meta',{id:'child',cwd:'/work/a',thread_source:'subagent',parent_thread_id:owner},1),
    row('session_meta',{id:owner,cwd:'/work/a',source:'user'},2),
    row('token_usage_record',{turn_id:'t2',usage:{input_tokens:5,output_tokens:5}},3),
  ];
  fs.writeFileSync(log,childRows.map(r=>JSON.stringify(r)).join('\n')+'\n');
  db.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?,?,?)').run(owner,'Owner',childLog,0,1,'user',null,'/work/a');
  db.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?,?,?)').run('child','Child',log,0,2,'subagent',owner,'/work/a');
  try {
    const cold=cacheParity('codex',root,cacheFile,{reset:true,restores:[0,2]});
    assert.equal(cold.sessions.length,1,'the subagent must join its parent task');
    assert.equal(cold.agents.length,2,'both rollouts must be parsed');
    fs.appendFileSync(log,JSON.stringify(row('token_usage_record',{response_id:'req2',turn_id:'t2',usage:{input_tokens:7,output_tokens:3}},4))+'\n');
    const grown=cacheParity('codex',root,cacheFile,{restores:[2,2]});
    assert.ok(grown.sessions[0].totalTokens>cold.sessions[0].totalTokens,'the appended request must be counted');
    db.exec("UPDATE threads SET cwd='/work/b' WHERE id='child'");
    cacheParity('codex',root,cacheFile,{restores:[2,2]});
  } finally {db.close();}
});
test('warm Kimi accounting agrees with fresh scans after ownership, metadata and file changes',async()=>{
  const root=fs.mkdtempSync(path.join(work,'accounting-cache-kimi-'));
  const folders=['session_a','session_b'].map(id=>path.join(root,'sessions/wd',id));
  const logs=folders.map(folder=>path.join(folder,'agents/main/wire.jsonl'));
  const usage=(id,input=10)=>JSON.stringify({type:'usage.record',requestId:id,time:1,usage:{inputOther:input,output:20}})+'\n';
  for(let i=0;i<folders.length;i++) {
    fs.mkdirSync(path.dirname(logs[i]),{recursive:true});
    fs.writeFileSync(path.join(folders[i],'state.json'),JSON.stringify({title:'Original',cwd:'/work/a'}));
    fs.writeFileSync(logs[i],usage('shared'));
  }
  const watcher=watchCatalog('kimi',root);
  const check=async()=>assert.deepEqual(canonicalSnapshot(await watcher.read()),canonicalSnapshot(scan('kimi',root)));
  try {
    await check();await check();
    fs.appendFileSync(logs[0],usage('new-request'));await check();
    fs.writeFileSync(path.join(folders[1],'state.json'),JSON.stringify({title:'Renamed',cwd:'/work/b'}));await check();
    fs.writeFileSync(logs[1],usage('shared',90));fs.utimesSync(logs[1],new Date(),new Date(Date.now()+10000));await check();
    fs.writeFileSync(logs[1],'');await check();
    fs.rmSync(logs[1]);await check();
    fs.writeFileSync(logs[1],usage('restored'));await check();
    fs.writeFileSync(path.join(folders[1],'state.json'),JSON.stringify({title:'Archived',archived:true}));await check();
    fs.writeFileSync(path.join(folders[1],'state.json'),JSON.stringify({title:'Restored',cwd:'/work/a'}));await check();
  } finally {watcher.close();}
});
test('warm Codex accounting invalidates shared ownership when an explicit parent or project changes',async()=>{
  const {DatabaseSync}=await import('node:sqlite');
  const root=fs.mkdtempSync(path.join(work,'accounting-cache-codex-'));
  fs.mkdirSync(path.join(root,'sessions'));
  const db=new DatabaseSync(path.join(root,'state_5.sqlite'));
  db.exec('CREATE TABLE threads(id TEXT,title TEXT,rollout_path TEXT,archived INTEGER,updated_at INTEGER,thread_source TEXT,parent_thread_id TEXT,cwd TEXT)');
  for(const [id,parent] of [['a',null],['b',null],['child','a']]) {
    const log=path.join(root,'sessions',id+'.jsonl');
    fs.writeFileSync(log,JSON.stringify(row('token_usage_record',{response_id:'shared',usage:{input_tokens:100,output_tokens:20}},1))+'\n');
    db.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?,?,?)').run(id,id,log,0,1,parent?'subagent':'user',parent,'/work/a');
  }
  const watcher=watchCatalog('codex',root);let now=10000;
  const check=async()=>{now+=6000;assert.deepEqual(canonicalSnapshot(await watcher.read(now)),canonicalSnapshot(scan('codex',root)));};
  try {
    await check();await check();
    db.exec("UPDATE threads SET parent_thread_id='b' WHERE id='child'");await check();
    db.exec("UPDATE threads SET cwd='/work/b' WHERE id='b'");await check();
    db.exec("UPDATE threads SET archived=1 WHERE id='a'");await check();
    db.exec("UPDATE threads SET parent_thread_id='missing' WHERE id='child'");await check();
  } finally {watcher.close();db.close();}
});
test('native Kimi catalog hides archived sessions and does not serialize conversations',()=>{
  const root=fs.mkdtempSync(path.join(work,'kimi-catalog-'));
  for(const [id,archived] of [['session_a',false],['session_b',true]]) {
    const folder=path.join(root,'sessions/wd/'+id);fs.mkdirSync(path.join(folder,'agents/main'),{recursive:true});
    fs.writeFileSync(path.join(folder,'state.json'),JSON.stringify({title:'会话',archived}));
    fs.writeFileSync(path.join(folder,'agents/main/wire.jsonl'),[
      {type:'context.append_message',message:{content:'SECRET_SENTINEL'},time:1},
      {type:'usage.record',usage:{inputOther:10,output:20},time:2}
    ].map(JSON.stringify).join('\n')+'\n{"partial":');
  }
  const result=scan('kimi',root);assert.equal(result.sessions.length,1);assert.equal(result.sessions[0].totalTokens,30);assert.ok(!JSON.stringify(result).includes('SECRET_SENTINEL'));
});
test('native Kimi subagent identity, background tasks and waiting state come from host records',()=>{
  const root=fs.mkdtempSync(path.join(work,'kimi-tasks-')),session=path.join(root,'sessions/wd/session_a');
  fs.mkdirSync(path.join(session,'agents/main/tasks'),{recursive:true});
  fs.mkdirSync(path.join(session,'agents/worker'),{recursive:true});
  fs.writeFileSync(path.join(session,'state.json'),JSON.stringify({title:'父任务',agents:{main:{},worker:{parentAgentId:'main',labels:{profileName:'coder'}},
    swarm:{parentAgentId:'main',labels:{swarmItem:'WS0(地基与契约冻结)。'+'X'.repeat(5000)}}}}));
  fs.mkdirSync(path.join(session,'agents/swarm'),{recursive:true});
  fs.writeFileSync(path.join(session,'agents/swarm/wire.jsonl'),JSON.stringify({type:'usage.record',usage:{inputOther:1,output:1},time:8})+'\n');
  fs.writeFileSync(path.join(session,'agents/main/tasks/agent-x.json'),JSON.stringify({taskId:'agent-x',kind:'agent',agentId:'worker',description:' 曲库页面\n实现 ',subagentType:'coder',model:'kimi-code/k3',thinkingEffort:'max',status:'completed',startedAt:1,endedAt:2}));
  fs.writeFileSync(path.join(session,'agents/main/tasks/bash-y.json'),JSON.stringify({taskId:'bash-y',kind:'process',description:'npm run dev',status:'running',startedAt:5,command:'npm run dev'}));
  fs.writeFileSync(path.join(session,'agents/main/tasks/bad.json'),'{"kind":"agent","taskId":"unterminated"');
  fs.writeFileSync(path.join(session,'agents/main/tasks/unknown.json'),JSON.stringify({taskId:'unknown',kind:'other',description:'ignored'}));
  fs.writeFileSync(path.join(session,'agents/main/wire.jsonl'),[
    {type:'token_counting.measured',agentId:'main',tokens:134088,time:10},
    {type:'permission.set_mode',agentId:'main',mode:'auto',time:11},
    {type:'interaction.request',id:'approval_1',kind:'approval',time:12},
    {type:'interaction.request',id:'question_1',kind:'question',time:13},
    {type:'usage.record',usage:{inputOther:10,output:20},time:14},
    {type:'agent.turn.started',turnId:0,time:15},
    {type:'context.append_message',message:{content:'SECRET_SENTINEL'},time:16}].map(JSON.stringify).join('\n')+'\n');
  fs.writeFileSync(path.join(session,'agents/worker/wire.jsonl'),JSON.stringify({type:'usage.record',usage:{inputOther:1,output:2},time:9})+'\n');
  const result=scan('kimi',root),task=result.sessions[0],worker=task.agents.find(a=>a.agentID==='worker');
  assert.equal(worker.nickname,'曲库页面 实现','the parent task record names the subagent');
  assert.equal(worker.agentType,'coder');assert.equal(worker.agentStatus,'completed');assert.equal(worker.agentEffort,'max');
  assert.equal(worker.model,'kimi-code/k3','a model the wire log lacks is filled from the task record');
  assert.equal(task.backgroundRunning,1);assert.equal(task.backgroundTotal,1);
  assert.deepEqual(task.backgroundItems.map(i=>i.description),['npm run dev']);
  assert.equal(task.contextTokens,134088,'the host-measured context length is reported as a length only');
  assert.equal(task.pendingApprovals,1);assert.equal(task.pendingQuestions,1);assert.equal(task.permissionMode,'auto');
  assert.ok(!JSON.stringify(result).includes('SECRET_SENTINEL'),'task records never leak conversation content');
  const swarm=task.agents.find(a=>a.agentID==='swarm');
  assert.equal(swarm.nickname,'WS0(地基与契约冻结)…','a swarm brief is reduced to a bounded first sentence');
  assert.ok(!JSON.stringify(result).includes('X'.repeat(200)),'a swarm brief is never copied wholesale into a scan');
  const closed=scan('kimi',root);
  assert.equal(closed.sessions[0].pendingApprovals,1,'a closed scan does not invent a second resolution');
});
test('native Kimi waiting state expires once its turn ends',()=>{
  const root=fs.mkdtempSync(path.join(work,'kimi-waiting-')),session=path.join(root,'sessions/wd/session_a');
  fs.mkdirSync(path.join(session,'agents/main'),{recursive:true});
  fs.writeFileSync(path.join(session,'state.json'),JSON.stringify({title:'等待',agents:{main:{}}}));
  const write=rows=>fs.writeFileSync(path.join(session,'agents/main/wire.jsonl'),rows.map(JSON.stringify).join('\n')+'\n');
  write([{type:'agent.turn.started',turnId:0,time:1},{type:'interaction.request',id:'q',kind:'question',time:2}]);
  assert.equal(scan('kimi',root).sessions[0].pendingQuestions,1);
  write([{type:'agent.turn.started',turnId:0,time:1},{type:'interaction.request',id:'q',kind:'question',time:2},
    {type:'interaction.resolved',id:'q',time:3},{type:'turn.ended',turnId:0,time:4,durationMs:3,reason:'completed'}]);
  assert.equal(scan('kimi',root).sessions[0].pendingQuestions,0,'a resolved and finished interaction is not still waiting');
  write([{type:'agent.turn.started',turnId:0,time:1},{type:'turn.ended',turnId:0,time:4,durationMs:3,reason:'completed'}]);
  assert.equal(scan('kimi',root).sessions[0].pendingApprovals,0);
  const empty=fs.mkdtempSync(path.join(work,'kimi-waiting-empty-')),missing=path.join(empty,'sessions/wd/session_b');
  fs.mkdirSync(path.join(missing,'agents/main'),{recursive:true});
  fs.writeFileSync(path.join(missing,'state.json'),JSON.stringify({title:'无日志',agents:{main:{}}}));
  assert.equal(scan('kimi',empty).sessions[0].pendingApprovals,null,'a missing log never becomes zero waiting requests');
});
test('native Kimi task records are reused until their file changes',async()=>{
  const root=fs.mkdtempSync(path.join(work,'kimi-task-cache-')),session=path.join(root,'sessions/wd/session_a');
  fs.mkdirSync(path.join(session,'agents/main/tasks'),{recursive:true});
  fs.writeFileSync(path.join(session,'agents/main/wire.jsonl'),JSON.stringify({type:'usage.record',usage:{inputOther:1,output:1},time:1})+'\n');
  // Padding keeps the byte size identical so only the modification date can make the
  // reader read the record again.
  const file=path.join(session,'agents/main/tasks/bash-y.json');
  const writeTask=status=>fs.writeFileSync(file,JSON.stringify({taskId:'bash-y',kind:'process',description:'npm run dev',status,startedAt:5}).padEnd(200,' '));
  writeTask('running');
  const watcher=watchCatalog('kimi',root);
  try {
    assert.equal((await watcher.read()).sessions[0].backgroundRunning,1,'a running host task is reported');
    assert.equal((await watcher.read()).sessions[0].backgroundRunning,1,'an unchanged task record stays reported');
    writeTask('completed');
    const finished=await watcher.read();
    assert.equal(finished.sessions[0].backgroundRunning,0,'a rewritten task record is read again instead of reusing the cached state');
    assert.equal(finished.sessions[0].backgroundTotal,1,'the rewritten record still counts as one host task');
    await new Promise(resolve=>setTimeout(resolve,1100));
    writeTask('running');
    assert.equal((await watcher.read()).sessions[0].backgroundRunning,1,'a later rewrite is picked up as well');
  } finally {watcher.close();}
});
test('native hook reports validate events and never store conversation content',()=>{
  const support=fs.mkdtempSync(path.join(work,'hook-support-'));
  const record=payload=>spawnSync(binary,[],{input:JSON.stringify({mode:'hook-record',support,payload}),encoding:'utf8'});
  const stop=record({session_id:'session_test',hook_event_name:'Stop',source:'resume',client_type:'kimi_code_desktop',
    session_title:'标题\n换行',model:'kimi-code/k3',prompt:'SECRET_SENTINEL',tool_input:{command:'SECRET_SENTINEL'},tool_output:'SECRET_SENTINEL',response:'SECRET_SENTINEL'});
  assert.equal(stop.status,0,stop.stderr);
  const stored=JSON.parse(fs.readFileSync(path.join(support,'hook-context.json'),'utf8'));
  assert.equal(stored.event,'Stop');assert.equal(stored.sessionId,'session_test');assert.equal(stored.title,'标题 换行');
  assert.equal(stored.model,'kimi-code/k3');
  assert.ok(!JSON.stringify(stored).includes('SECRET_SENTINEL'),'prompt, tool and reply fields are never persisted');
  for(const payload of [{session_id:'session_test',hook_event_name:'BogusEvent'},{session_id:'nope',hook_event_name:'Stop'},{hook_event_name:'Stop'}]){
    const rejected=record(payload);
    assert.notEqual(rejected.status,0,'an invalid lifecycle report is refused');
    assert.equal(rejected.status,1,'hook failures never use the host reserved block exit code');
  }
  assert.equal(JSON.parse(fs.readFileSync(path.join(support,'hook-context.json'),'utf8')).event,'Stop','a refused report leaves the previous one intact');
  assert.equal(record({session_id:'session_test',hook_event_name:'PostToolUse',tool_name:'Bash'}).status,0,'a manually registered host event stays readable');
  assert.equal(record({session_id:'session_test',hook_event_name:'SessionStart',source:'startup'}).status,0);
  assert.equal(JSON.parse(fs.readFileSync(path.join(support,'hook-context.json'),'utf8')).event,'SessionStart');
  // One oversized label must not push the report past the reader's size limit,
  // which would silence every later hook event until another write.
  assert.equal(record({session_id:'session_test',hook_event_name:'Stop',source:'S'.repeat(40000),client_type:'C'.repeat(40000)}).status,0);
  const bounded=JSON.parse(fs.readFileSync(path.join(support,'hook-context.json'),'utf8'));
  assert.equal(bounded.source.length,200,'stored labels are bounded');
  assert.equal(bounded.clientType.length,200,'stored labels are bounded');
  assert.ok(fs.statSync(path.join(support,'hook-context.json')).size<4096,'a single report stays readable by the hook reader');
});
test('native Codex reads SQLite without writes and loads local agent accounting',async()=>{
  const {DatabaseSync}=await import('node:sqlite');const root=fs.mkdtempSync(path.join(work,'codex-catalog-'));
  const db=new DatabaseSync(path.join(root,'state_5.sqlite'));
  db.exec('CREATE TABLE threads(id TEXT,title TEXT,rollout_path TEXT,archived INTEGER,updated_at INTEGER,thread_source TEXT,source TEXT)');
  const dir=path.join(root,'sessions');fs.mkdirSync(dir);
  for(const [id,updated,archived,source] of [['older',1,0,'user'],['newer',2,0,'user'],['child',3,0,'subagent'],['archived',4,1,'user']]){
    const file=path.join(dir,id+'.jsonl');fs.writeFileSync(file,JSON.stringify(event('token_count',{info:{total_token_usage:{input_tokens:100,output_tokens:20}}},1))+'\n');
    db.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?,?)').run(id,id,file,archived,updated,source,'vscode');
  }
  db.close();const before=fs.readFileSync(path.join(root,'state_5.sqlite'));
  const result=scan('codex',root);assert.deepEqual(result.sessions.map(s=>s.id),['__agent__:child','newer','older']);assert.equal(result.sessions[1].totalTokens,120);assert.equal(result.sessions[2].loaded,true);
  const selected=scan('codex',root,'older');assert.equal(selected.sessions[0].loaded,true);assert.equal(selected.sessions[2].totalTokens,120);
  assert.deepEqual(fs.readFileSync(path.join(root,'state_5.sqlite')),before);
  const edit=new DatabaseSync(path.join(root,'state_5.sqlite'));edit.exec('UPDATE threads SET archived=1');edit.close();assert.equal(scan('codex',root).sessions.length,0);
});
test('Codex catalog uses the real name, then the session index, never a known first-message placeholder',async()=>{
  const {DatabaseSync}=await import('node:sqlite');const root=fs.mkdtempSync(path.join(work,'codex-titles-'));
  const db=new DatabaseSync(path.join(root,'state_5.sqlite'));
  db.exec('CREATE TABLE threads(id TEXT,title TEXT,rollout_path TEXT,archived INTEGER,updated_at INTEGER,thread_source TEXT,source TEXT,name TEXT,first_user_message TEXT)');
  const dir=path.join(root,'sessions');fs.mkdirSync(dir);
  const prompt='第一条消息\n'+ '很长的上下文\n'.repeat(40);
  for(const [id,name] of [['named','重命名后的会话'],['indexed',''],['unknown',null]]){
    const file=path.join(dir,id+'.jsonl');fs.writeFileSync(file,JSON.stringify(event('token_count',{info:{total_token_usage:{input_tokens:100,output_tokens:20}}},1))+'\n');
    db.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?,?,?,?)').run(id,prompt,file,0,1,'user','vscode',name,prompt);
  }
  db.close();fs.writeFileSync(path.join(root,'session_index.jsonl'),[
    {id:'named',thread_name:'旧索引名称',updated_at:'2026-10-01T00:00:00Z'},
    {id:'indexed',thread_name:'索引中的会话名称',updated_at:'2026-10-02T00:00:00Z'},
    {id:'indexed',thread_name:'更旧的名称',updated_at:'2026-10-01T00:00:00Z'}
  ].map(JSON.stringify).join('\n')+'\n');
  const titles=Object.fromEntries(scan('codex',root).sessions.map(s=>[s.id,s.title]));
  assert.equal(titles.named,'重命名后的会话');assert.equal(titles.indexed,'索引中的会话名称');assert.equal(titles.unknown,'未命名会话 · unknown');
});
test('older Codex schemas also consult the session index when their database is available',async()=>{
  const {DatabaseSync}=await import('node:sqlite');const root=fs.mkdtempSync(path.join(work,'codex-old-titles-'));
  const db=new DatabaseSync(path.join(root,'state_5.sqlite'));
  db.exec('CREATE TABLE threads(id TEXT,title TEXT,rollout_path TEXT,archived INTEGER,updated_at INTEGER,thread_source TEXT,source TEXT)');
  const dir=path.join(root,'sessions');fs.mkdirSync(dir);const file=path.join(dir,'thread.jsonl');fs.writeFileSync(file,'{}\n');
  db.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?,?)').run('thread','首条消息',file,0,1,'user','vscode');db.close();
  fs.writeFileSync(path.join(root,'session_index.jsonl'),JSON.stringify({id:'thread',thread_name:'真实名称'})+'\n');
  assert.equal(scan('codex',root).sessions[0].title,'真实名称');
});
test('Kimi titles use state metadata, normalize whitespace and handle missing titles',()=>{
  const root=fs.mkdtempSync(path.join(work,'kimi-titles-'));
  for(const [id,title] of [['session_named','  自定义\r\n会话\t名称  '],['session_empty',' \n\t '],['session_null',null]]){
    const folder=path.join(root,'sessions/wd/'+id);fs.mkdirSync(path.join(folder,'agents/main'),{recursive:true});
    fs.writeFileSync(path.join(folder,'state.json'),JSON.stringify({title,isCustomTitle:true,lastPrompt:'不应使用这条消息'}));
    fs.writeFileSync(path.join(folder,'agents/main/wire.jsonl'),'{}\n');
  }
  const titles=Object.fromEntries(scan('kimi',root).sessions.map(s=>[s.id,s.title]));
  assert.equal(titles.session_named,'自定义 会话 名称');assert.equal(titles.session_empty,'未命名会话 · empty');assert.equal(titles.session_null,'未命名会话 · null');
});
test('both running catalog readers pick up host renames without restarting',async()=>{
  const {DatabaseSync}=await import('node:sqlite');
  for(const provider of ['codex','kimi']) {
    const root=fs.mkdtempSync(path.join(work,provider+'-rename-'));let update;
    if(provider==='codex'){
      const db=new DatabaseSync(path.join(root,'state_5.sqlite'));db.exec('CREATE TABLE threads(id TEXT,title TEXT,rollout_path TEXT,archived INTEGER,updated_at INTEGER,thread_source TEXT,source TEXT,name TEXT)');
      fs.mkdirSync(path.join(root,'sessions'));const file=path.join(root,'sessions/thread.jsonl');fs.writeFileSync(file,'{}\n');
      db.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?,?,?)').run('thread','首条消息',file,0,1,'user','vscode','旧名称');
      update=()=>db.exec("UPDATE threads SET name='新名称'");
      // Keep this test DB alive until its reader process has consumed the update.
      update.close=()=>db.close();
    } else {
      const folder=path.join(root,'sessions/wd/session_thread');fs.mkdirSync(path.join(folder,'agents/main'),{recursive:true});fs.writeFileSync(path.join(folder,'agents/main/wire.jsonl'),'{}\n');
      const state=path.join(folder,'state.json');fs.writeFileSync(state,JSON.stringify({title:'旧名称'}));
      update=()=>fs.writeFileSync(state,JSON.stringify({title:'新名称',isCustomTitle:true}));update.close=()=>{};
    }
    const child=spawn(binary,['--provider',provider,'--watch-catalog',root],{stdio:['pipe','pipe','pipe']});let pending='',answers=[],errors='';
    child.stdout.on('data',data=>{pending+=data;let i;while((i=pending.indexOf('\n'))>=0){answers.push(JSON.parse(pending.slice(0,i)));pending=pending.slice(i+1);}});child.stderr.on('data',data=>errors+=data);
    async function read(now){const previous=answers.length;child.stdin.write(JSON.stringify({now})+'\n');const deadline=Date.now()+3000;while(answers.length===previous){assert.ok(Date.now()<deadline,errors||'catalog timed out');await new Promise(r=>setTimeout(r,10));}return answers.at(-1);}
    try {
      assert.equal((await read(10000)).sessions[0].title,'旧名称');update();assert.equal((await read(16000)).sessions[0].title,'新名称');
      const file=path.join(root,provider==='codex'?'sessions/thread.jsonl':'sessions/wd/session_thread/agents/main/wire.jsonl');
      fs.writeFileSync(file+'.replacement',JSON.stringify(provider==='codex'?row('token_usage_record',{response_id:'cached',usage:{input_tokens:10,output_tokens:20}},2):{type:'usage.record',requestId:'cached',usage:{inputOther:10,output:20}})+'\n');
      fs.renameSync(file+'.replacement',file);
      assert.equal((await read(22000)).sessions[0].totalTokens,30);
      fs.rmSync(file);const missing=await read(28000);assert.equal(missing.sessions[0].totalTokens,null);assert.equal(missing.sessions[0].observedRequestTokens,0,'deleted logs cannot retain cached billing');
    }
    finally {child.kill();update.close();}
  }
});
test('native JSONL handles split UTF-8, half lines, file truncation and replacement without recounting',async()=>{
  const file=path.join(work,'incremental.jsonl');const event={type:'usage.record',model:'中文🙂',time:2,usage:{inputOther:10,output:20}};
  const line=Buffer.from(JSON.stringify(event)+'\n'), cut=line.indexOf(Buffer.from('中'))+1;fs.writeFileSync(file,line.subarray(0,cut));
  const child=spawn(binary,['--provider','kimi','--watch',file],{stdio:['pipe','pipe','pipe']});let pending='',answers=[],error='';
  child.stdout.on('data',data=>{pending+=data;let i;while((i=pending.indexOf('\n'))>=0){answers.push(JSON.parse(pending.slice(0,i)));pending=pending.slice(i+1);}});child.stderr.on('data',data=>error+=data);
  async function read(){const count=answers.length;child.stdin.write('{"now":10000}\n');const until=Date.now()+3000;while(answers.length===count){assert.ok(Date.now()<until,error||'native read timeout');await new Promise(r=>setTimeout(r,10));}return answers.at(-1);}
  try{
    assert.equal((await read()).totalTokens,0);fs.appendFileSync(file,line.subarray(cut));assert.equal((await read()).totalTokens,30);assert.equal((await read()).totalTokens,30);
    fs.writeFileSync(file,'');assert.equal((await read()).totalTokens,0);
    fs.writeFileSync(file+'.new',line);fs.renameSync(file+'.new',file);assert.equal((await read()).totalTokens,30);
  }finally{child.kill();}
});
test('native HTTP bridge validates authentication, origin, body size and local selection',async()=>{
  const reserve=net.createServer();await new Promise(r=>reserve.listen(0,'127.0.0.1',r));const port=reserve.address().port;await new Promise(r=>reserve.close(r));
  const config=path.join(work,'bridge.json');fs.writeFileSync(config,JSON.stringify({port,key:'test-pairing-key'}));
  const child=spawn(binary,['--provider','kimi','--bridge',config],{stdio:'ignore'});
  const request=(route,body={},headers={},method='POST')=>new Promise((resolve,reject)=>{
    const data=JSON.stringify(body);const req=http.request({host:'127.0.0.1',port,path:route,method,headers:{'Content-Type':'application/json','Content-Length':Buffer.byteLength(data),'X-Agent-Stats-Key':'test-pairing-key',...headers}},res=>{let body='';res.on('data',d=>body+=d);res.on('end',()=>resolve({status:res.statusCode,headers:res.headers,body}));});req.on('error',reject);req.end(data);
  });
  try{
    const until=Date.now()+5000;while(true){try{await request('/state');break;}catch(e){if(Date.now()>until)throw e;await new Promise(r=>setTimeout(r,20));}}
    assert.equal((await request('/state',{}, {'X-Agent-Stats-Key':'wrong'})).status,401);
    assert.equal((await request('/state',{}, {Origin:'https://evil.example'})).status,403);
    const preflight=await request('/kimi-selection',{}, {Origin:'app://renderer'},'OPTIONS');assert.equal(preflight.status,204);assert.equal(preflight.headers['access-control-allow-origin'],'app://renderer');
    assert.equal((await request('/kimi-selection',{clientId:'test',known:true,sessionId:'session_live',focused:true,visible:true})).status,204);
    assert.equal(JSON.parse((await request('/state')).body).sessionId,'session_live');
    assert.equal((await request('/kimi-selection',{message:'x'.repeat(2000)})).status,413);
    assert.equal((await request('/disable')).status,200);
    assert.equal((await request('/kimi-selection',{clientId:'test',known:true,sessionId:null,focused:true,visible:true})).status,410);
  }finally{child.kill();}
});

test('native bridge uninstall preserves host updates and refuses conflicting assets or backups',()=>{
  const hash=data=>createHash('sha256').update(data).digest('hex');
  const begin='<!-- AgentStats Kimi Bridge v1 BEGIN -->',end='<!-- AgentStats Kimi Bridge v1 END -->';
  for(const scenario of ['original','new-host','other-edit','asset-conflict','backup-conflict']) {
    const support=fs.mkdtempSync(path.join(work,'restore-')),folder=path.join(support,'kimi-bridge'),renderer=path.join(support,'renderer');
    fs.mkdirSync(folder);fs.mkdirSync(path.join(renderer,'assets'),{recursive:true});
    const original='<body>original</body>',patched=`<body>original${begin}\n<script defer src="/assets/agent-stats-kimi-bridge.js"></script>\n${end}\n</body>`,asset='paired-bridge';
    fs.writeFileSync(path.join(folder,'manifest.json'),JSON.stringify({renderer,asset:'assets/agent-stats-kimi-bridge.js',originalSha256:hash(original),patchedSha256:hash(patched),assetSha256:hash(asset)}));
    fs.writeFileSync(path.join(folder,'original-index.html'),scenario==='backup-conflict'?'changed':original);
    const html=scenario==='new-host'?'<body>updated host</body>':scenario==='other-edit'?patched.replace('original','other edit'):patched;
    fs.writeFileSync(path.join(renderer,'index.html'),html);fs.writeFileSync(path.join(renderer,'assets/agent-stats-kimi-bridge.js'),scenario==='asset-conflict'?'changed':asset);
    const r=spawnSync(binary,['--provider','kimi','--restore-bridge',support],{encoding:'utf8'});
    if(scenario.endsWith('conflict')) {assert.notEqual(r.status,0);assert.equal(fs.readFileSync(path.join(renderer,'index.html'),'utf8'),html);assert.ok(fs.existsSync(path.join(renderer,'assets/agent-stats-kimi-bridge.js')));}
    else {assert.equal(r.status,0,r.stderr);assert.equal(fs.readFileSync(path.join(renderer,'index.html'),'utf8'),scenario==='new-host'?html:scenario==='other-edit'?'<body>other edit</body>':original);assert.equal(fs.existsSync(path.join(renderer,'assets/agent-stats-kimi-bridge.js')),false);}
  }
});

test('native uninstall resolves the installed Kimi root and never an unrelated shell environment',()=>{
  for(const scenario of ['record','custom-launch','default-launch','missing','invalid-record','relative-launch']) {
    const home=fs.mkdtempSync(path.join(work,'installed-root-'+scenario+'-')),support=path.join(home,'support'),launch=path.join(home,'agent.plist');
    fs.mkdirSync(support);
    const installed=path.join(home,'installed-kimi'),other=path.join(home,'other-kimi');
    if(['record','invalid-record'].includes(scenario))fs.writeFileSync(path.join(support,'installation.json'),JSON.stringify({version:scenario==='record'?1:999,kimiDataRoot:installed}));
    if(scenario!=='missing') {
      const environment=scenario==='default-launch'?'':`<key>EnvironmentVariables</key><dict><key>KIMI_CODE_HOME</key><string>${scenario==='relative-launch'?'relative-path':other}</string></dict>`;
      fs.writeFileSync(launch,`<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>local.agent.stats</string>${environment}</dict></plist>`);
    }
    const result=spawnSync(binary,[],{input:JSON.stringify({mode:'installed-kimi-root',home,support,launch}),encoding:'utf8',env:{...process.env,KIMI_CODE_HOME:path.join(home,'ambient-must-be-ignored')}});
    if(['missing','invalid-record','relative-launch'].includes(scenario))assert.notEqual(result.status,0,`${scenario} must fail closed before uninstalling`);
    else {
      assert.equal(result.status,0,result.stderr);
      assert.equal(JSON.parse(result.stdout).root,scenario==='record'?installed:scenario==='custom-launch'?other:path.join(home,'.kimi-code'));
    }
  }
});

test('native bridge recovers when the previous process releases its port after startup',async()=>{
  const occupied=net.createServer();await new Promise(r=>occupied.listen(0,'127.0.0.1',r));
  const port=occupied.address().port,config=path.join(work,'retry-bridge.json');fs.writeFileSync(config,JSON.stringify({port,key:'retry-key'}));
  const child=spawn(binary,['--provider','kimi','--bridge',config],{stdio:['ignore','ignore','pipe']});let errors='';child.stderr.on('data',data=>errors+=data);
  try {
    const deadline=Date.now()+4000;while(!errors.includes('Bridge listener unavailable')){assert.ok(Date.now()<deadline,'bind failure was not reported');await new Promise(r=>setTimeout(r,10));}
    await new Promise(r=>occupied.close(r));
    const recovered=Date.now()+5000;
    while(true){
      try {
        const result=await new Promise((resolve,reject)=>{const req=http.request({host:'127.0.0.1',port,path:'/state',method:'POST',headers:{'X-Agent-Stats-Key':'retry-key','Content-Length':0}},res=>{res.resume();res.on('end',()=>resolve(res.statusCode));});req.on('error',reject);req.end();});
        assert.equal(result,200);break;
      } catch(e){if(Date.now()>recovered)throw e;await new Promise(r=>setTimeout(r,20));}
    }
  } finally {child.kill();if(occupied.listening)await new Promise(r=>occupied.close(r));}
});

test('Kimi task totals include children once, preserve identical independent calls and distinguish same-name projects',()=>{
  const root=fs.mkdtempSync(path.join(work,'accounting-kimi-'));
  const make=(wd,id,cwd,agent,records)=>{
    const dir=path.join(root,'sessions',wd,id);fs.mkdirSync(path.join(dir,'agents',agent),{recursive:true});
    fs.writeFileSync(path.join(dir,'state.json'),JSON.stringify({title:'同名任务',cwd,agents:cwd==='/work/a/shop'?{main:{},worker:{parentAgentId:'main'}}:{main:{}}}));
    fs.writeFileSync(path.join(dir,'agents',agent,'wire.jsonl'),records.map(JSON.stringify).join('\n')+'\n');
  };
  const u=(agentId,extra={})=>({type:'usage.record',agentId,time:10,model:'test',usageScope:'turn',usage:{inputOther:10,inputCacheRead:0,inputCacheCreation:0,output:20},...extra});
  make('one','session_one','/work/a/shop','main',[u('main',{requestId:'parent'}),u('main',{requestId:'parent'}),{type:'subagent.completed',usage:{inputOther:9999,output:9999}}]);
  make('one','session_one','/work/a/shop','worker',[u('worker'),u('worker')]);
  make('two','session_two','/work/b/shop','main',[u('main',{requestId:'other'})]);
  const result=scan('kimi',root),parent=result.sessions.find(s=>s.id==='session_one');
  assert.equal(parent.totalTokens,90);assert.equal(parent.agents.length,2);
  assert.equal(parent.agents.find(a=>a.agentID==='worker').totalTokens,60);
  assert.equal(parent.agents.find(a=>a.agentID==='worker').parentID,'main');
  assert.equal(result.projects.length,2);assert.equal(new Set(result.projects.map(p=>p.projectID)).size,2);
  assert.deepEqual(result.projects.map(p=>p.totalTokens).sort((a,b)=>a-b),[30,90]);
});

test('Kimi copied histories are project-deduplicated without guessing fork ownership; absent child journals stay unknown',()=>{
  const root=fs.mkdtempSync(path.join(work,'accounting-fork-'));
  for(const session of ['original','fork']){
    const folder=path.join(root,'sessions/wd',session);fs.mkdirSync(path.join(folder,'agents/main'),{recursive:true});
    fs.writeFileSync(path.join(folder,'state.json'),JSON.stringify({cwd:'/work/project',agents:{main:{}}}));
    fs.writeFileSync(path.join(folder,'agents/main/wire.jsonl'),[
      {type:'metadata',created_at:123},
      {type:'usage.record',time:10,agentId:'main',model:'test',usage:{inputOther:10,output:20,inputCacheRead:0,inputCacheCreation:0}},
    ].map(JSON.stringify).join('\n')+'\n');
  }
  let result=scan('kimi',root);assert.equal(result.projects[0].totalTokens,30);assert.equal(result.projects[0].sharedHistoryTokens,30);
  assert.ok(result.sessions.every(s=>s.totalTokens===0 && s.sharedHistoryTokens===30));
  const state=path.join(root,'sessions/wd/original/state.json');fs.writeFileSync(state,JSON.stringify({cwd:'/work/project',agents:{main:{},missing:{parentAgentId:'main'}}}));
  result=scan('kimi',root);assert.equal(result.sessions.find(s=>s.id==='original').totalTokens,null);assert.equal(result.projects[0].partial,true);
});

test('Codex joins only explicit parent links and refuses ambiguous cumulative parent plus child totals',async()=>{
  const {DatabaseSync}=await import('node:sqlite');const root=fs.mkdtempSync(path.join(work,'accounting-codex-'));
  const db=new DatabaseSync(path.join(root,'state_5.sqlite'));db.exec('CREATE TABLE threads(id TEXT,title TEXT,rollout_path TEXT,archived INTEGER,updated_at INTEGER,thread_source TEXT,source TEXT,cwd TEXT,project_id TEXT)');
  fs.mkdirSync(path.join(root,'sessions'));
  for(const [id,parent,kind] of [['root',null,'user'],['child','root','subagent'],['orphan','absent','subagent'],['fork',null,'user']]){
    const file=path.join(root,'sessions',id+'.jsonl');
    const source=parent ? {subagent:{thread_spawn:{parent_thread_id:parent}}}:'vscode';
    fs.writeFileSync(file,[row('session_meta',{id,source,thread_source:kind,cwd:'/work/shop',...(id==='fork'?{forked_from_id:'root'}:{})},1),row('token_usage_record',{response_id:id,usage:{input_tokens:100,output_tokens:20}},2)].map(JSON.stringify).join('\n')+'\n');
    db.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?,?,?,?)').run(id,id,file,0,1,kind,JSON.stringify(source),'/work/shop',null);
  }db.close();
  let result=scan('codex',root);
  assert.equal(result.sessions.find(s=>s.id==='root').totalTokens,240);
  assert.equal(result.sessions.find(s=>s.id==='root').agents.length,2);
  assert.equal(result.sessions.find(s=>s.id==='fork').totalTokens,120,'fork is a separate task, not a child');
  assert.equal(result.agents.find(a=>a.agentID==='orphan').relationship,'unknown');
  assert.equal(result.projects[0].totalTokens,480);
  fs.writeFileSync(path.join(root,'sessions/root.jsonl'),[row('session_meta',{id:'root',source:'vscode'},1),event('token_count',{info:{total_token_usage:{input_tokens:100,output_tokens:20}}},2)].map(JSON.stringify).join('\n')+'\n');
  result=scan('codex',root);const task=result.sessions.find(s=>s.id==='root');
  assert.equal(task.totalTokens,null);assert.equal(task.partial,true);assert.equal(task.observedRequestTokens,120);
});

test('one request echoed in two agents is included once in the task union',()=>{
  const root=fs.mkdtempSync(path.join(work,'accounting-echo-')),dir=path.join(root,'sessions/wd/shared');
  fs.mkdirSync(dir,{recursive:true});fs.writeFileSync(path.join(dir,'state.json'),JSON.stringify({cwd:'/work/shop',agents:{main:{},worker:{parentAgentId:'main'}}}));
  for(const agent of ['main','worker']){
    fs.mkdirSync(path.join(dir,'agents',agent),{recursive:true});fs.writeFileSync(path.join(dir,'agents',agent,'wire.jsonl'),JSON.stringify({type:'usage.record',requestId:'one-real-request',usage:{inputOther:10,output:20}})+'\n');
  }
  const result=scan('kimi',root);assert.equal(result.sessions[0].totalTokens,30);assert.equal(result.projects[0].totalTokens,30);assert.equal(result.sessions[0].sharedHistoryTokens,30);
});

test('catalogued missing Codex logs remain unknown instead of reducing a parent total silently',async()=>{
  const {DatabaseSync}=await import('node:sqlite');const root=fs.mkdtempSync(path.join(work,'accounting-missing-'));
  fs.mkdirSync(path.join(root,'sessions'));const file=path.join(root,'sessions/root.jsonl');
  fs.writeFileSync(file,[row('session_meta',{id:'root',cwd:'/work/shop',source:'vscode'},1),row('token_usage_record',{response_id:'root',usage:{input_tokens:100,output_tokens:20}},2)].map(JSON.stringify).join('\n')+'\n');
  const db=new DatabaseSync(path.join(root,'state_5.sqlite'));db.exec('CREATE TABLE threads(id TEXT,title TEXT,rollout_path TEXT,archived INTEGER,updated_at INTEGER,thread_source TEXT,parent_thread_id TEXT,cwd TEXT)');
  const put=db.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?,?,?)');put.run('root','root',file,0,1,'user',null,'/work/shop');put.run('child','child',path.join(root,'sessions/missing.jsonl'),0,1,'subagent','root','/work/shop');db.close();
  const result=scan('codex',root);assert.equal(result.sessions[0].totalTokens,null);assert.equal(result.sessions[0].observedRequestTokens,120);assert.equal(result.sessions[0].agents.length,2);
});

test('Codex navigation uses saved project names and explicit membership, never cwd or stale rollout IDs', async()=>{
  const {DatabaseSync}=await import('node:sqlite'),root=fs.mkdtempSync(path.join(work,'named-projects-'));
  fs.mkdirSync(path.join(root,'sessions'));
  const db=new DatabaseSync(path.join(root,'state_5.sqlite'));
  db.exec('CREATE TABLE projects(id TEXT,name TEXT,position INTEGER); CREATE TABLE threads(id TEXT,title TEXT,rollout_path TEXT,archived INTEGER,updated_at INTEGER,thread_source TEXT,source TEXT,project_id TEXT,cwd TEXT)');
  db.prepare('INSERT INTO projects VALUES(?,?,?)').run('123456789',' 用户的项目\n名称 ',0);
  for(const [id,project] of [['assigned','123456789'],['loose',null],['deleted','gone']]){
    const file=path.join(root,'sessions',id+'.jsonl');
    fs.writeFileSync(file,JSON.stringify(row('session_meta',{id,cwd:'/same/path',project_id:'123456789'},1))+'\n');
    db.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?,?,?,?)').run(id,id,file,0,1,'user','vscode',project,'/same/path');
  }
  const find=(result,id)=>result.sessions.find(s=>s.id===id).group;
  let result=scan('codex',root);
  assert.deepEqual(find(result,'assigned'),{id:'123456789',title:'用户的项目 名称'});
  assert.equal(find(result,'loose').title,'未分组');assert.equal(find(result,'deleted').id,'ungrouped');
  assert.equal(result.sessionGroups.length,2);
  db.prepare('UPDATE projects SET name=?').run('重命名后的项目');
  assert.equal(find(scan('codex',root),'assigned').title,'重命名后的项目');
  db.exec('DELETE FROM projects');
  fs.writeFileSync(path.join(root,'.codex-global-state.json'),JSON.stringify({'local-projects':{'123456789':{name:'旧项目'}},'thread-project-assignments':{assigned:{projectId:'123456789'}}}));
  result=scan('codex',root);assert.equal(find(result,'assigned').id,'ungrouped');assert.deepEqual(result.sessionGroups,[{id:'ungrouped',title:'未分组'}]);db.close();
});

test('a warm reader reloads project names when the host database changes',async()=>{
  const {DatabaseSync}=await import('node:sqlite'),root=fs.mkdtempSync(path.join(work,'cached-projects-'));
  fs.mkdirSync(path.join(root,'sessions'));
  const db=new DatabaseSync(path.join(root,'state_5.sqlite'));
  db.exec('CREATE TABLE projects(id TEXT,name TEXT,position INTEGER); CREATE TABLE threads(id TEXT,title TEXT,rollout_path TEXT,archived INTEGER,updated_at INTEGER,thread_source TEXT,source TEXT,project_id TEXT,cwd TEXT)');
  db.prepare('INSERT INTO projects VALUES(?,?,?)').run('p1','原名',0);
  const file=path.join(root,'sessions','assigned.jsonl');
  fs.writeFileSync(file,JSON.stringify(row('session_meta',{id:'assigned',cwd:'/same/path',project_id:'p1'},1))+'\n');
  db.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?,?,?,?)').run('assigned','assigned',file,0,1,'user','vscode','p1','/same/path');
  const watcher=watchCatalog('codex',root);
  const group=async()=>(await watcher.read()).sessions.find(s=>s.id==='assigned').group;
  try {
    // The catalog is cached per reader, so a host rename must invalidate it instead
    // of leaving the first name in place for the life of the process.
    assert.deepEqual(await group(),{id:'p1',title:'原名'});
    db.prepare('UPDATE projects SET name=?').run('已改名');
    assert.deepEqual(await group(),{id:'p1',title:'已改名'});
    db.exec('DELETE FROM projects');
    assert.equal((await group()).id,'ungrouped');
  } finally {watcher.close();db.close();}
});
test('Kimi navigation groups only registered named workspaces; deleted or arbitrary directories are ungrouped',async()=>{
  const root=fs.mkdtempSync(path.join(work,'kimi-named-projects-'));
  fs.writeFileSync(path.join(root,'workspaces.json'),JSON.stringify({workspaces:{wd_saved:{name:'我命名的项目'},wd_deleted:{name:'已删除项目'}},deleted_workspace_ids:['wd_deleted']}));
  for(const workspace of ['wd_saved','wd_deleted','123456789']){
    const dir=path.join(root,'sessions',workspace,'session_'+workspace);fs.mkdirSync(dir,{recursive:true});
    fs.writeFileSync(path.join(dir,'state.json'),JSON.stringify({cwd:'/same/path',title:'对话'}));
  }
  const result=scan('kimi',root);
  assert.equal(result.sessions.find(s=>s.workspace==='wd_saved').group.title,'我命名的项目');
  assert.ok(result.sessions.filter(s=>s.workspace!=='wd_saved').every(s=>s.group.id==='ungrouped'));
  assert.deepEqual(result.sessionGroups.map(g=>g.title),['我命名的项目','未分组']);

  // Once projects.json exists (schema_version 2), it supersedes stale workspaces.json,
  // supports managed projects (wm_*) and reloads when edited on a warm reader.
  const managedDir=path.join(root,'sessions','wm_managed','session_managed');
  fs.mkdirSync(managedDir,{recursive:true});
  fs.writeFileSync(path.join(managedDir,'state.json'),JSON.stringify({cwd:'/same/managed',title:'托管对话'}));
  const projectsFile=path.join(root,'projects.json');
  fs.writeFileSync(projectsFile,JSON.stringify({
    schema_version:2,
    projects:{wd_saved:{name:'已迁移项目',kind:'implicit'},wm_managed:{name:'托管项目',kind:'managed'}},
    deleted_project_ids:['wd_saved']
  }));
  const watcher=watchCatalog('kimi',root);
  try{
    let live=await watcher.read();
    assert.equal(live.sessions.find(s=>s.workspace==='wd_saved').group.id,'ungrouped','projects.json deletion overrides stale workspaces.json');
    assert.equal(live.sessions.find(s=>s.workspace==='wm_managed').group.title,'托管项目');
    fs.writeFileSync(projectsFile,JSON.stringify({
      schema_version:2,
      projects:{wd_saved:{name:'改名后项目',kind:'implicit'},wm_managed:{name:'托管新名',kind:'managed'}},
      deleted_project_ids:[]
    }));
    live=await watcher.read(16000);
    assert.equal(live.sessions.find(s=>s.workspace==='wd_saved').group.title,'改名后项目');
    assert.equal(live.sessions.find(s=>s.workspace==='wm_managed').group.title,'托管新名');
  }finally{watcher.close();}
});

test('legacy Codex project metadata preserves named membership and explicit ungrouped exclusions',()=>{
  const root=fs.mkdtempSync(path.join(work,'codex-legacy-projects-')),a='11111111-1111-4111-8111-111111111111',b='22222222-2222-4222-8222-222222222222';
  fs.mkdirSync(path.join(root,'sessions'));
  for(const id of [a,b])fs.writeFileSync(path.join(root,'sessions',id+'.jsonl'),JSON.stringify(row('session_meta',{id,cwd:'/same/project'},1))+'\n');
  fs.writeFileSync(path.join(root,'.codex-global-state.json'),JSON.stringify({'local-projects':{saved:{name:'旧版自定义名称'}},'thread-project-assignments':{[a]:{projectId:'saved'},[b]:{projectId:'saved'}},'projectless-thread-ids':[b]}));
  const result=scan('codex',root);
  assert.equal(result.sessions.find(s=>s.id===a).group.title,'旧版自定义名称');
  assert.equal(result.sessions.find(s=>s.id===b).group.title,'未分组');
});

test('Codex incomplete host migration maps pending legacy memberships into named current projects only',async()=>{
  const {DatabaseSync}=await import('node:sqlite'),root=fs.mkdtempSync(path.join(work,'codex-pending-projects-'));
  fs.mkdirSync(path.join(root,'sessions'));
  const db=new DatabaseSync(path.join(root,'state_5.sqlite'));
  db.exec('CREATE TABLE projects(id TEXT,name TEXT,position INTEGER); CREATE TABLE threads(id TEXT,title TEXT,rollout_path TEXT,archived INTEGER,updated_at INTEGER,thread_source TEXT,source TEXT,project_id TEXT)');
  db.exec("INSERT INTO projects VALUES('current','用户新名称',0),('other','新表已选择的项目',1)");
  const ids=['pending','complete','projectless','remote','deleted','db-wins'];
  for(const id of ids){
    const file=path.join(root,'sessions',id+'.jsonl');fs.writeFileSync(file,'{}\n');
    db.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?,?,?)').run(id,id,file,0,1,'user','vscode',id==='db-wins'?'other':null);
  }
  const host='local:'+root,state={
    'app-server-projects-migration-by-host':{[host]:{projectsMigrated:true,threadAssignmentsMigrated:false,pendingThreadAssignmentIds:ids.filter(id=>id!=='complete')}},
    'app-server-project-id-by-legacy-project-id-by-host':{[host]:{legacy:'current',deleted:'not-in-current-projects'}},
    'thread-project-assignments':Object.fromEntries(ids.map(id=>[id,{projectKind:'local',projectId:id==='deleted'?'deleted':'legacy'}])),
    'thread-project-membership-host-ids':{remote:'remote-host'},'projectless-thread-ids':['projectless']
  };
  const file=path.join(root,'.codex-global-state.json');fs.writeFileSync(file,JSON.stringify(state));
  const groups=result=>Object.fromEntries(result.sessions.map(s=>[s.id,s.group]));
  let result=groups(scan('codex',root));assert.equal(result.pending.title,'用户新名称');assert.equal(result['db-wins'].id,'other');
  for(const id of ['complete','projectless','remote','deleted'])assert.equal(result[id].id,'ungrouped',id);
  state['app-server-projects-migration-by-host'][host].threadAssignmentsMigrated=true;fs.writeFileSync(file,JSON.stringify(state));
  result=groups(scan('codex',root));assert.equal(result.pending.id,'ungrouped','finished migration must not revive stale legacy membership');db.close();
});

test('per-agent identities and cache hit rates stay separate from the combined task',async()=>{
  const {DatabaseSync}=await import('node:sqlite'),root=fs.mkdtempSync(path.join(work,'agent-detail-'));
  fs.mkdirSync(path.join(root,'sessions'));
  const db=new DatabaseSync(path.join(root,'state_5.sqlite'));
  db.exec('CREATE TABLE threads(id TEXT,title TEXT,rollout_path TEXT,archived INTEGER,updated_at INTEGER,thread_source TEXT,source TEXT,agent_nickname TEXT,agent_role TEXT)');
  for(const [id,parent,nickname,read] of [['root',null,null,10],['child','root','检索代理',80]]){
    const file=path.join(root,'sessions',id+'.jsonl');
    const source=parent?{subagent:{thread_spawn:{parent_thread_id:parent}}}:'vscode';
    const records=[row('session_meta',{id,source},1),row('token_usage_record',{response_id:id,usage:{input_tokens:100,cached_input_tokens:read,output_tokens:20}},2)];
    fs.writeFileSync(file,records.map(JSON.stringify).join('\n')+'\n');
    db.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?,?,?,?)').run(id,id,file,0,1,parent?'subagent':'user',JSON.stringify(source),nickname,'reviewer');
  }
  db.close();const task=scan('codex',root).sessions.find(s=>s.id==='root');
  assert.equal(task.totalTokens,240);assert.equal(task.cacheHit,45);
  assert.equal(task.agents.find(a=>a.role==='main').cacheHit,10);
  const child=task.agents.find(a=>a.role==='subagent');assert.equal(child.cacheHit,80);assert.equal(child.totalTokens,120);assert.equal(child.nickname,'检索代理');assert.equal(child.agentRole,'reviewer');
});

test('Codex inherited session metadata preserves Ultra children, nested agents and ordinary forks',async()=>{
  const {DatabaseSync}=await import('node:sqlite');
  const ids=Object.fromEntries(['root','child','nested','fork','orphan'].map((key,i)=>[key,`10000000-0000-4000-8000-00000000000${i+1}`]));
  const meta=(key,parent)=>row('session_meta',{id:ids[key],source:parent?{subagent:{thread_spawn:{parent_thread_id:ids[parent]??parent}}}:'vscode',
    thread_source:parent?'subagent':'user',...(parent?{parent_thread_id:ids[parent]??parent,agent_nickname:key}:{}),cwd:'/work/ultra'},1);
  const request=(id,input)=>row('token_usage_record',{response_id:id,usage:{input_tokens:input,cached_input_tokens:0,output_tokens:20}},3);
  for(const indexed of [true,false])for(const explicitRequestID of [true,false]){
    const root=fs.mkdtempSync(path.join(work,'inherited-codex-'));fs.mkdirSync(path.join(root,'sessions'));
    const db=indexed?new DatabaseSync(path.join(root,'state_5.sqlite')):null;
    db?.exec('CREATE TABLE threads(id TEXT,title TEXT,rollout_path TEXT,archived INTEGER,updated_at INTEGER,source TEXT,thread_source TEXT)');
    const logs={};
    for(const [key,parent,input] of [['root',null,10],['child','root',50],['nested','child',30],['fork',null,20],['orphan','absent',40]]){
      const header=meta(key,parent),records=[header];
      if(key!=='root')records.push(meta(key==='nested'||key==='fork'?'child':'root',key==='nested'||key==='fork'?'root':null));
      if(key==='root'||key==='child'){
        const copied=request('copied-request',100);if(!explicitRequestID)delete copied.payload.response_id;
        records.push(copied);
      }
      records.push(row('turn_context',{turn_id:key,model:'test-model',effort:'ultra'},2),request(key,input));
      const file=logs[key]=path.join(root,'sessions',ids[key]+'.jsonl');fs.writeFileSync(file,records.map(JSON.stringify).join('\n')+'\n');
      db?.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?,?)').run(ids[key],key,file,key==='nested'?1:0,1,JSON.stringify(header.payload.source),header.payload.thread_source);
    }
    db?.close();
    const verify=result=>{
      const task=result.sessions.find(s=>s.id===ids.root);assert.ok(task);
      assert.equal(task.agents.length,3,'the owning header survives inherited parent metadata');
      assert.equal(task.totalTokens,270,'copied requests count once in the parent task');
      assert.equal(task.sharedHistoryTokens,120);assert.equal(task.partial,false);
      assert.equal(task.agents.find(a=>a.sessionID===ids.child).parentID,ids.root);
      assert.equal(task.agents.find(a=>a.sessionID===ids.child).totalTokens,70);
      assert.equal(task.agents.find(a=>a.sessionID===ids.nested).parentID,ids.child);
      assert.equal(result.sessions.find(s=>s.id===ids.fork).agents.length,1,'a fork stays separate even when it copies a child header');
      assert.equal(result.agents.find(a=>a.sessionID===ids.orphan).relationship,'unknown');
      assert.equal(result.projects[0].totalTokens,370);
    };
    verify(scan('codex',root));
    const watcher=watchCatalog('codex',root);
    try{
      verify(await watcher.read());
      fs.appendFileSync(logs.child,[meta('root',null),row('session_meta',{id:ids.child,agent_nickname:'renamed child'},4)].map(JSON.stringify).join('\n')+'\n');
      const refreshed=await watcher.read();verify(refreshed);
      assert.equal(refreshed.agents.find(a=>a.sessionID===ids.child).nickname,'renamed child');
      assert.deepEqual(canonicalSnapshot(await watcher.read(16000)),canonicalSnapshot(scan('codex',root)));
    }finally{watcher.close();}
  }
});

test('native Codex classification agrees with JS after inherited and partial metadata',()=>{
  for(const child of [false,true]){
    const source=child?{subagent:{thread_spawn:{parent_thread_id:'parent'}}}:'vscode';
    const records=[row('session_meta',{id:'owner',source,thread_source:child?'subagent':'user'},0),
      row('session_meta',{id:'parent',source:child?'vscode':{subagent:{thread_spawn:{parent_thread_id:'ancestor'}}},thread_source:child?'user':'subagent'},1),
      row('session_meta',{id:'owner',agent_nickname:'renamed'},2)];
    parity('codex',records);
    assert.equal(native({provider:'codex',records}).excluded,child);
  }
});

test('Kimi child details retain declared names and missing journals remain unknown',()=>{
  const root=fs.mkdtempSync(path.join(work,'kimi-agent-detail-')),session=path.join(root,'sessions/wd/session_test');
  fs.mkdirSync(path.join(session,'agents/main'),{recursive:true});fs.mkdirSync(path.join(session,'agents/worker'),{recursive:true});
  fs.writeFileSync(path.join(session,'state.json'),JSON.stringify({title:'task',agents:{main:{},worker:{name:' 验证\n代理 ',parentAgentId:'main'},missing:{name:'待启动',parentAgentId:'main'}}}));
  for(const [id,read] of [['main',10],['worker',80]])fs.writeFileSync(path.join(session,'agents',id,'wire.jsonl'),JSON.stringify({type:'usage.record',requestId:id,time:1,usage:{inputOther:100-read,inputCacheRead:read,inputCacheCreation:0,output:20}})+'\n');
  const task=scan('kimi',root).sessions[0],worker=task.agents.find(a=>a.agentID==='worker'),missing=task.agents.find(a=>a.agentID==='missing');
  assert.equal(worker.nickname,'验证 代理');assert.equal(worker.cacheHit,80);assert.equal(missing.totalTokens,null);assert.equal(missing.cacheHit,null);
});

test('average turn duration uses only ended measured turns and is unaffected by a running turn',()=>{
  const cases={
    codex:[event('task_started',{turn_id:'a'},0),event('task_complete',{turn_id:'a',duration_ms:1000},1000),event('task_started',{turn_id:'b'},1500),event('task_complete',{turn_id:'b',duration_ms:3000},4500),event('task_complete',{turn_id:'missing'},5000),event('task_started',{turn_id:'running'},6000)],
    kimi:[{type:'agent.turn.started',turnId:'a',time:0},{type:'turn.ended',turnId:'a',time:1000,durationMs:1000},{type:'agent.turn.started',turnId:'b',time:1500},{type:'turn.ended',turnId:'b',time:4500,durationMs:3000},{type:'turn.ended',turnId:'missing',time:5000},{type:'agent.turn.started',turnId:'running',time:6000}]
  };
  for(const [provider,records] of Object.entries(cases)){
    for(const now of [10000,20000]){parity(provider,records,now);const result=native({provider,records,now});assert.equal(result.avgTurnMs,2000);assert.equal(result.turnDurationSamples,2);}
    const zero=provider==='codex'?event('task_complete',{turn_id:'zero',duration_ms:0},7000):{type:'turn.ended',turnId:'zero',time:7000,durationMs:0};
    const withZero=[...records,zero];parity(provider,withZero,10000);
    assert.equal(native({provider,records:withZero,now:10000}).avgTurnMs,4000/3);
    const empty=native({provider,records:[],now:10000});assert.equal(empty.avgTurnMs,null);assert.equal(empty.turnDurationSamples,0);
  }
});

test('Codex reads compressed rollouts and never parses unknown encodings as JSONL',async()=>{
  const {DatabaseSync}=await import('node:sqlite');
  const zlib=await import('node:zlib');
  const root=fs.mkdtempSync(path.join(work,'codex-zst-'));
  fs.mkdirSync(path.join(root,'sessions'));
  const body=rid=>[row('session_meta',{id:'a',source:'vscode'},1),
    row('token_usage_record',{response_id:rid,turn_id:'t',usage:{input_tokens:100,cached_input_tokens:20,output_tokens:30}},2)].map(JSON.stringify).join('\n')+'\n';
  // The host stores cold rollouts as `*.jsonl.zst` and keeps the catalog path on
  // the plain name; both the twin and a direct compressed path must be read.
  const twinPlain=path.join(root,'sessions','twin.jsonl');
  fs.writeFileSync(twinPlain+'.zst',zlib.zstdCompressSync(Buffer.from(body('r1'))));
  const direct=path.join(root,'sessions','direct.jsonl.zst');
  fs.writeFileSync(direct,zlib.zstdCompressSync(Buffer.from(body('r2'))));
  // A gzip payload must stay unknown instead of becoming phantom parse errors.
  const binary=path.join(root,'sessions','binary.jsonl');
  fs.writeFileSync(binary,Buffer.concat([Buffer.from([0x1f,0x8b,8,0]),Buffer.alloc(12,0x41)]));
  const db=new DatabaseSync(path.join(root,'state_5.sqlite'));
  db.exec('CREATE TABLE threads(id TEXT,title TEXT,rollout_path TEXT,archived INTEGER,updated_at INTEGER,thread_source TEXT,source TEXT,tokens_used INTEGER)');
  const put=db.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?,?,?)');
  put.run('twin','Twin',twinPlain,0,3,'user','vscode',130);
  put.run('direct','Direct',direct,0,2,'user','vscode',130);
  put.run('binary','Binary',binary,0,1,'user','vscode',7);
  db.close();
  const by=Object.fromEntries(scan('codex',root).sessions.map(s=>[s.sessionID,s]));
  for(const id of ['twin','direct']){
    assert.equal(by[id].totalTokens,130,`${id} decompresses to the same usage as plain JSONL`);
    assert.equal(by[id].cacheRead,20);
    assert.equal(by[id].input,80);
    assert.equal(by[id].malformedLines,0);
  }
  assert.equal(by.binary.malformedLines,undefined,'an unreadable encoding produces no phantom line errors');
  assert.equal(by.binary.partial,true);
  assert.equal(by.binary.totalSource,'host');
  assert.equal(by.binary.totalTokens,7,'an unreadable log falls back to the host counter');
  assert.equal(by.binary.input,null,'the breakdown of an unreadable log stays unknown');
  assert.match(by.binary.coverageNote,/宿主本机计数/);
});

test('Codex merges continuation pages and keeps only the surviving revision branch',async()=>{
  const {DatabaseSync}=await import('node:sqlite');
  const root=fs.mkdtempSync(path.join(work,'codex-pages-'));
  fs.mkdirSync(path.join(root,'sessions'));
  const line=(id,ord,rid,tokens)=>JSON.stringify({timestamp:new Date(1000+ord).toISOString(),ordinal:ord,
    type:'token_usage_record',payload:{response_id:rid,turn_id:'t',usage:{input_tokens:tokens,output_tokens:1}}})+'\n';
  // One thread continues across compaction pages: ordinals keep running, so both
  // pages belong to the same branch and their requests are counted once each.
  const u='aaaaaaaa-1111-2222-3333-444444444444',child='bbbbbbbb-1111-2222-3333-444444444444';
  const head=path.join(root,'sessions',`rollout-2026-01-01T00-00-00-${u}.jsonl`);
  const cont=path.join(root,'sessions',`rollout-2026-01-01T01-00-00-${u}_${child}.jsonl`);
  fs.writeFileSync(head,line(u,0,'h1',10)+line(u,1,'dup',20));
  fs.writeFileSync(cont,line(u,2,'dup',20)+line(u,3,'c1',30));
  // A second thread was rewritten: both pages restart at ordinal 0, and the host
  // counter matches only the newer one, so the older revision must not be added.
  const v='cccccccc-1111-2222-3333-444444444444';
  const old=path.join(root,'sessions',`rollout-2026-01-01T02-00-00-${v}.jsonl`);
  const fresh=path.join(root,'sessions',`rollout-2026-01-01T03-00-00-${v}_dddddddd-1111-2222-3333-444444444444.jsonl`);
  fs.writeFileSync(old,line(v,0,'o1',500));
  fs.writeFileSync(fresh,line(v,0,'n1',5));
  // A third thread branched mid-page via history_base (rollback from ordinal 6 back
  // to 4): ordinals >= end_ordinal_exclusive (4) on the parent page and an abandoned
  // sibling branch must both be dropped, and cache restoration must match cold parity.
  const w='eeeeeeee-1111-2222-3333-444444444444',abandoned='ffffffff-1111-2222-3333-444444444444',kept='99999999-1111-2222-3333-444444444444';
  const metaLine=(id,ord,base)=>JSON.stringify({timestamp:new Date(1000+ord).toISOString(),ordinal:ord,type:'session_meta',payload:{id,source:'vscode',...(base?{history_base:base}:{})}})+'\n';
  const wHead=path.join(root,'sessions',`rollout-2026-01-01T04-00-00-${w}.jsonl`);
  const wAbandoned=path.join(root,'sessions',`rollout-2026-01-01T05-00-00-${w}_${abandoned}.jsonl`);
  const wKept=path.join(root,'sessions',`rollout-2026-01-01T06-00-00-${w}_${kept}.jsonl`);
  fs.writeFileSync(wHead,metaLine(w,0)+line(w,1,'w1',10)+line(w,2,'w2',20)+line(w,4,'w-rolled-back-1',500)+line(w,5,'w-rolled-back-2',600));
  fs.writeFileSync(wAbandoned,metaLine(w,4,{thread_id:w,end_ordinal_exclusive:4})+line(w,5,'w-abandoned',700));
  fs.writeFileSync(wKept,metaLine(w,4,{thread_id:w,end_ordinal_exclusive:4})+line(w,5,'w3',30));
  const db=new DatabaseSync(path.join(root,'state_5.sqlite'));
  db.exec('CREATE TABLE threads(id TEXT,title TEXT,rollout_path TEXT,archived INTEGER,updated_at INTEGER,thread_source TEXT,source TEXT,tokens_used INTEGER)');
  const put=db.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?,?,?)');
  put.run(u,'Continued',cont,0,3,'user','vscode',63);
  put.run(v,'Revised',fresh,0,2,'user','vscode',6);
  put.run(w,'Branched',wKept,0,1,'user','vscode',63);
  db.close();
  const by=Object.fromEntries(scan('codex',root).sessions.map(s=>[s.sessionID,s]));
  assert.equal(by[u].rolloutPages,2);
  assert.equal(by[u].totalTokens,63,'continuation pages merge and shared request ids count once');
  assert.equal(by[v].rolloutPages,1);
  assert.equal(by[v].droppedRevisionPages,1);
  assert.equal(by[v].totalTokens,6,'a superseded revision is never summed into the total');
  assert.equal(by[w].rolloutPages,2);
  assert.equal(by[w].droppedRevisionPages,1);
  assert.equal(by[w].totalTokens,63,'rolled-back ordinals and abandoned branch pages are excluded');
  assert.equal(by[w].partial,false);
  // Every chosen page and slice cutoff must be restorable, or the merged set re-reads its whole
  // history on every scan while the cache holds nothing about it.
  const cached=cacheParity('codex',root,path.join(work,'pages-cache.json'),{reset:true,restores:[0,3]});
  assert.equal(cached.sessions.find(s=>s.sessionID===u).totalTokens,63,'a restored page set equals the cold merge');
  assert.equal(cached.sessions.find(s=>s.sessionID===w).totalTokens,63,'a restored history_base slice equals the cold merge');
});

test('Codex forked threads subtract inherited token baseline when reconciling host counter',async()=>{
  const {DatabaseSync}=await import('node:sqlite');
  const root=fs.mkdtempSync(path.join(work,'codex-fork-baseline-'));
  fs.mkdirSync(path.join(root,'sessions'));
  const parentID='11111111-1111-4111-8111-111111111111',forkID='22222222-2222-4222-8222-222222222222';
  const parentFile=path.join(root,'sessions',parentID+'.jsonl'),forkFile=path.join(root,'sessions',forkID+'.jsonl');
  fs.writeFileSync(parentFile,[
    row('session_meta',{id:parentID,cwd:'/work/fork',source:'vscode',thread_source:'user'},1),
    row('token_usage_record',{response_id:'p1',turn_id:'tp1',usage:{input_tokens:600,cached_input_tokens:400,output_tokens:100,total_tokens:700},thread_token_usage:{total_tokens:700}},2),
  ].map(JSON.stringify).join('\n')+'\n');
  fs.writeFileSync(forkFile,[
    row('session_meta',{id:forkID,forked_from_id:parentID,cwd:'/work/fork',source:'vscode',thread_source:'user'},3),
    row('token_usage_record',{response_id:'f1',turn_id:'tf1',usage:{input_tokens:100,cached_input_tokens:50,output_tokens:20,total_tokens:120},thread_token_usage:{total_tokens:820}},4),
    event('token_count',{info:{total_token_usage:{input_tokens:700,cached_input_tokens:450,output_tokens:120,total_tokens:820}}},5),
  ].map(JSON.stringify).join('\n')+'\n');
  const db=new DatabaseSync(path.join(root,'state_5.sqlite'));
  db.exec('CREATE TABLE threads(id TEXT,title TEXT,rollout_path TEXT,archived INTEGER,updated_at INTEGER,thread_source TEXT,source TEXT,cwd TEXT,tokens_used INTEGER,attached_thread_parent_id TEXT)');
  const put=db.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?,?,?,?,?)');
  put.run(parentID,'Parent',parentFile,0,1,'user','vscode','/work/fork',700,null);
  put.run(forkID,'Fork',forkFile,0,2,'user','vscode','/work/fork',820,parentID);
  db.close();
  const result=scan('codex',root);
  const fork=result.sessions.find(s=>s.sessionID===forkID);
  assert.equal(fork.partial,false,'inherited fork baseline matches host counter without false mismatch');
  assert.equal(fork.totalTokens,120,'fork retains only its own generated usage');
  assert.equal(fork.input,50);assert.equal(fork.cacheRead,50);assert.equal(fork.output,20);
  assert.equal(result.projects[0].totalTokens,820,'project total counts parent once plus fork own usage');
  cacheParity('codex',root,path.join(work,'fork-cache.json'),{reset:true,restores:[0,2]});
});

test('Codex turn-scoped durations stay unknown without a completed turn',()=>{
  const records=[event('task_started',{turn_id:'a'},0),
    row('response_item',{type:'function_call',call_id:'c1',turn_id:'a'},100)];
  const s=native({provider:'codex',records,now:20000});
  assert.equal(s.totalMs,null,'no completed turn means the duration is unknown');
  assert.equal(s.modelMs,null);assert.equal(s.decodeMs,null);assert.equal(s.reasoningMs,null);
  assert.equal(s.toolMs,19900,'an open tool call still measures real time');
  parity('codex',records,20000);
  const empty=native({provider:'codex',records:[],now:20000});
  assert.equal(empty.totalMs,null);assert.equal(empty.toolMs,null);
  const kimi=native({provider:'kimi',records:[{type:'agent.turn.started',turnId:0,time:0}],now:5000});
  assert.equal(kimi.totalMs,5000,'a running turn still ticks');
  assert.equal(native({provider:'kimi',records:[],now:5000}).totalMs,null,'nothing observed is unknown, never zero');
});

test('Kimi closes turns from agent.turn.ended and stops dead clocks',()=>{
  const records=[{type:'agent.turn.started',turnId:4,time:0},
    loop('tool.call',{toolCallId:'a',turnId:4},100),
    {type:'agent.turn.ended',turnId:4,outcome:'done',time:500}];
  parity('kimi',records,10000);
  const s=native({provider:'kimi',records,now:10000});
  assert.equal(s.completedTurns,1,'agent.turn.ended closes a turn turn.ended never closed');
  assert.equal(s.totalMs,null,'an ended turn without a recorded duration stays unknown');
  assert.equal(s.lastTurn.durationMs,null,'and the last turn stops running on the clock');
  assert.equal(s.toolMs,400,'the turn boundary still closes its tool calls');
  const open=[{type:'agent.turn.started',turnId:9,time:0}];
  parity('kimi',open,1000000);
  const stale=native({provider:'kimi',records:open,now:1000000});
  assert.equal(stale.totalMs,120000,'a quiet log charges at most 120s past its last write');
  assert.equal(stale.lastTurn.durationMs,120000);
});

test('provably hidden Codex history is never parsed',async()=>{
  const {DatabaseSync}=await import('node:sqlite');
  const root=fs.mkdtempSync(path.join(work,'codex-hidden-'));
  fs.mkdirSync(path.join(root,'sessions'));
  const log=(id,records)=>{const f=path.join(root,'sessions',id+'.jsonl');
    fs.writeFileSync(f,records.map(JSON.stringify).join('\n')+'\n');return f;};
  const hidden=log('hidden',[row('token_usage_record',{response_id:'h',turn_id:'t',usage:{input_tokens:900000,output_tokens:1}},1)]);
  const shown=log('shown',[row('token_usage_record',{response_id:'s',turn_id:'t',usage:{input_tokens:10,output_tokens:20}},2)]);
  const db=new DatabaseSync(path.join(root,'state_5.sqlite'));
  db.exec('CREATE TABLE threads(id TEXT,title TEXT,rollout_path TEXT,archived INTEGER,updated_at INTEGER,thread_source TEXT,source TEXT,tokens_used INTEGER)');
  const put=db.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?,?,?)');
  put.run('hidden','Hidden',hidden,1,1,'user','vscode',900001);
  put.run('shown','Shown',shown,0,2,'user','vscode',30);
  db.close();
  const cacheFile=path.join(work,'hidden-parse-cache.json');
  const run=spawnSync(binary,['--provider','codex','--scan-cache-parity',root,cacheFile,'reset'],{encoding:'utf8'});
  assert.equal(run.status,0,run.stderr);
  const parsed=JSON.parse(run.stdout);
  const shownBytes=fs.statSync(shown).size;
  assert.equal(parsed.parsed[0],shownBytes,'only the visible session log is ever read');
  assert.equal(parsed.cold.sessions.length,1);
  assert.equal(parsed.cold.sessions[0].totalTokens,30);
});

test('legacy single-page cache entries resume text logs but reject compressed ones',async()=>{
  const {DatabaseSync}=await import('node:sqlite');
  const zlib=await import('node:zlib');
  const digest=b=>createHash('sha256').update(b).digest('hex').slice(0,32);
  for(const compressed of [false,true]){
    const root=fs.mkdtempSync(path.join(work,'legacy-cache-'));
    fs.mkdirSync(path.join(root,'sessions'));
    const body=[row('session_meta',{id:'x',source:'vscode'},1),
      row('token_usage_record',{response_id:'r',turn_id:'t',usage:{input_tokens:5,output_tokens:7}},2)].map(JSON.stringify).join('\n')+'\n';
    const raw=compressed?zlib.zstdCompressSync(Buffer.from(body)):Buffer.from(body);
    const file=path.join(root,'sessions','x.jsonl');
    fs.writeFileSync(file,raw);
    const db=new DatabaseSync(path.join(root,'state_5.sqlite'));
    db.exec('CREATE TABLE threads(id TEXT,title TEXT,rollout_path TEXT,archived INTEGER,updated_at INTEGER,thread_source TEXT,source TEXT)');
    db.prepare('INSERT INTO threads VALUES(?,?,?,?,?,?,?)').run('x','X',file,0,1,'user','vscode');
    db.close();
    const cacheFile=path.join(work,'legacy-cache.json');
    // Store a fresh state, then rewrite its entry into the pre-encoding shape.
    let run=spawnSync(binary,['--provider','codex','--scan-cache-parity',root,cacheFile,'reset'],{encoding:'utf8'});
    assert.equal(run.status,0,run.stderr);
    const cache=JSON.parse(fs.readFileSync(cacheFile,'utf8'));
    const key=Object.keys(cache.entries)[0],entry=cache.entries[key],page=entry.pages[0];
    const legacy={...page,agentID:entry.agentID,sessionID:entry.sessionID,journal:entry.journal,metrics:entry.metrics};
    delete legacy.path;delete legacy.encoding;
    fs.writeFileSync(cacheFile,JSON.stringify({version:1,entries:{[key]:legacy}}));
    run=spawnSync(binary,['--provider','codex','--scan-cache-parity',root,cacheFile,'keep'],{encoding:'utf8'});
    assert.equal(run.status,0,run.stderr);
    const resumed=JSON.parse(run.stdout);
    if(compressed){
      assert.equal(resumed.restored[0],0,'a compressed page parsed as text may never resume its legacy state');
      assert.equal(resumed.restored[1],1,'the corrected state still resumes afterwards');
    }else{
      assert.deepEqual(resumed.restored,[1,1],'a legacy text entry resumes without replaying the log');
      assert.deepEqual(resumed.runs[0],resumed.cold);
    }
  }
});
