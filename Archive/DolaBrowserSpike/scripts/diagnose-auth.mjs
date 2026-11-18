// Run the app's owned probe; observe protocol metadata without logging credentials.
import { spawn, execFileSync } from 'node:child_process';
const binary = process.argv[2];
if (!binary) throw new Error('Pass the DolaLite executable path');
const send = process.argv.includes('--send');
const app = spawn(binary, send ? ['--probe', 'Hello world.'] : ['--probe-debug'], { stdio: ['ignore', 'pipe', 'ignore'] });
// The debug app prints page text; suppress it so account content cannot enter logs.
app.stdout.on('data', () => {});
let finished = false;
const exited = new Promise(resolve => app.on('exit', code => { finished = true; console.log(JSON.stringify({appExit: code})); resolve(); }));
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
let ws, id = 0;
const pending = new Map(), requests = new Map(), bodies = new Set();
function safeURL(raw) {
  try {
    const u = new URL(raw);
    if (!['https:', 'http:'].includes(u.protocol)) return u.protocol;
    return u.origin + u.pathname.replace(/\/chat\/(?:local_)?[0-9]+$/, '/chat/[conversation]');
  } catch { return '[invalid URL]'; }
}
function call(method, params = {}) {
  return new Promise((resolve, reject) => {
    const n = ++id;
    const timer = setTimeout(() => { pending.delete(n); reject(new Error(method + ' timed out')); }, 4000);
    pending.set(n, value => { clearTimeout(timer); resolve(value); });
    ws.send(JSON.stringify({id:n, method, params}));
  });
}
function statusFields(value, depth = 0) {
  if (!value || typeof value !== 'object' || depth > 3) return {};
  const out = {};
  for (const [key, child] of Object.entries(value)) {
    if (/^(code|status_code|error_code|status|success|login|is_login|isLogin|logged_in|authenticated)$/.test(key)
        && (typeof child === 'number' || typeof child === 'boolean' || (typeof child === 'string' && /^[a-zA-Z0-9_ -]{0,60}$/.test(child)))) out[key] = child;
    else if (['data','error','base_resp','BaseResp','result','login'].includes(key) && child && typeof child === 'object') out[key] = statusFields(child, depth + 1);
  }
  return out;
}
try {
  let port;
  for (let i=0;i<160&&!finished;i++) {
    const ps = execFileSync('/bin/ps',['-axo','ppid=,command='],{encoding:'utf8'});
    const line = ps.split('\n').find(s => s.trimStart().startsWith(`${app.pid} `) && s.includes('--remote-debugging-port='));
    port = line?.match(/--remote-debugging-port=(\d+)/)?.[1];
    if (port) break;
    await pause(100);
  }
  if (!port) throw Error('Owned browser port not found');
  let target;
  for(let i=0;i<100&&!finished;i++) {
    try { const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); target = targets.find(t=>t.url.startsWith('https://www.dola.com/chat')); if(target) break; } catch {}
    await pause(100);
  }
  if (!target) throw Error('Owned chat target not found');
  console.log(JSON.stringify({attached:true, port}));
  ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve,reject)=>{ws.onopen=resolve;ws.onerror=reject});
  ws.onmessage = async event => {
    const message = JSON.parse(event.data);
    if(message.id) { pending.get(message.id)?.(message); pending.delete(message.id); return; }
    const p = message.params;
    if (message.method === 'Fetch.requestPaused') {
      if (p.request.url.includes('/passport/web/logout/')) {
        console.log(JSON.stringify({blocked:'webapp-initiated logout in diagnostic copy'}));
        await call('Fetch.failRequest',{requestId:p.requestId,errorReason:'Aborted'});
      } else {
        try {
          const result=await call('Fetch.getResponseBody',{requestId:p.requestId});
          const text=result.result?.base64Encoded?Buffer.from(result.result.body,'base64').toString():result.result?.body;
          if(text) {
            let records;try{records=[JSON.parse(text)]}catch{records=text.split('\n').filter(s=>s.startsWith('data:')).flatMap(s=>{try{return [JSON.parse(s.slice(5))]}catch{return []}})}
            console.log(JSON.stringify({completionIntercept:{http:p.responseStatusCode,bytes:text.length,records:records.map(json=>({keys:Object.keys(json),dataKeys:json.data&&typeof json.data==='object'?Object.keys(json.data):[],fields:statusFields(json)}))}}));
          }
        } finally { await call('Fetch.continueRequest',{requestId:p.requestId}); }
      }
      return;
    }
    if(message.method==='Network.requestWillBeSent' && ['XHR','Fetch','Document'].includes(p.type)) {
      requests.set(p.requestId,{url:safeURL(p.request.url),type:p.type,method:p.request.method});
      if (/\/chat\/completion|\/passport\/|\/alice\/(profile|user\/launch)/.test(requests.get(p.requestId).url)) console.log(JSON.stringify({request:requests.get(p.requestId)}));
    }
    if(message.method==='Network.responseReceived' && requests.has(p.requestId)) {
      const r=requests.get(p.requestId);
      if (/\/chat\/completion|\/passport\/|\/alice\/(profile|user\/launch)/.test(r.url)) {
        console.log(JSON.stringify({response:r.url,http:p.response.status,mime:p.response.mimeType}));
        bodies.add(p.requestId);
      }
    }
    if(message.method==='Network.loadingFinished' && bodies.delete(p.requestId)) {
      try {
        const result=await call('Network.getResponseBody',{requestId:p.requestId});
        const body=result.result?.body;if(!body)return;
        const text=result.result.base64Encoded?Buffer.from(body,'base64').toString():body;
        let records;
        try { records=[JSON.parse(text)]; } catch {
          records=text.split('\n').filter(line=>line.startsWith('data:')).flatMap(line=>{try{return [JSON.parse(line.slice(5))]}catch{return []}});
        }
        console.log(JSON.stringify({business:requests.get(p.requestId)?.url,bytes:text.length,records:records.map(json=>({keys:Object.keys(json),dataKeys:json.data&&typeof json.data==='object'?Object.keys(json.data):[],fields:statusFields(json)}))}));
      } catch {}
    }
    if(message.method==='Page.frameNavigated' && !p.frame.parentId) console.log(JSON.stringify({navigation:safeURL(p.frame.url)}));
  };
  await call('Network.enable');await call('Page.enable');
  await call('Fetch.enable',{patterns:[
    {urlPattern:'*/chat/completion*',requestStage:'Response'},
    {urlPattern:'*/passport/web/logout/*',requestStage:'Request'}
  ]});
  const seen=new Set();
  while(!finished) {
    try {
      const tabs=await(await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      for(const t of tabs.filter(t=>t.type==='page')){const u=safeURL(t.url);if(!seen.has(u)){seen.add(u);console.log(JSON.stringify({page:u}));}}
    } catch {}
    await pause(500);
  }
} catch(error) { console.log(JSON.stringify({diagnosticError:String(error)})); }
finally { ws?.close(); }
await exited;
