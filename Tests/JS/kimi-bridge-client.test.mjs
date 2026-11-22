import test from 'node:test';import assert from 'node:assert/strict';import vm from 'node:vm';import fs from 'node:fs';
test('page bridge tracks exact selected ID, draft, unavailable state, and stops on removal',async()=>{
 const source=fs.readFileSync(new URL('../../Scripts/kimi-bridge-client.js',import.meta.url),'utf8').replace('__AGENT_STATS_BRIDGE_CONFIG__',JSON.stringify({endpoint:'http://127.0.0.1:1234/kimi-selection',key:'test-key'}));
 const store={activeSessionId:'session_first',messages:['PRIVATE_SENTINEL']},pinia={state:{value:{'kimi.sessions':store}}};let tick,cleared=false,status=204;const sent=[];
 const fake={crypto:{randomUUID:()=> 'client'},AbortSignal,Date,console,setInterval:f=>(tick=f,1),clearInterval:()=>{cleared=true},window:{addEventListener(){},removeEventListener(){}},document:{querySelector:()=>({__vue_app__:{config:{globalProperties:{$pinia:pinia}}}}),hasFocus:()=>true,visibilityState:'visible',addEventListener(){},removeEventListener(){}},fetch:async(url,options)=>{sent.push(JSON.parse(options.body));return{status,ok:status===204}}};
 vm.runInNewContext(source,fake);await new Promise(setImmediate);assert.equal(sent.at(-1).sessionId,'session_first');
 store.activeSessionId='session_second';await tick();assert.equal(sent.at(-1).sessionId,'session_second');
 store.activeSessionId=undefined;await tick();assert.equal(sent.at(-1).sessionId,null);assert.equal(sent.at(-1).known,true);
 delete pinia.state.value['kimi.sessions'];await tick();assert.equal(sent.at(-1).known,false);assert.ok(!JSON.stringify(sent).includes('PRIVATE_SENTINEL'));
 status=410;pinia.state.value['kimi.sessions']={activeSessionId:'session_last'};await tick();assert.equal(cleared,true);
});
