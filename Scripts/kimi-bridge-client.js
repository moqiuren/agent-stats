/* Agent Stats Kimi bridge. Reads only the selected session ID; never message content. */
(() => {
  'use strict';
  const config = __AGENT_STATS_BRIDGE_CONFIG__;
  const marker = '__agentStatsKimiBridgeV1';
  if (window[marker]) return;
  const clientId = crypto.randomUUID();
  let stopped=false, inflight=false, last='', lastSent=0;
  function selection() {
    const pinia=document.querySelector('#app')?.__vue_app__?.config?.globalProperties?.$pinia;
    const store=pinia?.state?.value?.['kimi.sessions'];
    if (!store) return {known:false,sessionId:null};
    const id=store.activeSessionId;
    if (id===undefined || id===null || id==='') return {known:true,sessionId:null};
    if (typeof id==='string' && /^session_[A-Za-z0-9_-]{1,100}$/.test(id)) return {known:true,sessionId:id};
    return {known:false,sessionId:null};
  }
  function stop(){stopped=true;clearInterval(timer);window.removeEventListener('focus',tick);document.removeEventListener('visibilitychange',tick);delete window[marker];}
  async function tick(){
    if(stopped||inflight)return;
    const data={...selection(),clientId,focused:document.hasFocus(),visible:document.visibilityState==='visible'};
    const key=JSON.stringify(data),now=Date.now();if(key===last&&now-lastSent<2000)return;
    inflight=true;
    try{
      const response=await fetch(config.endpoint,{method:'POST',headers:{'Content-Type':'application/json','X-Agent-Stats-Key':config.key},body:key,signal:AbortSignal.timeout(1800)});
      if(response.status===410){stop();return;}
      if(response.ok){last=key;lastSent=now;}
    }catch{/* Helper may be stopped or restarting. No data leaves loopback. */}
    finally{inflight=false;}
  }
  const timer=setInterval(tick,400);window[marker]={stop};window.addEventListener('focus',tick);document.addEventListener('visibilitychange',tick);void tick();
})();
