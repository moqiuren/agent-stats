@testable import StatsCore
@testable import StatsAdapters
@testable import AgentStatsApp
import AppKit
enum InspectorTests {
 static func main(){
  let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
  let host=NSRect(x:100,y:100,width:900,height:650),screen=NSRect(x:0,y:0,width:1440,height:900)
  let bar=HUDPanel(contentRect:.zero,styleMask:.borderless,backing:.buffered,defer:false);let anchor=NSButton(title:"32.8 tok/s",target:nil,action:nil);let view=NSView();view.addSubview(anchor);bar.contentView=view
  let inspector=HUDInspector();var checks=0
  func check(_ value:Bool,_ message:String){precondition(value,message);checks+=1}
  for contentSize in [CGSize(width:530,height:34),CGSize(width:220,height:34)] {
   let frame=HUDPlacement(moduleCount:4,contentSize:contentSize).frame(host:host,screen:screen);bar.setFrame(frame,display:false);anchor.frame=NSRect(x:4,y:4,width:40,height:24)
   let choices=(1...150).map{InspectorChoice(id:String($0),title:"会话 \($0)")}
   inspector.present(kind:"sessions",title:"选择统计会话",choices:choices,searchable:true,anchor:anchor,host:host,screen:screen,bar:frame,display:false)
   check(host.contains(inspector.window.frame),"selector contained: \(contentSize)")
   check(inspector.canvas.bounds.contains(inspector.search.frame),"search is not clipped")
   check(inspector.canvas.bounds.contains(inspector.scroll.frame),"list viewport is not clipped")
   check((inspector.scroll.documentView?.frame.height ?? 0)>inspector.scroll.frame.height,"long list scrolls instead of squeezing")
   inspector.setChoiceLevel(title:"用户命名的项目",choices:choices,backTitle:"所有项目")
   inspector.position(host:host,screen:screen,bar:frame)
   check(host.contains(inspector.window.frame),"nested selector stays in its host: \(contentSize)")
   check(inspector.canvas.bounds.contains(inspector.back.frame),"back navigation is visible: \(contentSize)")
   check(inspector.back.frame.maxY<=inspector.search.frame.minY && inspector.search.frame.maxY<=inspector.scroll.frame.minY,"nested navigation, search and rows do not overlap: \(contentSize)")
   check(inspector.canvas.bounds.contains(inspector.scroll.frame),"nested viewport is contained: \(contentSize)")
   inspector.present(kind:"speed",title:"速度与延迟",rows:[("最近一轮速度","32.8 tok/s"),("平均速度","33.4 tok/s"),("最近一轮 TTFT","0.50 秒"),("平均 TTFT","0.80 秒"),("等待合计","8.00 秒")],anchor:anchor,host:host,screen:screen,bar:frame,display:false)
   check(host.contains(inspector.window.frame),"metric contained: \(contentSize)");check(inspector.search.isHidden,"metric has no session search")
   check((inspector.scroll.documentView?.frame.height ?? 0)<=inspector.scroll.contentSize.height,"all merged metrics fit the popup: \(contentSize)")
  }
  inspector.close()
  inspector.present(kind:"modules",title:"显示模块",choices:[InspectorChoice(id:"speed",title:"速度与延迟",selected:true),InspectorChoice(id:"usage",title:"Token")],toggleable:true,anchor:anchor,host:host,screen:screen,bar:bar.frame,display:false)
  var toggled:String?
  inspector.onChoice={toggled=$0}
  let first=inspector.scroll.documentView?.subviews.compactMap{$0 as? NSButton}.first
  first?.performClick(nil)
  check(toggled=="speed","toggle callback fires with the picked id")
  check(inspector.kind=="modules","toggleable picker stays open")
  check(inspector.choices.first?.selected==false,"toggle flips the selection mark")
  inspector.close()
  let longTitle="很长的会话名称\n第二行\t"+String(repeating:"中文名称",count:100)
  inspector.present(kind:"sessions",title:"选择统计会话",choices:[InspectorChoice(id:"long",title:longTitle)],searchable:true,anchor:anchor,host:host,screen:screen,bar:bar.frame,display:false)
  let longButton=inspector.scroll.documentView?.subviews.compactMap{$0 as? NSButton}.first
  check(longButton?.title.contains("\n")==false,"selector titles do not contain line breaks")
  check(longButton?.cell?.usesSingleLineMode==true,"selector title is a single line")
  check(longButton?.toolTip==longTitle,"selector retains complete title in tooltip")
  check(longButton?.frame.height==30,"long selector rows retain fixed height")
  inspector.search.stringValue="新名称"
  inspector.updateChoices([InspectorChoice(id:"long",title:"新名称",selected:true)])
  check(inspector.search.stringValue=="新名称","renaming preserves current search")
  check(inspector.scroll.documentView?.subviews.compactMap{$0 as? NSButton}.first?.title=="✓  新名称","open selector updates renamed titles")
  inspector.close()
  let status=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
  defer { inspector.close();NSStatusBar.system.removeStatusItem(status) }
  status.button!.title="K  速度 42.0 tok/s"
  let statusAnchor=status.button!,statusWindow=statusAnchor.window!
  let statusScreen=statusWindow.screen?.visibleFrame ?? screen
  let statusFrame=statusWindow.convertToScreen(statusAnchor.convert(statusAnchor.bounds,to:nil))
  inspector.present(kind:"sessions",title:"统计会话",choices:[InspectorChoice(id:"current",title:"自动跟随当前对话"),InspectorChoice(id:"old",title:"之前的会话")],searchable:true,anchor:statusAnchor,host:statusScreen,screen:statusScreen,bar:statusFrame,attachToOwner:false)
  check(inspector.isShown && inspector.anchor===statusAnchor,"native menu bar anchors open a real inspector")
  check(inspector.owner==nil && inspector.window.parent==nil && statusWindow.childWindows?.contains(inspector.window) != true,"menu bar inspectors never inherit the native status window's elevated level")
  check(inspector.window.level == .normal && !inspector.window.isFloatingPanel,"independent menu bar inspectors remain ordinary panels")
  check(statusScreen.contains(inspector.window.frame),"menu bar inspector is constrained to the available screen")
  inspector.close()
  inspector.present(kind:"speed",title:"速度与延迟",rows:[("最近一轮速度","42.0 tok/s")],anchor:anchor,host:host,screen:screen,bar:bar.frame)
  check(inspector.owner===bar && inspector.window.parent===bar,"returning to a floating inspector restores its owner attachment")
  inspector.close()
  check(inspector.window.parent==nil && bar.childWindows?.contains(inspector.window) != true,"closing the floating inspector removes its child relationship")

  // Exercise WindowServer ordering with windows owned exclusively by this test.
  // No accessibility calls or window IDs belonging to a real host are used.
  let orderingScreen=NSScreen.main?.visibleFrame ?? screen
  let orderingHost=NSRect(x:orderingScreen.minX+24,y:orderingScreen.minY+24,width:360,height:160)
  let hostWindow=NSWindow(contentRect:orderingHost,styleMask:.borderless,backing:.buffered,defer:false)
  hostWindow.title="Stats ordering test host";hostWindow.level = .normal;hostWindow.backgroundColor = .gray
  let orderingBar=HUDPanel(contentRect:NSRect(x:orderingHost.minX+8,y:orderingHost.maxY-42,width:344,height:34),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
  orderingBar.title="Stats ordering test bar";orderingBar.hidesOnDeactivate=false;orderingBar.backgroundColor = .blue
  let orderingAnchor=NSButton(title:"Ordering test",target:nil,action:nil);orderingAnchor.frame=NSRect(x:8,y:4,width:100,height:24)
  orderingBar.contentView=NSView(frame:NSRect(origin:.zero,size:orderingBar.frame.size));orderingBar.contentView!.addSubview(orderingAnchor)
  let orderingInspector=HUDInspector()
  defer{orderingInspector.close();orderingBar.orderOut(nil);hostWindow.orderOut(nil)}
  func settleOrdering(){RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
  func above(_ upper:NSWindow,_ lower:NSWindow)->Bool {
   // Empty options restrict this public API to the calling test application.
   let numbers=(NSWindow.windowNumbers(options:[]) ?? []).map(\.intValue)
   guard let upperIndex=numbers.firstIndex(of:upper.windowNumber),let lowerIndex=numbers.firstIndex(of:lower.windowNumber) else{return false}
   return upperIndex<lowerIndex
  }
  hostWindow.orderFrontRegardless();orderingBar.orderFrontRegardless();settleOrdering()
  check(orderingBar.level == .normal && above(orderingBar,hostWindow),"the unattached ordinary test HUD can initially be placed above its own host")
  hostWindow.orderFrontRegardless();settleOrdering()
  check(above(hostWindow,orderingBar),"raising an ordinary host reproduces obstruction of an overlapping same-level HUD")
  orderingBar.setHostOverlayActive(true);orderingBar.orderFrontRegardless();settleOrdering()
  check(orderingBar.level == HUDPanel.hostOverlayLevel && !orderingBar.isFloatingPanel,"an active host overlay uses the designated level without changing panel activation behavior")
  for _ in 0..<12 {
   hostWindow.orderFrontRegardless();settleOrdering()
   check(above(orderingBar,hostWindow),"a host raised to the front cannot cover its active overlay")
   hostWindow.orderFront(nil);settleOrdering()
   check(above(orderingBar,hostWindow),"ordinary host ordering cannot cover its active overlay")
   hostWindow.order(.above,relativeTo:orderingBar.windowNumber);settleOrdering()
   check(above(orderingBar,hostWindow) && hostWindow.level == .normal,"relative host ordering respects the overlay's separate window level")
  }
  orderingInspector.present(kind:"speed",title:"Ordering inspector",rows:[("Probe","1")],anchor:orderingAnchor,host:orderingHost,screen:orderingScreen,bar:orderingBar.frame)
  settleOrdering()
  check(orderingInspector.window.level == orderingBar.level && orderingInspector.window.parent===orderingBar,"an attached inspector inherits its active host overlay level")
  hostWindow.orderFrontRegardless();settleOrdering()
  check(above(orderingInspector.window,hostWindow) && above(orderingBar,hostWindow),"raising the host preserves both the attached inspector and the HUD")
  orderingInspector.close()
  check(orderingInspector.window.level == .normal && orderingInspector.window.parent==nil && !orderingInspector.isShown,"closing an attached inspector resets its window level and attachment")
  orderingInspector.present(kind:"speed",title:"Independent inspector",rows:[("Probe","1")],anchor:statusAnchor,host:orderingScreen,screen:orderingScreen,bar:statusFrame,attachToOwner:false)
  check(orderingInspector.window.level == .normal && orderingInspector.window.parent==nil,"reopening the same inspector from the menu bar cannot retain host overlay elevation")
  orderingInspector.close();orderingBar.orderOut(nil);orderingBar.setHostOverlayActive(false)
  check(orderingBar.level == .normal && !orderingBar.isVisible,"releasing a hidden host overlay restores ordinary window ordering")
  print("\(checks) native inspector checks passed")
 }
}
