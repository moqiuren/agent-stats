import StatsCore
import StatsAdapters
import AppKit

private final class AgentLabel:NSTextField {
    override func hitTest(_ point:NSPoint)->NSView?{nil}
}

private final class AgentDecoration:NSImageView {
    override func hitTest(_ point:NSPoint)->NSView?{nil}
}

// Navigation uses the same label geometry as the body, instead of mixing
// NSButton cell insets/baselines with NSTextField insets/baselines.
private final class AgentActionButton:NSButton {
    override var isFlipped:Bool{true}
    let caption=AgentLabel(labelWithString:"")
    private var chevron:AgentDecoration?
    override var isEnabled:Bool {
        didSet {
            let color:NSColor=isEnabled ? .labelColor:.disabledControlTextColor
            caption.textColor=color;chevron?.contentTintColor=color
        }
    }
    init(text:String,frame:NSRect,target:AnyObject?,action:Selector){
        super.init(frame:frame);self.target=target;self.action=action
        title="";isBordered=false;bezelStyle = .recessed
        caption.stringValue=text;caption.font = .systemFont(ofSize:12)
        caption.frame=NSRect(x:0,y:3,width:frame.width,height:20)
        caption.alignment = .center;caption.lineBreakMode = .byTruncatingTail
        caption.cell?.usesSingleLineMode=true;caption.setAccessibilityElement(false)
        addSubview(caption);setAccessibilityLabel(text)
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    func align(_ alignment:NSTextAlignment,textFrame:NSRect,symbol:String,symbolFrame:NSRect){
        caption.alignment=alignment;caption.frame=textFrame
        let icon=AgentDecoration(frame:symbolFrame)
        icon.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil)
        icon.contentTintColor = .labelColor;icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false);addSubview(icon);chevron=icon
    }
}

final class AgentInspectorView:NSView {
    override var isFlipped:Bool{true}
    private var actions=[Int:()->Void]()
    private let layout:AgentPageLayout
    private static let secondary=NSColor(name:nil){appearance in
        appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(white:0.78,alpha:1):NSColor(white:0.30,alpha:1)
    }
    init(size:CGSize,inventory:AgentInventory,state:AgentInspectorState,hasSession:Bool,
         onOpen:@escaping(String)->Void,onBack:@escaping()->Void,onPage:@escaping(Int)->Void) {
        layout=AgentPageLayout(size:size)
        super.init(frame:NSRect(origin:.zero,size:size))
        if let selected=state.selectedID {
            detail(inventory.entry(selected),page:state.detailPage,onBack:onBack,onPage:onPage)
        }else{list(inventory,page:state.listPage,hasSession:hasSession,onOpen:onOpen,onPage:onPage)}
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    private func label(_ text:String,frame:NSRect,size:CGFloat=12,weight:NSFont.Weight = .regular,secondary:Bool=false)->NSTextField {
        let label=AgentLabel(labelWithString:SessionTitle.singleLine(text));label.frame=frame
        label.font = .systemFont(ofSize:size,weight:weight);label.textColor=secondary ? Self.secondary:.labelColor
        label.lineBreakMode = .byTruncatingTail;label.cell?.usesSingleLineMode=true;label.cell?.wraps=false;label.toolTip=text
        addSubview(label);return label
    }
    private func button(_ text:String,frame:NSRect,id:String,action:@escaping()->Void)->AgentActionButton {
        let button=AgentActionButton(text:text,frame:frame,target:self,action:#selector(invoke(_:)))
        button.identifier=NSUserInterfaceItemIdentifier(id);button.tag=actions.count;actions[button.tag]=action
        addSubview(button);return button
    }
    @objc private func invoke(_ sender:NSButton){actions[sender.tag]?()}
    private func row(_ entry:AgentEntry,y:CGFloat,height:CGFloat,onOpen:@escaping(String)->Void) {
        let width=bounds.width-16
        let control=button("",frame:NSRect(x:8,y:y,width:width,height:height-4),id:"agent-row-"+entry.id){onOpen(entry.id)}
        control.wantsLayer=true;control.layer?.cornerRadius=8;control.layer?.masksToBounds=true
        control.layer?.backgroundColor=NSColor.labelColor.withAlphaComponent(entry.isMain ? 0.07:0.035).cgColor
        let top=layout.compact ? y+6:y+3
        let name=label(entry.name,frame:NSRect(x:16,y:top,width:max(40,bounds.width-168),height:20),weight:.medium)
        name.identifier=NSUserInterfaceItemIdentifier("agent-name-"+entry.id)
        if !layout.compact {
            let subtitle=label(entry.isMain ? (SessionTitle.nonempty(entry.record["model"]) ?? "主代理") : Self.activity(entry.record),
                    frame:NSRect(x:16,y:y+24,width:max(40,bounds.width-168),height:14),size:10,secondary:true)
            subtitle.identifier=NSUserInterfaceItemIdentifier("agent-subtitle-"+entry.id)
        }
        let value=count(entry.record["totalTokens"])+" Token"
        let valueLabel=label(value,frame:NSRect(x:bounds.width-140,y:top,width:100,height:20),size:12,weight:.medium)
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize:12,weight:.medium)
        valueLabel.identifier=NSUserInterfaceItemIdentifier("agent-tokens-"+entry.id)
        let arrow=AgentDecoration(frame:NSRect(x:bounds.width-28,y:top+5,width:10,height:10))
        arrow.image=NSImage(systemSymbolName:"chevron.right",accessibilityDescription:nil)
        arrow.contentTintColor=Self.secondary;arrow.setAccessibilityElement(false);addSubview(arrow)
        control.setAccessibilityLabel(entry.role+"，"+entry.name+"，"+value+"，查看详情")
    }
    private func pager(page:Int,pages:Int,onPage:@escaping(Int)->Void) {
        guard pages>1 else{return}
        let y=max(0,bounds.height-28)
        let previous=button("上页",frame:NSRect(x:0,y:y,width:96,height:26),id:"agent-previous-page"){onPage(-1)}
        let next=button("下页",frame:NSRect(x:bounds.width-96,y:y,width:96,height:26),id:"agent-next-page"){onPage(1)}
        previous.align(.left,textFrame:NSRect(x:16,y:3,width:76,height:20),symbol:"chevron.left",symbolFrame:NSRect(x:3,y:8,width:8,height:10))
        next.align(.right,textFrame:NSRect(x:4,y:3,width:76,height:20),symbol:"chevron.right",symbolFrame:NSRect(x:85,y:8,width:8,height:10))
        previous.isEnabled=page>0;next.isEnabled=page<pages-1
        previous.setAccessibilityLabel("上一页");next.setAccessibilityLabel("下一页")
        let count=label("\(page+1) / \(pages)",frame:NSRect(x:96,y:y+3,width:max(30,bounds.width-192),height:20),size:12,secondary:true)
        count.alignment = .center;count.identifier=NSUserInterfaceItemIdentifier("agent-page-number")
    }
    private func list(_ inventory:AgentInventory,page:Int,hasSession:Bool,onOpen:@escaping(String)->Void,onPage:@escaping(Int)->Void) {
        var y:CGFloat=6
        if let main=inventory.main {row(main,y:y,height:layout.rowHeight,onOpen:onOpen);y+=layout.rowHeight+8}
        let title=inventory.known ? "子代理 · \(inventory.children.count)":"子代理"
        let section=label(title,frame:NSRect(x:16,y:y,width:bounds.width-32,height:22),weight:.semibold)
        section.identifier=NSUserInterfaceItemIdentifier("agent-section-title")
        y+=24
        guard !inventory.children.isEmpty else {
            let message = !hasSession ? "暂无会话统计":inventory.known ? "暂无子代理":"未提供子代理记录"
            let empty=label(message,frame:NSRect(x:16,y:y+12,width:bounds.width-32,height:24),size:12,secondary:true)
            empty.identifier=NSUserInterfaceItemIdentifier("agent-empty-state");return
        }
        let capacity=layout.listCapacity(hasMain:inventory.main != nil),pages=(inventory.children.count+capacity-1)/capacity
        let page=min(max(0,page),pages-1),start=page*capacity
        for (index,entry) in inventory.children.dropFirst(start).prefix(capacity).enumerated(){row(entry,y:y+CGFloat(index)*layout.rowHeight,height:layout.rowHeight,onOpen:onOpen)}
        pager(page:page,pages:pages,onPage:onPage)
    }
    private func detail(_ entry:AgentEntry?,page:Int,onBack:@escaping()->Void,onPage:@escaping(Int)->Void) {
        let back=button("代理列表",frame:NSRect(x:0,y:2,width:116,height:26),id:"agent-back",action:onBack)
        back.align(.left,textFrame:NSRect(x:16,y:3,width:96,height:20),symbol:"chevron.left",symbolFrame:NSRect(x:3,y:8,width:8,height:10))
        guard let entry else{
            _=label("该代理已不可用",frame:NSRect(x:16,y:42,width:bounds.width-32,height:24),secondary:true);return
        }
        let name=label(entry.name,frame:NSRect(x:16,y:layout.titleY,width:bounds.width-32,height:layout.nameHeight),size:layout.compact ? 14:16,weight:.semibold)
        name.identifier=NSUserInterfaceItemIdentifier("agent-detail-name")
        let model=SessionTitle.nonempty(entry.record["model"]) ?? "模型未知"
        var subtitleParts=[entry.role,model]
        // A subagent's task record supplies its profile, model and status; only the
        // values the host actually recorded are shown.
        if !entry.isMain {
            subtitleParts.append(contentsOf:[SessionTitle.nonempty(entry.record["agentType"]),
                                             SessionTitle.nonempty(entry.record["agentEffort"]).map{$0+" 思考"},
                                             Self.agentState(entry.record)].compactMap{$0})
        }
        let subtitle=label(subtitleParts.joined(separator:" · "),frame:NSRect(x:16,y:layout.subtitleY,width:bounds.width-32,height:layout.subtitleHeight),size:11,secondary:true)
        subtitle.identifier=NSUserInterfaceItemIdentifier("agent-detail-subtitle")
        let pages=layout.detailPages(Self.metricGroups(entry.record))
        let page=min(max(0,page),pages.count-1),visible=pages[page],values=visible.flatMap(\.metrics),columns=layout.columns
        let width=(bounds.width-32-CGFloat(columns-1)*16)/CGFloat(columns)
        var fontSize=layout.detailValueSize
        while fontSize>9 && values.contains(where:{($0.1 as NSString).size(withAttributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:fontSize,weight:.medium)]).width>max(1,width-4)}){fontSize-=1}
        let valueFont=NSFont.monospacedDigitSystemFont(ofSize:fontSize,weight:.medium)
        var y=layout.detailHeader
        for (groupIndex,group) in visible.enumerated(){
            let groupTop=y
            let heading=label(group.title,frame:NSRect(x:16,y:groupTop,width:bounds.width-32,height:layout.groupTitleHeight-4),size:10,weight:.semibold,secondary:true)
            heading.identifier=NSUserInterfaceItemIdentifier("agent-group-"+group.title)
            let rule=NSView(frame:NSRect(x:16,y:groupTop+layout.groupRuleY,width:bounds.width-32,height:1))
            rule.wantsLayer=true;rule.layer?.backgroundColor=NSColor.separatorColor.withAlphaComponent(0.7).cgColor
            addSubview(rule)
            y=groupTop+layout.groupTitleHeight
            for (index,value) in group.metrics.enumerated(){
                let x=16+CGFloat(index%columns)*(width+16),top=y+CGFloat(index/columns)*layout.metricRowPitch
                let caption=label(value.0,frame:NSRect(x:x,y:top,width:width,height:layout.metricCaptionHeight),size:10,secondary:true)
                caption.identifier=NSUserInterfaceItemIdentifier("agent-metric-label-"+value.0)
                let number=label(value.1,frame:NSRect(x:x,y:top+layout.metricCaptionHeight,width:width,height:layout.metricValueHeight),size:fontSize,weight:.medium)
                number.font=valueFont
                number.identifier=NSUserInterfaceItemIdentifier("agent-metric-value-"+value.0)
                number.setAccessibilityLabel(value.0+"，"+value.1)
            }
            y+=CGFloat((group.metrics.count+columns-1)/columns)*layout.metricRowPitch
            if groupIndex<visible.count-1{y+=layout.groupGap}
        }
        pager(page:page,pages:pages.count,onPage:onPage)
    }
    // Subagent identity comes from the host's own task records. A running turn wins
    // over a recorded status, and a value the host never wrote stays missing.
    static func agentState(_ record:JSONObject)->String {
        let states=["running":"运行中","completed":"已结束","killed":"已终止","failed":"失败"]
        if record["active"] as? Bool == true {return "运行中"}
        return SessionTitle.nonempty(record["agentStatus"]).map{states[$0] ?? $0} ?? "未运行"
    }
    static func activity(_ record:JSONObject)->String {
        [SessionTitle.nonempty(record["agentType"]),agentState(record)].compactMap{$0}.joined(separator:" · ")
    }
    static func metricGroups(_ record:JSONObject)->[AgentMetricGroup] { MetricPresenter.agentGroups(record) }
    static func metrics(_ record:JSONObject)->[(String,String)] { MetricPresenter.agentMetrics(record) }
}
