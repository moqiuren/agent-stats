@testable import StatsCore
@testable import StatsAdapters
@testable import AgentStatsApp
import AppKit

enum AgentInspectorTests {
 static func run(provider:StatsProvider) {
  var checks=0
  func check(_ value:Bool,_ message:String){precondition(value,message);checks+=1}
  let suite="stats-agent-tests-"+UUID().uuidString
  // Each fixture uses a private preference domain, never the installed app's defaults.
  let fixtureDefaults=UserDefaults(suiteName:suite)!
  defer{fixtureDefaults.removePersistentDomain(forName:suite)}
  let initial=[HUDModule(metric:.usage),HUDModule(metric:.timing)]
  HUDModuleSettings.save(initial,to:fixtureDefaults,provider:"codex")
  HUDModuleSettings.installSubagentModule(in:fixtureDefaults,provider:"codex")
  let migrated=HUDModuleSettings.load(from:fixtureDefaults,provider:"codex")
  check(migrated.map(\.metric)==[.usage,.timing,.subagents] && Array(migrated.prefix(2))==initial,"upgrade adds one child-agent module without changing existing slots")
  HUDModuleSettings.save(initial,to:fixtureDefaults,provider:"codex")
  HUDModuleSettings.installSubagentModule(in:fixtureDefaults,provider:"codex")
  check(HUDModuleSettings.load(from:fixtureDefaults,provider:"codex")==initial,"a user can remove the new module without it being added on every launch")
  let delegate=AppCoordinator(preferences:fixtureDefaults,provider:provider)
  delegate.followsActiveTool=false;delegate.hud.makePanel();delegate.hud.interactionMenuOpen=true
  defer{delegate.hud.popover.close();delegate.hud.panel.close()}
  let main:JSONObject=["key":"main","id":"main","agentID":"main","role":"main","model":"主模型","totalTokens":999,"input":100,"cacheRead":800,"cacheWrite":0,"output":99,"cacheHit":88,"tps":90,"totalMs":4000]
  func child(_ index:Int)->JSONObject {
   ["key":"worker-\(String(format:"%02d",index))","id":"child-\(index)","agentID":"11111111-1111-4111-8111-\(String(format:"%012d",index))","nickname":index==1 ? "检索代理":"校验代理 \(index)","role":"subagent","model":"子模型",
    "agentType":index==1 ? "coder":"explore","agentStatus":index==1 ? "running":"completed","agentEffort":index==1 ? "max":"high",
    "totalTokens":12000+index,"input":1000,"cacheWrite":100,"cacheRead":8000,"output":2900+index,"cacheHit":80,"tps":40,"avgTtftMs":120,"avgTurnMs":2500,"totalMs":5500,"toolMs":200,
    "lastTurn":["tps":50,"ttftMs":80,"durationMs":1200],"active":index==1]
  }
  let children=(1...17).map(child)
  var session:JSONObject=["id":"task-a","taskKey":"task-a","title":"主任务","totalTokens":999999,"agents":[main]+children]
  delegate.selected="task-a";delegate.sessions=[session];delegate.render()
  check(number(HUDMetric.subagents.value(in:session))==17,"the module counts children only, excluding the main agent")
  check(AgentInventory(session).main?.record["totalTokens"] as? Int==999,"main-agent own metrics are not the task aggregate")
  let values=AgentInspectorView.metrics(children[0])
  check(values.contains{$0.0=="Token 总计" && $0.1=="12,001"},"native Int child token values render exactly")
  check(values.contains{$0.0=="平均 TPS" && $0.1=="40.0 tok/s"} && values.contains{$0.0=="缓存命中率" && $0.1=="80.0%"},"each child's throughput and hit rate are its own data")
  check(AgentInspectorView.metrics(["tps":42]).prefix(6).contains{$0.0=="平均 TPS" && $0.1=="42.0 tok/s"},"the summary always uses the average throughput")
  check(!values.contains{$0.0.contains("最近")},"agent details contain no last-turn metrics")
  check(AgentInspectorView.activity(children[0])=="coder · 运行中","a running turn wins over the recorded subagent status")
  check(AgentInspectorView.activity(children[1])=="explore · 已结束","a finished subagent keeps the profile and state its task record declared")
  check(AgentInspectorView.agentState(["agentStatus":"killed"])=="已终止" && AgentInspectorView.agentState([:])=="未运行","a recorded state without a profile still reads as one state")
  check(AgentInspectorView.activity(["agentType":"coder"])=="coder · 未运行","a declared profile never invents a status")
  check(values.contains{$0.0=="平均每轮耗时" && $0.1=="2.50 秒"},"native average turn durations render in milliseconds")
  check(values.contains{$0.0=="平均首 Token" && $0.1=="0.12 秒"},"latency uses the average rather than the latest sample")
  let latestOnly=AgentInspectorView.metrics(["lastTurn":["tps":99,"ttftMs":999,"durationMs":9999]])
  check(latestOnly.filter{$0.0.contains("平均")}.allSatisfy{$0.1=="—"},"missing averages never fall back to last-turn values")
  check(AgentInspectorView.metrics(["partial":true,"totalTokens":42]).first?.0=="已记录 Token","incomplete logs do not present observed tokens as a complete total")
  check(AgentInspectorView.metrics([:]).allSatisfy{$0.1=="—"},"missing child metrics do not inherit parent values or become zero")
  check(AgentInspectorView.metrics(["totalTokens":true]).first?.1=="—","Boolean fields are never token counts")
  let groups=AgentInspectorView.metricGroups(children[0])
  check(groups.map(\.title)==["Token 用量","性能与耗时"],"cache metrics stay inside the Token category instead of forming their own")
  check(groups.flatMap(\.metrics).map(\.0)==values.map(\.0),"every metric belongs to exactly one category, in a stable order")
  func body()->NSView{delegate.hud.popover.scroll.documentView!}
  func control(_ id:String)->NSButton?{body().subviews.compactMap{$0 as? NSButton}.first{$0.identifier?.rawValue==id}}
  func descendants(_ view:NSView)->[NSView]{view.subviews.flatMap{[$0]+descendants($0)}}
  func field(_ id:String)->NSTextField {descendants(body()).compactMap{$0 as? NSTextField}.first{$0.identifier?.rawValue==id}!}
  func textRect(_ field:NSTextField)->NSRect{field.convert(field.bounds,to:body())}
  func baseline(_ field:NSTextField)->CGFloat{textRect(field).minY+field.firstBaselineOffsetFromTop}
  func checkNavigationAlignment(){
   if let previous=control("agent-previous-page"),let next=control("agent-next-page") {
    let a=previous.subviews.compactMap{$0 as? NSTextField}.first!,b=next.subviews.compactMap{$0 as? NSTextField}.first!
    let middle=field("agent-page-number")
    check(abs(baseline(a)-baseline(b))<0.5 && abs(baseline(a)-baseline(middle))<0.5,"paging captions share a text baseline")
    check(textRect(a).minX==16 && textRect(b).maxX==body().bounds.maxX-16,"paging text shares the content gutters")
   }
  }
  func checkDetailAlignment(){
   let name=field("agent-detail-name"),subtitle=field("agent-detail-subtitle")
   let back=control("agent-back")!.subviews.compactMap{$0 as? NSTextField}.first!
   check(textRect(name).minX==16 && textRect(subtitle).minX==16 && textRect(back).minX==16,"detail heading, subtitle and back caption share a left edge")
   let metrics=body().subviews.compactMap{$0 as? NSTextField}.filter{$0.identifier?.rawValue.hasPrefix("agent-metric-value-")==true}
   check(Set(metrics.map{$0.font!.pointSize}).count==1,"all values on a detail page share a font size")
   for value in metrics {
    let labelID=value.identifier!.rawValue.replacingOccurrences(of:"agent-metric-value-",with:"agent-metric-label-")
    check(value.frame.minX==field(labelID).frame.minX,"each metric value aligns with its caption")
   }
   for row in Dictionary(grouping:metrics,by:{$0.frame.minY}).values where row.count>1 {
    check(row.allSatisfy{abs(baseline($0)-baseline(row[0]))<0.5},"paired metric values share a baseline even when one value is long")
   }
   checkNavigationAlignment()
  }
  let screen=NSRect(x:0,y:0,width:1440,height:900)
  for dimensions in [NSSize(width:900,height:650),NSSize(width:360,height:260),NSSize(width:280,height:240)] {
   let host=NSRect(origin:NSPoint(x:100,y:100),size:dimensions)
   do {
    delegate.hud.applyModules()
    delegate.hud.panel.setFrame(delegate.hud.placement.frame(host:host,screen:screen),display:false);delegate.hud.lastRect=host
    delegate.hud.showAgentInspector(anchor:delegate.hud.metricScroll,display:false)
    check(!delegate.hud.popover.scroll.hasVerticalScroller,"agent list never requires vertical scrolling")
    check(body().frame.height==delegate.hud.popover.scroll.contentSize.height,"list body fills its viewport exactly")
    check(control("agent-row-main") != nil,"main agent is separated at the top of the list")
    let section=field("agent-section-title")
    for name in body().subviews.compactMap({$0 as? NSTextField}).filter({$0.identifier?.rawValue.hasPrefix("agent-name-")==true}) {
     let id=String(name.identifier!.rawValue.dropFirst("agent-name-".count)),tokens=field("agent-tokens-"+id)
     check(name.frame.minX==section.frame.minX && name.frame.minX==delegate.hud.popover.heading.frame.minX,"list names and section/panel headings share one left edge")
     check(abs(baseline(name)-baseline(tokens))<0.5,"agent name and token amount share a baseline")
    }
    checkNavigationAlignment()
    for view in body().subviews {check(body().bounds.contains(view.frame),"every list control is visible within a compact native viewport")}
    check(control("agent-next-page")?.isEnabled==true,"large child lists have a next page")
    control("agent-next-page")?.performClick(nil)
    let retainedPage=delegate.hud.agentInspectorState.listPage
    check(retainedPage==1 && control("agent-previous-page")?.isEnabled==true,"next page changes the list without scrolling")
    let row=body().subviews.compactMap{$0 as? NSButton}.first{($0.identifier?.rawValue.hasPrefix("agent-row-worker")) == true}!
    let id=String(row.identifier!.rawValue.dropFirst("agent-row-".count))
    row.performClick(nil)
    check(delegate.hud.agentInspectorState.selectedID==id && delegate.selected=="task-a","opening a child changes only the detail page, never the selected conversation")
    check(delegate.hud.popover.heading.stringValue=="子代理详情","child detail explicitly identifies its scope")
    for view in body().subviews {check(body().bounds.contains(view.frame),"all detail cards and navigation fit without scrolling")}
    checkDetailAlignment()
    let valuesOnPage=body().subviews.compactMap{$0 as? NSTextField}.filter{$0.identifier?.rawValue.hasPrefix("agent-metric-value-")==true}
    if let next=control("agent-next-page") {
     check(next.isEnabled,"a viewport too short for the whole grid falls back to another page")
     next.performClick(nil)
     check(delegate.hud.agentInspectorState.detailPage==1,"detail pagination exposes the remaining metrics")
     checkDetailAlignment()
     for view in body().subviews {check(body().bounds.contains(view.frame),"every compact detail page fits completely")}
    }else{
     check(delegate.hud.agentInspectorState.detailPage==0 && valuesOnPage.count==values.count,"a detail with room shows every metric on one page")
    }
    control("agent-back")?.performClick(nil)
    check(delegate.hud.agentInspectorState.selectedID==nil && delegate.hud.agentInspectorState.listPage==retainedPage,"back returns to the same list page")
   }
  }
  let host=NSRect(x:100,y:100,width:900,height:650)
  delegate.hud.applyModules();delegate.hud.panel.setFrame(delegate.hud.placement.frame(host:host,screen:screen),display:false);delegate.hud.lastRect=host
  delegate.hud.showAgentInspector(anchor:delegate.hud.metricScroll,display:false)
  control("agent-row-worker-01")?.performClick(nil)
  check(control("agent-next-page")==nil,"the standard subagent detail shows every metric without paging")
  let detailSubtitle=field("agent-detail-subtitle").stringValue
  check(detailSubtitle.contains("coder") && detailSubtitle.contains("max 思考") && detailSubtitle.contains("运行中"),"the subagent detail names its profile, thinking effort and state")
  let headings=body().subviews.compactMap{$0 as? NSTextField}.filter{$0.identifier?.rawValue.hasPrefix("agent-group-")==true}
  check(headings.map(\.stringValue)==groups.map(\.title),"category headings appear once, in the declared order")
  check(headings.map{textRect($0).minY}==headings.map{textRect($0).minY}.sorted(),"categories read top to bottom")
  for (index,heading) in headings.enumerated() {
   let top=textRect(heading).maxY,bottom=index+1<headings.count ? textRect(headings[index+1]).minY:body().bounds.maxY
   let owned=groups.first{$0.title==heading.stringValue}!.metrics.map{$0.0}
   check(owned.allSatisfy{let r=textRect(field("agent-metric-value-"+$0));return r.minY>=top && r.maxY<=bottom},"every value stays inside its own category band")
  }
  var long=children;long[0]["totalTokens"]=1_234_567_890_123_456
  session["agents"]=[main]+long;delegate.sessions=[session];delegate.render()
  checkDetailAlignment()
  check(field("agent-metric-value-Token 总计").font!.pointSize<16,"long numeric fixtures exercise the shared font reduction path")
  var changed=children;changed[0]["totalTokens"]=54321
  session["agents"]=[main]+changed;delegate.sessions=[session];delegate.render()
  check(delegate.hud.agentInspectorState.selectedID=="worker-01","live refresh retains the exact selected child")
  check(body().subviews.compactMap{$0 as? NSTextField}.contains{$0.stringValue=="54,321"},"visible child data updates in place")
  delegate.hud.agentInspectorState.detailPage=99;delegate.hud.refreshAgentInspector()
  check(delegate.hud.agentInspectorState.detailPage==0 && control("agent-next-page")==nil,"a single-page detail clamps an out-of-range page instead of inventing more metrics")
  session["agents"]=[main]+Array(changed.dropFirst());delegate.sessions=[session];delegate.render()
  check(delegate.hud.agentInspectorState.selectedID=="worker-01" && body().subviews.compactMap{$0 as? NSTextField}.contains{$0.stringValue=="该代理已不可用"},"a disappearing child is never silently replaced by another")
  var other=session;other["id"]="task-b";other["taskKey"]="task-b";delegate.sessions=[other];delegate.selected="task-b";delegate.render()
  check(delegate.hud.agentInspectorState.selectedID==nil,"changing conversations clears old child detail state")
  delegate.sessions=[];delegate.render()
  check(body().subviews.compactMap{$0 as? NSTextField}.contains{$0.stringValue=="暂无会话统计"},"unknown current sessions clear all child details")
  if let path=ProcessInfo.processInfo.environment["STATS_PREVIEW_DIR"] {
   let folder=URL(fileURLWithPath:path);try! FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
   session["agents"]=[main]+children;delegate.sessions=[session];delegate.selected="task-a";delegate.render()
   func snapshot(_ name:String){
    let view=delegate.hud.popover.window.contentView!;view.layoutSubtreeIfNeeded();view.displayIfNeeded()
    let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
    view.effectiveAppearance.performAsCurrentDrawingAppearance{view.cacheDisplay(in:view.bounds,to:bitmap)}
    try! bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(provider.rawValue+"-agents-"+name+".png"))
   }
   for (appearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
    delegate.hud.popover.window.appearance=NSAppearance(named:appearance)
    delegate.hud.showAgentInspector(anchor:delegate.hud.metricScroll,display:false);snapshot("list-"+suffix)
    control("agent-row-worker-01")?.performClick(nil);snapshot("detail-"+suffix)
    if let next=control("agent-next-page"),next.isEnabled{next.performClick(nil);snapshot("more-"+suffix)}
    control("agent-back")?.performClick(nil);control("agent-row-main")?.performClick(nil);snapshot("main-"+suffix)
   }
  }
  print("\(checks) \(provider.rawValue) subagent module checks passed")
 }
}
