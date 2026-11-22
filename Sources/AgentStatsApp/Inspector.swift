import StatsCore
import StatsAdapters
import AppKit

struct InspectorChoice:Equatable {let id:String;let title:String;var selected:Bool=false;var enabled:Bool=true;var navigation:Bool=false}
final class FlippedContent:NSView {override var isFlipped:Bool{true}}
/// One shared metric-row pitch so the card height formula and the rows agree.
let inspectorRowHeight:CGFloat=24
final class HUDInspector:NSObject,NSSearchFieldDelegate {
 let window:HUDPanel
 let canvas=FlippedContent();let scroll=NSScrollView();let heading=NSTextField(labelWithString:"");let search=NSSearchField();let back=NSButton()
 private var onBack:(()->Void)?
 var kind:String?;weak var anchor:NSView?;weak var owner:NSWindow?
 var choices=[InspectorChoice]();var rows=[(String,String)]();var note="";var onChoice:((String)->Void)?
 var desired=CGSize(width:300,height:260);var searchable=false;var toggleable=false
 private var rowsSignature="";private var bodyInitialized=false
 private var customBody:((CGFloat)->NSView)?
 private var fittedBody:((CGSize)->NSView)?
 var isShown:Bool{window.isVisible}
 override init(){
  window=HUDPanel(contentRect:NSRect(x:0,y:0,width:300,height:260),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
  super.init()
  window.level = .normal;window.hidesOnDeactivate=false;window.isOpaque=false;window.backgroundColor = .clear;window.hasShadow=true
  window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
  let glass=NSVisualEffectView();glass.material = .popover;glass.state = .active;glass.blendingMode = .behindWindow;glass.wantsLayer=true;glass.layer?.cornerRadius=12;glass.layer?.masksToBounds=true;glass.layer?.borderWidth=0.5;glass.layer?.borderColor=NSColor.separatorColor.cgColor
  canvas.autoresizingMask=[.width,.height];glass.addSubview(canvas);window.contentView=glass
  heading.font = .systemFont(ofSize:13,weight:.semibold);canvas.addSubview(heading)
  let close=NSButton(image:NSImage(systemSymbolName:"xmark",accessibilityDescription:"关闭展开面板")!,target:self,action:#selector(dismiss));close.isBordered=false;close.bezelStyle = .recessed;close.setAccessibilityLabel("关闭展开面板");close.identifier=NSUserInterfaceItemIdentifier("inspector-close");canvas.addSubview(close)
  scroll.scrollerStyle = .overlay;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.drawsBackground=false;scroll.borderType = .noBorder;canvas.addSubview(scroll)
  back.isBordered=false;back.bezelStyle = .recessed;back.alignment = .left;back.font = .systemFont(ofSize:12)
  back.target=self;back.action=#selector(goBack);back.identifier=NSUserInterfaceItemIdentifier("inspector-back");back.isHidden=true;canvas.addSubview(back)
  search.placeholderString="搜索会话";search.delegate=self;search.font = .systemFont(ofSize:12);canvas.addSubview(search)
 }
 func close(){owner?.removeChildWindow(window);window.orderOut(nil);window.setHostOverlayActive(false);kind=nil;anchor=nil;onChoice=nil;onBack=nil;back.isHidden=true;customBody=nil;fittedBody=nil}
 @objc private func dismiss(){close()}
 func present(kind:String,title:String,rows:[(String,String)]=[],note:String="",choices:[InspectorChoice]=[],searchable:Bool=false,toggleable:Bool=false,anchor:NSView,host:NSRect,screen:NSRect,bar:NSRect,display:Bool=true,attachToOwner:Bool=true,customSize:CGSize?=nil,customBody:((CGFloat)->NSView)?=nil,fittedBody:((CGSize)->NSView)?=nil,onChoice:((String)->Void)?=nil){
  close();self.kind=kind;self.anchor=anchor;self.owner=attachToOwner ? anchor.window:nil;self.rows=rows;self.note=note;self.choices=choices;self.searchable=searchable;self.toggleable=toggleable;self.onChoice=onChoice;self.rowsSignature="";self.bodyInitialized=false;heading.stringValue=title;window.title=title;search.stringValue="";search.isHidden = !searchable
  window.level=owner?.level ?? .normal
  let measuredNote=(note as NSString).boundingRect(with:NSSize(width:268,height:1000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:NSFont.systemFont(ofSize:11)]).height
  let noteHeight:CGFloat=note.isEmpty ? 0:ceil(measuredNote)+8
  let notePadding:CGFloat=note.isEmpty ? 0:10+noteHeight
  let metricHeight:CGFloat=CGFloat(rows.count)*inspectorRowHeight+68+notePadding
  let choiceHeader:CGFloat=searchable ? 96:56
  let choiceHeight:CGFloat=CGFloat(choices.count)*32+choiceHeader
  let height:CGFloat=choices.isEmpty ? min(340,metricHeight):min(440,choiceHeight)
  self.customBody=customBody;self.fittedBody=fittedBody;scroll.hasVerticalScroller=fittedBody == nil;desired=customSize ?? CGSize(width:300,height:height)
  position(host:host,screen:screen,bar:bar)
  if display{owner?.addChildWindow(window,ordered:.above);window.makeKeyAndOrderFront(nil)}
 }
 func position(host:NSRect,screen:NSRect,bar:NSRect){
  guard let anchor=anchor,let owning=anchor.window else{return}
  owning.contentView?.layoutSubtreeIfNeeded()
  let anchorRect=owning.convertToScreen(anchor.convert(anchor.bounds,to:nil))
  let plan=PopupLayout.plan(anchor:anchorRect,bar:bar,host:host,screen:screen,desired:desired)
  let changed=window.frame.size != plan.frame.size
  if window.frame != plan.frame{window.setFrame(plan.frame,display:true)};canvas.frame=NSRect(origin:.zero,size:plan.frame.size)
  let w=plan.frame.width,h=plan.frame.height
  heading.frame=NSRect(x:16,y:13,width:max(40,w-60),height:22)
  canvas.subviews.first{$0.identifier?.rawValue=="inspector-close"}?.frame=NSRect(x:w-36,y:12,width:22,height:22)
  let backHeight:CGFloat=back.isHidden ? 0:30
  back.frame=NSRect(x:14,y:43,width:w-28,height:26)
  search.frame=NSRect(x:14,y:46+backHeight,width:w-28,height:26)
  let y:CGFloat=(searchable ? 82:46)+backHeight
  scroll.frame=NSRect(x:0,y:y,width:w,height:max(20,h-y-8))
  if changed || !bodyInitialized{rebuildBody()}
 }
 func update(rows:[(String,String)],note:String){
  guard choices.isEmpty,customBody==nil,fittedBody==nil else{return};self.rows=rows;self.note=note
  let sig=rows.map{$0.0+"="+$0.1}.joined(separator:"|")+note
  if sig != rowsSignature{rebuildBody()}
 }
 func updateChoices(_ choices:[InspectorChoice]){
  guard kind=="sessions",self.choices != choices else{return}
  self.choices=choices;desired.height=min(440,CGFloat(choices.count)*32+(searchable ? 96:56)+(back.isHidden ? 0:30))
  rebuildBody()
 }
 func setChoiceLevel(title:String,choices:[InspectorChoice],backTitle:String?=nil,onBack:(()->Void)?=nil){
  heading.stringValue=SessionTitle.singleLine(title);heading.lineBreakMode = .byTruncatingTail;heading.toolTip=title;window.title=title
  self.onBack=onBack;back.isHidden=backTitle == nil;back.title=backTitle.map{"‹  "+$0} ?? "";back.setAccessibilityLabel(backTitle.map{"返回"+$0} ?? "返回")
  search.placeholderString=backTitle == nil ? "搜索项目":"搜索对话";search.stringValue=""
  self.choices=choices;desired.height=min(440,CGFloat(choices.count)*32+96+(back.isHidden ? 0:30));rebuildBody(resetScroll:true)
 }
 @objc private func goBack(){onBack?()}
 func controlTextDidChange(_ obj:Notification){rebuildBody(resetScroll:true)}
 func refreshCustomBody(){guard customBody != nil || fittedBody != nil else{return};rebuildBody()}
 private func rebuildBody(resetScroll:Bool=false){
  let w=scroll.contentSize.width,oldY=resetScroll ? 0:scroll.contentView.bounds.minY
  if let fittedBody {
   let size=scroll.contentSize,doc=fittedBody(size);doc.frame=NSRect(origin:.zero,size:size)
   scroll.documentView=doc;scroll.contentView.scroll(to:.zero);scroll.reflectScrolledClipView(scroll.contentView)
   bodyInitialized=true;return
  }
  if let customBody {
   let doc=customBody(w);scroll.documentView=doc
   scroll.contentView.scroll(to:NSPoint(x:0,y:min(oldY,max(0,doc.frame.height-scroll.contentSize.height))));scroll.reflectScrolledClipView(scroll.contentView)
   bodyInitialized=true;return
  }
  let doc=FlippedContent();var y:CGFloat=6
  if !choices.isEmpty || kind == "sessions" {
   let query=search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
   let filtered=choices.filter{query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)}
   for choice in filtered{
    let b=NSButton(title:(choice.selected ? "✓  ":"    ")+SessionTitle.singleLine(choice.title)+(choice.navigation ? "  ›":""),target:self,action:#selector(pick(_:)));b.identifier=NSUserInterfaceItemIdentifier(choice.id);b.isEnabled=choice.enabled;b.isBordered=false;b.bezelStyle = .recessed;b.alignment = .left;b.font = .systemFont(ofSize:12);b.cell?.usesSingleLineMode=true;b.cell?.wraps=false;b.lineBreakMode = .byTruncatingTail;b.toolTip=choice.title;b.frame=NSRect(x:10,y:y,width:max(40,w-20),height:30);doc.addSubview(b);y+=32
   }
   if filtered.isEmpty{let empty=NSTextField(labelWithString:back.isHidden ? "没有匹配的项目":query.isEmpty ? "暂无对话":"没有匹配的对话");empty.textColor = .secondaryLabelColor;empty.frame=NSRect(x:16,y:y,width:w-32,height:24);doc.addSubview(empty);y+=30}
  }else{
   for (title,value) in rows{
    let a=NSTextField(labelWithString:title),b=NSTextField(labelWithString:value);a.font = .systemFont(ofSize:11);a.textColor = .secondaryLabelColor;a.lineBreakMode = .byTruncatingTail;a.toolTip=title
    b.font = .monospacedDigitSystemFont(ofSize:11,weight:.medium);b.alignment = .right;b.lineBreakMode = .byTruncatingTail;b.toolTip=value
    a.frame=NSRect(x:12,y:y+2,width:max(50,w-128),height:18);b.frame=NSRect(x:max(66,w-112),y:y+2,width:100,height:18);doc.addSubview(a);doc.addSubview(b);y+=inspectorRowHeight
   }
   if !note.isEmpty{
    y+=10;let n=NSTextField(wrappingLabelWithString:note);n.font = .systemFont(ofSize:11);n.textColor = .secondaryLabelColor
    let width=max(80,w-32);let height=ceil((note as NSString).boundingRect(with:NSSize(width:width,height:1000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:NSFont.systemFont(ofSize:11)]).height)+8
    n.frame=NSRect(x:16,y:y,width:width,height:height);doc.addSubview(n);y+=height
   }
  }
  doc.frame=NSRect(x:0,y:0,width:w,height:y+8);scroll.documentView=doc
  scroll.contentView.scroll(to:NSPoint(x:0,y:min(oldY,max(0,doc.frame.height-scroll.contentSize.height))));scroll.reflectScrolledClipView(scroll.contentView)
  bodyInitialized=true;rowsSignature=rows.map{$0.0+"="+$0.1}.joined(separator:"|")+note
 }
 @objc private func pick(_ sender:NSButton){
  guard sender.isEnabled,let id=sender.identifier?.rawValue else{return}
  if toggleable,let i=choices.firstIndex(where:{$0.id==id}){choices[i].selected.toggle();rebuildBody();onChoice?(id);return}
  let callback=onChoice
  if choices.first(where:{$0.id==id})?.navigation == true{callback?(id);return}
  close();callback?(id)
 }
}
