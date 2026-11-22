@testable import StatsCore
import Foundation
import CoreGraphics
enum PlacementTests {
 static func main(){
  var checks=0
  func check(_ value:Bool,_ message:String){precondition(value,message);checks+=1}
  // The bar has exactly one shape and one place: a horizontal strip on the host's
  // inset top edge, centred, clamped into the visible part of its host.
  let screen=CGRect(x:0,y:0,width:1440,height:900),host=CGRect(x:220,y:120,width:900,height:650)
  let area=HUDPlacement.container(host:host,screen:screen)
  let bar=HUDPlacement(moduleCount:4,contentSize:CGSize(width:530,height:34)).frame(host:host,screen:screen)
  check(host.contains(bar),"the bar stays inside its host")
  check(bar.size==CGSize(width:530,height:34),"the bar keeps its metric strip size")
  check(bar.maxY==area.maxY,"the bar sits on the inset top edge")
  check(abs(bar.midX-host.midX)<=0.5,"the bar is centred on its host")
  for size in [CGSize(width:20000,height:34),CGSize(width:40,height:34)] {
   let clamped=HUDPlacement(moduleCount:1,contentSize:size).frame(host:host,screen:screen)
   check(area.contains(clamped) && clamped.maxY==area.maxY,"an oversized or tiny bar is clamped to the visible top strip")
  }
  let stripHeights=[0,1,7,40].map{HUDPlacement(moduleCount:$0).frame(host:host,screen:screen).height}
  check(Set(stripHeights).count==1 && stripHeights[0]==28,"every module count keeps one horizontal strip of the slim height")
  // A dragged bar keeps its free position as a fraction of the host container and
  // never snaps to an edge or changes shape.
  var dragged=HUDPlacement(moduleCount:4,contentSize:CGSize(width:530,height:34))
  let dropped=CGRect(x:area.minX+120,y:area.minY+240,width:530,height:34)
  dragged.recordDrag(frame:dropped,host:host,screen:screen)
  check(dragged.relativePosition != nil && dragged.frame(host:host,screen:screen)==dropped,"a dropped bar returns to exactly where it was released")
  let shiftedHost=host.offsetBy(dx:40,dy:-30)
  check(dragged.frame(host:shiftedHost,screen:screen).minX==dropped.minX+40 && dragged.frame(host:shiftedHost,screen:screen).minY==dropped.minY-30,"a free position follows its host at the same relative place")
  let resizedHost=CGRect(x:200,y:100,width:1200,height:800)
  let resizedArea=HUDPlacement.container(host:resizedHost,screen:screen)
  let resizedFrame=dragged.frame(host:resizedHost,screen:screen)
  check(resizedArea.contains(resizedFrame),"a free position stays inside a resized host")
  check(abs((resizedFrame.minX-resizedArea.minX)/(resizedArea.width-resizedFrame.width)-dragged.relativePosition!.x)<0.0001 && abs((resizedFrame.minY-resizedArea.minY)/(resizedArea.height-resizedFrame.height)-dragged.relativePosition!.y)<0.0001,"free positions keep their proportional location")
  var outside=HUDPlacement(moduleCount:1,contentSize:CGSize(width:200,height:34))
  outside.recordDrag(frame:CGRect(x:area.minX-900,y:area.maxY+900,width:200,height:34),host:host,screen:screen)
  check(area.contains(outside.frame(host:host,screen:screen)),"an unreachable saved fraction is clamped back inside the host")
  let defaultPlacement=HUDPlacement(moduleCount:4,contentSize:CGSize(width:530,height:34))
  check(defaultPlacement.relativePosition == nil && defaultPlacement.frame(host:host,screen:screen).maxY==area.maxY && abs(defaultPlacement.frame(host:host,screen:screen).midX-host.midX)<=0.5,"without a dragged position the bar starts centred on the top edge")
  // A single unverified pass must not blink the visible bar out while nothing about
  // the host changed; a real change still hides it immediately.
  let graceNow = Date()
  func holds(contextActive: Bool = true, visible: Bool = true, number: UInt32? = 7, age: Double = 0,
             onScreen: Bool = true) -> Bool {
    HUDVerificationGrace.holdsVisibleBar(
      hostContextActive: contextActive, barVisible: visible, verifiedNumber: number,
      verifiedAt: graceNow.addingTimeInterval(-age), now: graceNow, windowStillOnScreen: onScreen)
  }
  check(holds() && holds(age: 0.79), "a fresh proof gap keeps the visible bar in place instead of blinking")
  check(!holds(age: 0.9) && !holds(age: 5), "a sustained loss still hides the bar")
  check(!holds(contextActive: false), "another application taking focus hides the bar immediately")
  check(!holds(visible: false), "an unverified pass cannot make a hidden bar visible")
  check(!holds(number: nil), "without a verified window there is nothing to hold")
  check(!holds(onScreen: false), "a closed host window hides the bar without waiting for the grace")
  check(HUDVerificationGrace.interval > 0.5 && HUDVerificationGrace.interval < 1.5, "the grace covers an asynchronous proof gap without hiding for long")
  // A drag or an open menu pauses the positioning loop, so the last proof ages while
  // nothing about the host changes: the re-render right after must not blink.
  let pausedAt = graceNow.addingTimeInterval(-0.1)
  let resumed = HUDVerificationGrace.resumedVerifiedAt(graceNow.addingTimeInterval(-9), pausedAt: pausedAt)
  check(resumed == pausedAt, "the grace restarts when a paused pass resumes")
  check(HUDVerificationGrace.holdsVisibleBar(
    hostContextActive: true, barVisible: true, verifiedNumber: 7, verifiedAt: resumed,
    now: graceNow, windowStillOnScreen: true), "a long drag no longer leaves the refresh stale")
  check(HUDVerificationGrace.resumedVerifiedAt(graceNow, pausedAt: nil) == graceNow, "without a pause the last proof is used as it is")
  check(!HUDVerificationGrace.holdsVisibleBar(
    hostContextActive: true, barVisible: true, verifiedNumber: 7,
    verifiedAt: graceNow.addingTimeInterval(-9), now: graceNow, windowStillOnScreen: true),
    "a stale proof without a pause still hides the bar")
  // Moving or resizing the host while holding the pointer also races AX geometry, so
  // the grace stays alive during continuous motion and expires once motion settles.
  let priorMotion = graceNow.addingTimeInterval(-3)
  check(HUDVerificationGrace.motionAt(previous: priorMotion, frameChanged: false, pointerHeld: true, now: graceNow) == priorMotion,
        "stationary frames keep the previous motion timestamp")
  check(HUDVerificationGrace.motionAt(previous: priorMotion, frameChanged: true, pointerHeld: false, now: graceNow) == priorMotion,
        "motion without a held pointer does not extend the grace")
  let activeMotion = HUDVerificationGrace.motionAt(
    previous: priorMotion, frameChanged: true, pointerHeld: true,
    now: graceNow.addingTimeInterval(-0.1))
  check(activeMotion == graceNow.addingTimeInterval(-0.1),
        "host motion while holding the pointer records the latest motion time")
  check(HUDVerificationGrace.holdsVisibleBar(
    hostContextActive: true, barVisible: true, verifiedNumber: 7,
    verifiedAt: HUDVerificationGrace.resumedVerifiedAt(graceNow.addingTimeInterval(-9), pausedAt: activeMotion),
    now: graceNow, windowStillOnScreen: true),
    "continuous host dragging keeps the bar visible despite stale AX proofs")
  check(!HUDVerificationGrace.holdsVisibleBar(
    hostContextActive: true, barVisible: true, verifiedNumber: 7,
    verifiedAt: HUDVerificationGrace.resumedVerifiedAt(graceNow.addingTimeInterval(-9), pausedAt: graceNow.addingTimeInterval(-2)),
    now: graceNow, windowStillOnScreen: true),
    "releasing the host still requires a fresh proof once the grace expires")
  check(HUDIdleSink.shouldSink(enabled: true, engaged: false, lastActivity: graceNow.addingTimeInterval(-9), now: graceNow),
        "an idle bar sinks once the quiet period elapses")
  check(!HUDIdleSink.shouldSink(enabled: true, engaged: false, lastActivity: graceNow.addingTimeInterval(-7), now: graceNow),
        "the bar stays visible before the idle delay elapses")
  check(!HUDIdleSink.shouldSink(enabled: true, engaged: true, lastActivity: graceNow.addingTimeInterval(-20), now: graceNow),
        "active engagement keeps the bar surfaced")
  check(!HUDIdleSink.shouldSink(enabled: false, engaged: false, lastActivity: graceNow.addingTimeInterval(-20), now: graceNow),
        "disabling idle sink keeps the bar surfaced")
  check(HUDIdleSink.sunkContentAlpha > 0.3 && HUDIdleSink.sunkContentAlpha < 0.9,
        "sunk values stay dimmed yet readable")
  // An activation handoff reports no frontmost application; that is unknown, not
  // another application, and must never hide the bar.
  check(HUDHostContext.isActive(front: nil, host: "com.example.host", selfBundle: "local.agent.stats"),
        "an unknown foreground keeps the host context")
  check(HUDHostContext.isActive(front: "com.example.host", host: "com.example.host", selfBundle: "local.agent.stats")
        && HUDHostContext.isActive(front: "local.agent.stats", host: "com.example.host", selfBundle: "local.agent.stats"),
        "the host and our own UI both count as the host context")
  check(!HUDHostContext.isActive(front: "com.apple.finder", host: "com.example.host", selfBundle: "local.agent.stats"),
        "a third application is not the host context")
  let panelsize=CGSize(width:300,height:360)
  let plan=PopupLayout.plan(anchor:bar,bar:bar,host:host,screen:screen,desired:panelsize)
  check(plan.direction == .down,"a top bar opens its detail card downward")
  check(host.contains(plan.frame),"popup contained")
  check(plan.frame.size==panelsize,"popup full size where room exists")
  let smallHost=CGRect(x:100,y:100,width:520,height:280)
  let smallBar=HUDPlacement(moduleCount:2,contentSize:CGSize(width:300,height:34)).frame(host:smallHost,screen:screen)
  let constrained=PopupLayout.plan(anchor:smallBar,bar:smallBar,host:smallHost,screen:screen,desired:CGSize(width:300,height:800))
  check(smallHost.contains(constrained.frame),"small window popup stays inside");check(constrained.frame.height<800,"long content gets bounded scroll viewport")
  let secondary=CGRect(x:-1920,y:-120,width:1920,height:1080),secondaryHost=CGRect(x:-1850,y:-80,width:800,height:600)
  check(secondaryHost.contains(HUDPlacement().frame(host:secondaryHost,screen:secondary)),"negative-coordinate monitor")
  // A host partially behind the screen edge keeps the bar on the visible top edge.
  let clippedHost=CGRect(x:-180,y:100,width:300,height:240),clippedScreen=CGRect(x:0,y:0,width:1440,height:900)
  let clippedBar=HUDPlacement(moduleCount:6,contentSize:CGSize(width:600,height:34)).frame(host:clippedHost,screen:clippedScreen)
  let clippedArea=HUDPlacement.container(host:clippedHost,screen:clippedScreen)
  check(clippedScreen.contains(clippedBar) && clippedBar.maxY==clippedArea.maxY,"an offscreen host keeps the bar visible at its clipped top edge")
  check(HUDPlacement.clamp(CGRect(x:-500,y:-500,width:120,height:34),to:area)==CGRect(x:area.minX,y:area.minY,width:120,height:34),"clamping recovers a fully outside rectangle")

  let cg=CGRect(x:-1400,y:-200,width:600,height:450)
  check(HUDHostGeometry.appKitFrame(HUDHostGeometry.appKitFrame(cg,desktopTop:900),desktopTop:900)==cg,"multi-monitor coordinate conversion is reversible")
  let compact=HUDHostWindow(number:2,frame:CGRect(x:20,y:30,width:360,height:240))
  let large=HUDHostWindow(number:3,frame:host)
  let tiny=HUDHostWindow(number:1,frame:CGRect(x:20,y:30,width:100,height:80))
  let offscreen=HUDHostWindow(number:4,frame:CGRect(x:4000,y:30,width:800,height:600))
  check(HUDHostGeometry.select([tiny,offscreen,compact,large],screens:[screen],verifiedMain:2)?.number==2,"verified small main windows remain supported")
  check(HUDHostGeometry.select([compact,large],screens:[screen],verifiedMain:3,retaining:3)?.number==3,"HUD interaction retains its original verified host window")
  check(HUDHostGeometry.select([compact],screens:[screen],verifiedMain:3,retaining:3)==nil,"a disappearing host is never replaced with another during HUD interaction")
  check(HUDHostGeometry.screen(for:secondaryHost,screens:[screen,secondary])==secondary,"monitor selection uses the host's visible overlap")
  let filePanel=HUDHostWindow(number:5,frame:CGRect(x:300,y:200,width:700,height:450))
  check(HUDHostGeometry.select([filePanel,large],screens:[screen])==nil,"an unclassified front file picker must not become the HUD host")
  check(HUDHostGeometry.select([compact,large],screens:[screen])==nil,"an unclassified tool window cannot be selected by size or z-order")
  check(HUDHostGeometry.select([filePanel,large],screens:[screen],verifiedMain:3)?.number==3,"verified identity wins over a front file picker's size and ordering")
  check(HUDHostGeometry.select([large],screens:[screen],verifiedMain:5)==nil,"a stale or missing verified window is never replaced")
  check(HUDHostGeometry.select([compact,large],screens:[screen],verifiedMain:2,retaining:3)==nil,"HUD interaction cannot switch hosts after verification changes")
  check(!HUDHostGeometry.needsOrdering(panelVisible:true,panelIndex:2,hostIndex:3),"a HUD immediately above its host never needs reordering")
  check(!HUDHostGeometry.needsOrdering(panelVisible:true,panelIndex:1,hostIndex:5),"inspectors or system windows between a HUD and its host never force reordering")
  check(!HUDHostGeometry.needsOrdering(panelVisible:true,panelIndex:0,hostIndex:4),"the frontmost HUD remains in place above its host")
  check(!HUDHostGeometry.needsOrdering(panelVisible:true,panelIndex:3,hostIndex:3),"equal indices are not treated as the HUD being behind its host")
  check(HUDHostGeometry.needsOrdering(panelVisible:true,panelIndex:5,hostIndex:3),"a host brought in front of the HUD requires relative reordering")
  check(HUDHostGeometry.needsOrdering(panelVisible:true,panelIndex:1,hostIndex:0),"a frontmost host requires its obscured HUD to be restored")
  check(HUDHostGeometry.needsOrdering(panelVisible:false,panelIndex:2,hostIndex:3),"a hidden HUD must be shown even when cached indices put it above its host")
  check(HUDHostGeometry.needsOrdering(panelVisible:true,panelIndex:nil,hostIndex:3),"a HUD missing from the window list requires restoring")
  check(HUDHostGeometry.needsOrdering(panelVisible:true,panelIndex:2,hostIndex:nil),"an unavailable host index does not silently suppress relative ordering")
  check(HUDHostGeometry.needsOrdering(panelVisible:false,panelIndex:nil,hostIndex:nil),"initial presentation works before either window index is known")
  var identity=HUDHostIdentity(role:"AXWindow",subrole:"AXStandardWindow",isMain:true,isFocused:true,isModal:false,isMinimized:false,hasSheet:false,documentURLs:["app://-/index.html"])
  check(identity.permitsHUD(provider:"codex",requireFocused:true),"the focused native main window with the primary document is accepted")
  for subrole in ["AXDialog","AXSystemDialog","AXFloatingWindow","AXSystemFloatingWindow"]{
   var other=identity;other.subrole=subrole
   check(!other.permitsHUD(provider:"codex",requireFocused:true),"dialog and floating subroles never qualify as primary windows")
  }
  var blocked=identity;blocked.hasSheet=true
  check(!blocked.permitsHUD(provider:"codex",requireFocused:true),"a file-picker sheet hides the HUD even while AXMainWindow still refers to its parent")
  blocked=identity;blocked.isModal=true
  check(!blocked.permitsHUD(provider:"codex",requireFocused:true),"modal standard windows are not primary HUD targets")
  blocked=identity;blocked.isFocused=false
  check(!blocked.permitsHUD(provider:"codex",requireFocused:true),"focusing an auxiliary window suppresses the main HUD")
  check(blocked.permitsHUD(provider:"codex",requireFocused:false),"HUD-owned controls can retain their verified main host")
  blocked=identity;blocked.isMain=false
  check(!blocked.permitsHUD(provider:"codex",requireFocused:false),"a non-main window is rejected even during HUD interaction")
  blocked=identity;blocked.documentURLs=nil
  check(!blocked.permitsHUD(provider:"codex",requireFocused:true),"unavailable document identity fails closed")
  for path in ["/avatar-overlay","/hotkey-window","/global-dictation","/quick-chat","/debug","/detached-window"]{
   var components=URLComponents(string:"app://-/index.html")!;components.queryItems=[URLQueryItem(name:"initialRoute",value:path)]
   blocked=identity;blocked.documentURLs=[components.string!]
   check(!blocked.permitsHUD(provider:"codex",requireFocused:true),"auxiliary surfaces are excluded even if their native window looks standard")
  }
  identity.documentURLs=["app://-/index.html?initialRoute=%2Flocal%2F01234567-89ab-cdef-0123-456789abcdef"]
  check(identity.permitsHUD(provider:"codex",requireFocused:true),"a primary startup route identifies the surface without resolving any session")
  identity.documentURLs=["app://renderer/sessions/session_abc"]
  check(identity.permitsHUD(provider:"kimi",requireFocused:true),"Kimi primary session windows are accepted")
  let kimiOverlay="app://renderer/browser-overlay.html"
  for mainDocument in ["app://renderer/","app://renderer/sessions/session_abc"] {
   for urls in [[mainDocument,kimiOverlay],[kimiOverlay,mainDocument]] {
    var kimiMain=identity;kimiMain.documentURLs=urls
    check(kimiMain.permitsHUD(provider:"kimi",requireFocused:true),"Kimi's native main window remains valid with its attached browser overlay document")
    var auxiliary=kimiMain;auxiliary.hasSheet=true
    check(!auxiliary.permitsHUD(provider:"kimi",requireFocused:true),"Kimi's attached overlay never overrides an open file-picker sheet")
    auxiliary=kimiMain;auxiliary.isFocused=false
    check(!auxiliary.permitsHUD(provider:"kimi",requireFocused:true),"Kimi's attached overlay never overrides focus on another window")
    auxiliary=kimiMain;auxiliary.isMain=false
    check(!auxiliary.permitsHUD(provider:"kimi",requireFocused:false),"Kimi's attached overlay never turns a secondary window into a main window")
    auxiliary=kimiMain;auxiliary.isModal=true
    check(!auxiliary.permitsHUD(provider:"kimi",requireFocused:true),"Kimi's attached overlay never overrides native modality")
    auxiliary=kimiMain;auxiliary.isMinimized=true
    check(!auxiliary.permitsHUD(provider:"kimi",requireFocused:true),"Kimi's attached overlay never overrides a minimized host")
   }
  }
  check(!HUDHostIdentity.isPrimaryDocument(kimiOverlay,provider:"kimi"),"the companion overlay cannot identify a main window by itself")
  for urls in [[kimiOverlay],[kimiOverlay,kimiOverlay],[kimiOverlay,"https://example.com"],["app://renderer/",kimiOverlay,"app://renderer/browser-control.html"],["app://renderer/",kimiOverlay,"https://example.com"]] {
   var auxiliary=identity;auxiliary.documentURLs=urls
   check(!auxiliary.permitsHUD(provider:"kimi",requireFocused:true),"overlay-only windows and unrelated extra documents remain rejected")
  }
  for extra in [kimiOverlay+"?dialog=1",kimiOverlay+"#dialog","app://renderer/browser-overlay.html/","https://renderer/browser-overlay.html","app://other/browser-overlay.html"] {
   var auxiliary=identity;auxiliary.documentURLs=["app://renderer/",extra]
   check(!auxiliary.permitsHUD(provider:"kimi",requireFocused:true),"only the exact observed Kimi companion document is accepted")
  }
  var otherProvider=identity;otherProvider.documentURLs=["app://-/index.html",kimiOverlay]
  check(!otherProvider.permitsHUD(provider:"codex",requireFocused:true),"the Kimi companion exception never applies to Codex")
  identity.documentURLs=["https://example.com"]
  check(!identity.permitsHUD(provider:"kimi",requireFocused:true),"external documents never identify a Kimi main window")
  var proof=HUDHostProof();let now=Date(timeIntervalSince1970:100)
  proof.prepare(key:"pid:main",requireFocused:true)
  let initialGeneration=proof.generation
  proof.accept(3,focusConfirmed:true,key:"pid:main",generation:initialGeneration,checkedAt:now)
  check(proof.current(at:now)==3,"fresh matching verification enables its exact window")
  check(proof.current(at:now.addingTimeInterval(0.8))==nil,"expired verification hides the HUD")
  check(proof.current(at:now.addingTimeInterval(-0.1))==nil,"a proof from a future timestamp never qualifies")
  proof.prepare(key:"pid:main",requireFocused:false)
  let interactionGeneration=proof.generation
  check(interactionGeneration != initialGeneration,"entering HUD interaction invalidates pending requests from the old focus policy")
  check(proof.current(at:now)==3,"opening HUD controls does not flicker or discard a stricter main-window proof")
  proof.accept(nil,focusConfirmed:false,key:"pid:main",generation:initialGeneration,checkedAt:now)
  check(proof.current(at:now)==3,"a late focused-policy failure cannot erase proof during HUD interaction")
  proof.prepare(key:"pid:main",requireFocused:true)
  check(proof.current(at:now)==3,"returning to the host preserves fresh proof that already confirmed its focus")
  check(proof.generation != interactionGeneration,"returning to the host invalidates pending requests from the relaxed focus policy")
  proof.accept(nil,focusConfirmed:false,key:"pid:main",generation:interactionGeneration,checkedAt:now)
  check(proof.current(at:now)==3,"a late relaxed-policy failure cannot erase preserved focused proof")
  check(proof.current(at:now.addingTimeInterval(0.8))==nil,"focus policy changes never extend the lifetime of cached proof")
  // A relaxed request can still observe and recheck the host's actual focus.
  proof.prepare(key:"pid:main",requireFocused:false)
  proof.accept(3,focusConfirmed:true,key:"pid:main",generation:proof.generation,checkedAt:now)
  proof.prepare(key:"pid:main",requireFocused:true)
  check(proof.current(at:now)==3,"actual focus confirmation survives returning from a relaxed request")
  // Identity-only proof is valid for HUD controls, never for a focused-host request.
  proof.prepare(key:"pid:main",requireFocused:false)
  let weakGeneration=proof.generation
  proof.accept(3,focusConfirmed:false,key:"pid:main",generation:weakGeneration,checkedAt:now)
  check(proof.current(at:now)==3,"verified identity can retain its host while HUD controls own focus")
  proof.prepare(key:"pid:main",requireFocused:true)
  check(proof.current(at:now)==nil,"returning to the host cannot promote an identity-only proof to focused proof")
  proof.accept(3,focusConfirmed:false,key:"pid:main",generation:weakGeneration,checkedAt:now)
  check(proof.current(at:now)==nil,"a late weak result is ignored after returning to the host")
  proof.accept(3,focusConfirmed:false,key:"pid:main",generation:proof.generation,checkedAt:now)
  check(proof.current(at:now)==nil,"a focused request rejects results without actual focus confirmation")
  proof.accept(3,focusConfirmed:true,key:"pid:main",generation:proof.generation,checkedAt:now)
  proof.accept(nil,focusConfirmed:false,key:"pid:main",generation:proof.generation,checkedAt:now)
  check(proof.current(at:now)==nil,"a current validation failure hides the HUD immediately")
  proof.prepare(key:"pid:main",requireFocused:false);proof.prepare(key:"pid:main",requireFocused:true)
  check(proof.current(at:now)==nil,"policy changes cannot revive proof after a current validation failure")
  let focusGeneration=proof.generation
  proof.reset();proof.prepare(key:"pid:main",requireFocused:true)
  proof.accept(3,focusConfirmed:true,key:"pid:main",generation:focusGeneration,checkedAt:now)
  check(proof.current(at:now)==nil,"leaving and returning to the same window cannot revive stale results")
  proof.accept(3,focusConfirmed:true,key:"pid:main",generation:proof.generation,checkedAt:now)
  let mainGeneration=proof.generation
  proof.prepare(key:"pid:picker,main",requireFocused:true)
  check(proof.current(at:now)==nil,"a newly visible file picker invalidates proof immediately")
  proof.accept(3,focusConfirmed:true,key:"pid:main",generation:mainGeneration,checkedAt:now)
  check(proof.current(at:now)==nil,"a late main-window result cannot override a newly visible file picker")
  proof.prepare(key:"pid:main",requireFocused:true)
  check(proof.current(at:now)==nil,"closing the file picker still requires a fresh main-window verification")
  for click in 0..<20 {
   let checkedAt=now.addingTimeInterval(Double(click))
   proof.accept(3,focusConfirmed:true,key:"pid:main",generation:proof.generation,checkedAt:checkedAt)
   proof.prepare(key:"pid:main",requireFocused:false)
   check(proof.current(at:checkedAt.addingTimeInterval(0.1))==3,"repeated HUD clicks retain fresh focused proof")
   proof.prepare(key:"pid:main",requireFocused:true)
   check(proof.current(at:checkedAt.addingTimeInterval(0.2))==3,"repeated returns to the host never create a blank proof interval")
  }
  // Deterministic property loop across hosts, screens and metric counts.
  for i in 0..<200 {
   let h=CGRect(x:CGFloat(i%13)*57-170,y:CGFloat(i%9)*31-80,width:500+CGFloat(i%7)*90,height:280+CGFloat(i%11)*45)
   let b=HUDPlacement(moduleCount:i%5,contentSize:CGSize(width:120+CGFloat(i%9)*70,height:34)).frame(host:h,screen:screen)
   check(h.contains(b)&&screen.contains(b),"the bar property holds for its host and screen")
   let p=PopupLayout.plan(anchor:b,bar:b,host:h,screen:screen,desired:CGSize(width:300,height:420))
   check(h.contains(p.frame)&&screen.contains(p.frame),"popup property")
  }

  print("\(checks) layout checks passed")
 }
}
