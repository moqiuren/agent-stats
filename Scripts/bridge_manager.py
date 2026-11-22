"""Install/remove only Agent Stats' marked Kimi renderer bridge; preserve unrelated edits."""
import pathlib,json,hashlib,os,secrets,socket,urllib.request,time
BEGIN='<!-- AgentStats Kimi Bridge v1 BEGIN -->'
END='<!-- AgentStats Kimi Bridge v1 END -->'
ASSET='assets/agent-stats-kimi-bridge.js'
BLOCK=BEGIN+'\n<script defer src="/assets/agent-stats-kimi-bridge.js"></script>\n'+END+'\n'
def digest(data):return hashlib.sha256(data).hexdigest()
def atomic(path,data,mode=None):
 path=pathlib.Path(path);tmp=path.with_name(path.name+'.agent-stats-tmp');tmp.write_bytes(data)
 os.chmod(tmp,mode if mode is not None else (path.stat().st_mode&0o777 if path.exists() else 0o644));os.replace(tmp,path)
def stripped(text):
 if BEGIN not in text and END not in text:return text
 if text.count(BEGIN)!=1 or text.count(END)!=1:raise RuntimeError('桥接标记异常；已停止以保护页面。')
 a=text.index(BEGIN);b=text.index(END,a)+len(END)
 if text[b:b+1]=='\n':b+=1
 return text[:a]+text[b:]
def install(renderer,support,client_source):
 renderer=pathlib.Path(renderer);folder=pathlib.Path(support)/'kimi-bridge';folder.mkdir(parents=True,exist_ok=True)
 index=renderer/'index.html';asset=renderer/ASSET;manifest=folder/'manifest.json';connection=folder/'connection.json'
 raw=index.read_bytes();text=raw.decode('utf8');old=json.loads(manifest.read_text()) if manifest.exists() else None
 if BEGIN in text and not old:raise RuntimeError('页面已有桥接但缺少备份，停止安装。')
 if asset.exists() and (not old or digest(asset.read_bytes())!=old.get('assetSha256')):raise RuntimeError('桥接资源被另外修改；未覆盖。')
 base=stripped(text).encode('utf8')
 if b'</body>' not in base:raise RuntimeError('没有找到 Kimi 页面 body，未安装。')
 if connection.exists():cfg=json.loads(connection.read_text())
 else:
  with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
  cfg={'port':port,'key':secrets.token_urlsafe(32)}
  atomic(connection,(json.dumps(cfg)+'\n').encode(),0o600)
 config={'endpoint':f'http://127.0.0.1:{cfg["port"]}/kimi-selection','key':cfg['key']}
 js=pathlib.Path(client_source).read_text().replace('__AGENT_STATS_BRIDGE_CONFIG__',json.dumps(config)).encode()
 patched=base.replace(b'</body>',BLOCK.encode()+b'</body>',1)
 # Validate/backup everything before changing the app. No credentials or conversation text.
 atomic(folder/'original-index.html',base,0o600)
 state={'version':1,'renderer':str(renderer.resolve()),'originalSha256':digest(base),'patchedSha256':digest(patched),'asset':ASSET,'assetSha256':digest(js)}
 atomic(manifest,(json.dumps(state,indent=2)+'\n').encode(),0o600)
 atomic(asset,js);atomic(index,patched)
 return connection

def disable_runtime(folder):
 connection=folder/'connection.json'
 if not connection.exists():return
 try:
  cfg=json.loads(connection.read_text());req=urllib.request.Request(f'http://127.0.0.1:{cfg["port"]}/disable',data=b'',headers={'X-Agent-Stats-Key':cfg['key']},method='POST')
  with urllib.request.urlopen(req,timeout=1):pass
  time.sleep(2.2) # Let an open renderer receive HTTP 410 and stop its timer.
 except Exception:pass

def uninstall(support,disable=True):
 folder=pathlib.Path(support)/'kimi-bridge';manifest=folder/'manifest.json'
 if not manifest.exists():return {'restored':False,'reason':'not_installed'}
 state=json.loads(manifest.read_text());renderer=pathlib.Path(state['renderer']);index=renderer/'index.html';asset=renderer/ASSET
 if state.get('asset')!=ASSET:raise RuntimeError('未知桥接资源路径，停止卸载。')
 original=(folder/'original-index.html').read_bytes()
 if digest(original)!=state['originalSha256']:raise RuntimeError('原页面备份校验失败，保留安装以便恢复。')
 if asset.exists() and digest(asset.read_bytes())!=state['assetSha256']:raise RuntimeError('桥接资源被另外修改，未覆盖或删除。')
 restored=False
 if index.exists():
  raw=index.read_bytes();text=raw.decode('utf8')
  if digest(raw)==state['patchedSha256']:replacement=original
  elif BEGIN in text or END in text:replacement=stripped(text).encode('utf8')
  else:replacement=raw # App update already replaced this file; never restore the old version.
  if replacement!=raw:atomic(index,replacement);restored=True
 if asset.exists():asset.unlink()
 if disable:disable_runtime(folder)
 return {'restored':restored,'reason':'removed'}
