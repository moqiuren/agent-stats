@testable import StatsCore
@testable import StatsAdapters
@testable import AgentStatsApp
import AppKit

// Existing AppKit fixtures retain native Int/Bool/NSNull inputs while the runtime
// consumes typed updates. These compatibility setters are not shipped in the app.
extension AppCoordinator {
    // Drive the title through rendering while preserving the collector fixtures
    // used by later routing checks; the coordinator's derived label stays private.
    func presentFixtureTitle(_ title: String) {
        let savedCatalog = stats.catalog, savedCurrent = stats.current, savedSelection = selected
        defer { stats.catalog = savedCatalog; stats.current = savedCurrent; selected = savedSelection }
        var value = stats.current?.values ?? [:]
        let id = value["id"] as? String ?? "layout-fixture"
        value["id"] = id; value["title"] = title
        stats.catalog.sessions = [StatsRecord(value)]
        selected = id; render()
    }

    var sessions: [JSONObject] {
        get { stats.catalog.sessions.map(\.values) }
        set { stats.catalog.sessions = newValue.map(StatsRecord.init) }
    }
    var projects: [JSONObject] {
        get { stats.catalog.projects.map(\.values) }
        set { stats.catalog.projects = newValue.map(StatsRecord.init) }
    }
    var agents: [JSONObject] {
        get { stats.catalog.agents.map(\.values) }
        set { stats.catalog.agents = newValue.map(StatsRecord.init) }
    }
    var sessionGroups: [JSONObject] {
        get { stats.catalog.groups.map(\.json) }
        set { stats.catalog.groups = newValue.compactMap(StatsGroup.init) }
    }
    var current: JSONObject? {
        get { stats.current?.values }
        set { stats.current = newValue.map(StatsRecord.init) }
    }
    var kimiSelection: JSONObject {
        get { stats.pageSelection.json }
        set { stats.pageSelection = PageSessionSelection(newValue) }
    }
    var nativeSelection: JSONObject {
        get { stats.nativeSelection.json }
        set { stats.nativeSelection = CurrentSession(json: newValue) }
    }
    var errorText: String? { stats.error }
    var lastReceived: Date { stats.lastReceived }
    func receive(_ value: JSONObject, generation: UUID? = nil) {
        guard let update = StatsUpdate(json: value, defaultProvider: provider) else { return }
        receive(update, generation: generation ?? readerGeneration)
    }
}

enum AppTests {
    static func run(provider: StatsProvider) {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        testMenuControls(provider)
        AgentInspectorTests.run(provider:provider)
        if provider == .codex { testPreferenceMigration();testProviderSwitching();testStatusItemVisibility();AppArchitectureTests.run() }
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition,message); checks += 1 }
        let suite = "stats-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let delegate = AppCoordinator(preferences:defaults,provider:provider)
        // Provider-specific fixtures must not switch when the human changes apps.
        delegate.followsActiveTool=false;delegate.hud.makePanel()
        let modeKey="displayMode."+provider.rawValue,otherModeKey="displayMode."+(provider.rawValue == "codex" ? "kimi":"codex")
        check(delegate.displayMode == .floating,"existing installations default to the floating presentation")
        defaults.set("future-mode",forKey:modeKey)
        check(delegate.displayMode == .floating,"unknown saved display modes safely fall back to floating")
        defaults.set("menuBar",forKey:otherModeKey)
        check(delegate.displayMode == .floating,"one product's display mode never changes the other product")
        delegate.displayMode = .menuBar
        check(AppCoordinator(preferences:UserDefaults(suiteName:suite)!,provider:provider).displayMode == .menuBar,"menu bar presentation persists across delegates")
        delegate.displayMode = .floating
        check(defaults.string(forKey:otherModeKey)=="menuBar","changing display modes preserves the other product's preference")
        let menu = delegate.menu.makeStatusMenu()
        let modeItems=menu.items.first{$0.title=="展示模式"}!.submenu!.items
        check(modeItems.map(\.title)==["悬浮条","菜单栏"] && modeItems.map(\.state)==[.on,.off],"both display modes appear as peers with exactly the current mode checked")
        let idleSinkItem = menu.items.first{$0.title == "闲置后下沉"}!
        check(idleSinkItem.state == .on,"idle sink menu item starts checked in floating mode")
        _=NSApp.sendAction(idleSinkItem.action!,to:idleSinkItem.target,from:idleSinkItem)
        check(!delegate.hudIdleSink && delegate.menu.makeStatusMenu().items.first{$0.title == "闲置后下沉"}?.state == .off,"the menu item toggles idle sink off")
        let reopenedIdleSink = delegate.menu.makeStatusMenu().items.first{$0.title == "闲置后下沉"}!
        _=NSApp.sendAction(reopenedIdleSink.action!,to:reopenedIdleSink.target,from:reopenedIdleSink)
        check(delegate.hudIdleSink,"the menu item toggles idle sink back on")
        let settingsItem = menu.items.first{$0.title == "设置…"}!
        check(settingsItem.action == #selector(StatusMenuController.showSettings) && settingsItem.submenu == nil,"settings opens a dedicated window instead of an anchor-dependent submenu")
        check(settingsItem.keyEquivalent == "," && settingsItem.keyEquivalentModifierMask.contains(.command),"the settings window has the standard Command-comma shortcut")
        let helpItem = menu.items.first{$0.title == "使用说明"}!
        check(menu.items.suffix(2).map(\.title) == ["使用说明","退出 " + Product.name],"help and quit stay the last two entries")
        check(helpItem.submenu?.identifier?.rawValue == StatusMenuController.helpMenuIdentifier,"the help entry is a native categorized submenu")
        let helpRows=helpItem.submenu!.items.filter{$0.action == #selector(StatusMenuController.showHelpCategory(_:))}
        check(helpRows.map(\.title)==HelpDocs.categories(for:provider).map(\.title) && helpRows.allSatisfy{$0.target === delegate.menu && $0.representedObject is String},"the help submenu lists every category as a native item")
        check(helpItem.submenu!.items.contains{$0.title=="在设置中查看…" && $0.action == #selector(StatusMenuController.showHelpSettings)},"the help submenu can also hand off to the settings window")
        // The application menu keeps a standard help command on the same page.
        delegate.menu.makeApplicationMenu()
        let appHelp=NSApp.mainMenu!.items.last!
        check(appHelp.title=="帮助" && appHelp.action == #selector(StatusMenuController.showHelpSettings) && appHelp.keyEquivalent=="?","the application menu opens the same native help page")
        check(!menu.items.contains{$0.action == #selector(AppCoordinator.enableNativeFollowing)},"automatic following stays in the session controls")
        check(delegate.menu.validateMenuItem(settingsItem),"settings is available before a host has been recognized")
        delegate.hudHidden=true
        check(delegate.menu.validateMenuItem(settingsItem),"hiding the HUD does not disable settings")
        delegate.hudHidden=false;delegate.hud.lastRect=nil
        check(delegate.hud.panel.level == .normal && !delegate.hud.panel.isFloatingPanel,"an unattached HUD starts at the ordinary level before a host is verified")
        check(delegate.hud.popover.window.level == .normal,"an unattached HUD inspector starts at the ordinary level")
        delegate.hud.panel.setHostOverlayActive(true)
        delegate.hud.hideHUD()
        check(delegate.hud.panel.level == .normal && !delegate.hud.panel.isVisible && delegate.hud.popover.window.level == .normal,"hiding the HUD releases host overlay elevation")
        delegate.hud.panel.setHostOverlayActive(true);delegate.hud.panel.orderFrontRegardless()
        delegate.hud.popover.present(kind:"speed",title:"Activation test",rows:[("Probe","1")],anchor:delegate.hud.metricScroll,host:NSRect(x:100,y:100,width:900,height:650),screen:NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1440,height:900),bar:delegate.hud.panel.frame)
        delegate.hud.interactionMenuOpen=true
        delegate.activeApplicationChanged("test.other")
        check(!delegate.hud.panel.isVisible && delegate.hud.panel.level == .normal && !delegate.hud.popover.isShown && delegate.hud.popover.window.level == .normal,"another application activation hides elevated HUD and inspector even during menu tracking")
        delegate.hud.interactionMenuOpen=false
        func metricButton(_ metric:HUDMetric)->NSButton { delegate.hud.moduleButtons[delegate.modules.first{$0.metric==metric}!.id]! }
        check(delegate.modules.map(\.metric) == [.speed,.usage,.timing,.subagents], "default modules expose a dedicated subagent entry")
        for (legacy,expected) in [(["latency","usage"],[HUDMetric.speed,.usage]),(["speed","latency","timing"],[.speed,.timing]),(["reasoningTokens","usage"],[.usage]),([] as [String],[] as [HUDMetric])] {
            defaults.removeObject(forKey:HUDModuleSettings.storageKey(for:provider.rawValue));defaults.set(legacy,forKey:"hudModules")
            check(delegate.modules.map(\.metric)==expected,"legacy settings migrate without duplicates, including no modules")
        }
        defaults.set([["id":"same","metric":"usage"],["id":"same","metric":"output"],["id":"future","metric":"not-a-metric"],["id":"removed","metric":"cacheWrite"],["id":"reasoning","metric":"reasoningTokens"]],forKey:HUDModuleSettings.storageKey(for:provider.rawValue))
        let repaired=delegate.modules
        check(repaired.count==2 && Set(repaired.map(\.id)).count==2,"saved layouts discard retired reasoning/cache-write and unknown metrics while repairing duplicate identities")
        check(repaired==delegate.modules,"repaired identities persist and stay stable")
        defaults.set([["id":"a","metric":"speed"],["id":"b","metric":"averageSpeed"],["id":"c","metric":"averageLatency"],["id":"d","metric":"recentSpeed"],["id":"e","metric":"waitTime"],["id":"f","metric":"modelUseTime"]],forKey:HUDModuleSettings.storageKey(for:provider.rawValue))
        let merged=delegate.modules
        check(merged.map(\.metric)==[.speed,.latency,.modelTime] && merged.map(\.id)==["a","c","f"],"retired duplicate metrics merge into their replacement without duplicating a slot")
        check(merged==delegate.modules,"merged module layout persists cleanly")
        let availableMetrics=HUDMetric.available(for:provider.rawValue)
        check(Set(availableMetrics.map(\.shortLabel)).count==availableMetrics.count,"every selectable metric has a unique short label")
        check(!availableMetrics.contains{["recentSpeed","averageSpeed","averageLatency","modelUseTime","waitTime"].contains($0.rawValue)},"retired duplicate metrics stay out of the available list")
        defaults.set(["timing.modelUse","speed.waitTotal","timing.total"],forKey:StatsPreferencesStore.detailRowKey+"."+provider.rawValue)
        check(delegate.detailRowKeys==["timing.model","timing.total"],"retired detail rows migrate or drop cleanly")
        defaults.removeObject(forKey:StatsPreferencesStore.detailRowKey+"."+provider.rawValue)
        delegate.modules=[HUDMetric.speed,.usage,.timing].map{HUDModule(metric:$0)};delegate.hud.applyModules()
        let firstID=delegate.modules[0].id
        delegate.editModules(.replace(firstID,.latency));delegate.editModules(.add(.output))
        let addedID=delegate.modules.last!.id
        delegate.editModules(.move(addedID,-1))
        check(delegate.modules.map(\.metric)==[.latency,.usage,.output,.timing],"replacing, adding and moving preserve the chosen order")
        delegate.editModules(.remove(firstID));delegate.editModules(.add(.output))
        check(delegate.modules.filter{$0.metric == .output}.count==2,"each position can independently select the same metric")
        let restored=AppCoordinator(preferences:UserDefaults(suiteName:suite)!,provider:provider)
        check(restored.modules==delegate.modules,"module identities, order and choices persist across delegates")
        delegate.editModules(.reset)
        check(delegate.modules.map(\.metric)==[.speed,.usage,.timing,.subagents],"restore defaults replaces the custom layout")
        check(delegate.hud.moduleButtons.count==4,"only configured modules have buttons")
        check(seconds(1000) == "1.00 秒", "native integer timing must format")
        check(count(1000) == "1.0k", "native integer count must format")
        check(exactCount(7) == "7", "native integer counts must format")
        check(exactCount(NSNull()) == "—", "unknown remains unknown")
        check(exactCount(true) == "—", "booleans are not numeric measurements")
        delegate.current = ["tpsSamples":7,"tpsTokens":210,"tpsDurationMs":3000,"tps":70,"ttftSamples":9,"avgTtftMs":1000,"lastTurn":["tps":42,"ttftMs":500],"input":10,"cacheWrite":20,"cacheRead":40,"output":50,"totalTokens":120,"reasoningTokens":7]
        let performance = Dictionary(uniqueKeysWithValues:delegate.metrics.content("speed").0)
        check(performance["最近一轮速度"] == "42.0 tok/s" && performance["平均速度"] == "70.0 tok/s", "merged inspector renders recent and average native integer rates")
        check(performance["最近一轮 TTFT"] == "0.50 秒" && performance["平均 TTFT"] == "1.00 秒", "merged inspector retains both native integer latency values")
        check(delegate.metrics.content("speed").1.isEmpty && performance["样本"] == nil, "merged inspector keeps the concise data-only presentation")
        let usage = Dictionary(uniqueKeysWithValues:delegate.metrics.content("usage").0)
        check(usage["输入"] == "30" && usage["总计"] == "120" && usage["缓存写入"] == nil, "cache creation is hidden while remaining included in input and total")
        check(usage["推理 Token"] == nil && usage["输出"] == "50", "reasoning tokens are hidden without changing native output or total counts")
        let timingPresenter=MetricPresenter(provider:provider,record:StatsRecord(["totalMs":4000,"toolMs":200,"modelMs":450,"decodeMs":300,"reasoningMs":400,"llmMs":600,"firstTokenWaitMs":700]))
        let timing=Dictionary(uniqueKeysWithValues:timingPresenter.content("timing").0)
        check(timing["累计用时"] != nil && timing["其中：推理片段"]==nil && timing["其中：文字输出"]==nil && timing["推理片段"]==nil,"the Codex-only reasoning and decode breakdown is gone from the timing card")
        check(timing["模型耗时"] != nil && timing["模型用时"]==nil && timing["模型请求"]==nil,"both tools share one model duration row")
        delegate.hud.updateBarTitles()
        check(metricButton(.speed).title == "速度 42.0 tok/s" && metricButton(.speed).toolTip?.contains("当前显示最近一轮速度")==true, "HUD prefers the latest turn over the average")
        delegate.current?["lastTurn"] = ["tps":0]
        delegate.hud.updateBarTitles()
        check(metricButton(.speed).title == "速度 0.0 tok/s", "a measured zero must not fall back to the average")
        for missing in [NSNull(),true,-1,Double.nan] as [Any] {
            delegate.current?["lastTurn"] = ["tps":missing]
            delegate.hud.updateBarTitles()
            check(metricButton(.speed).title == "速度 70.0 tok/s" && metricButton(.speed).toolTip?.contains("当前显示会话平均速度")==true, "missing or invalid recent speed uses a clearly described average")
        }
        delegate.current?["tps"] = NSNull()
        delegate.hud.updateBarTitles()
        check(metricButton(.speed).title == "速度 —" && metricButton(.speed).toolTip?.contains("暂无有效速度数据")==true, "unknown speed remains unknown")
        delegate.presentFixtureTitle("当前 · 第一行\n第二行\r\n第三行\t" + String(repeating:"很长的会话名称",count:80))
        delegate.hud.updateBarTitles()
        delegate.hud.panel.setFrame(NSRect(x:0,y:0,width:560,height:34),display:false)
        delegate.hud.panel.contentView!.layoutSubtreeIfNeeded()
        check(!delegate.hud.panel.contentView!.subviews.contains{$0 is NSButton},"HUD has no inline session or customization buttons")
        let sizeWithLongTitle=delegate.hud.preferredHUDSize()
        delegate.presentFixtureTitle("短标题");delegate.hud.updateBarTitles()
        check(delegate.hud.preferredHUDSize()==sizeWithLongTitle,"conversation names no longer consume HUD width")
        let longTitle = "第一行\n第二行\u{2028}第三行\u{2029}第四行" + String(repeating:"很长的中文会话标题🙂",count:100)
        delegate.selected = "session_test"
        delegate.kimiSelection = ["status":"connected","known":true,"sessionId":"session_test"]
        let popupHost = NSRect(x:0,y:0,width:900,height:650)
        let content = delegate.metrics.content("speed")
        delegate.hud.popover.present(kind:"speed",title:"速度与延迟",rows:content.0,note:content.1,anchor:metricButton(.speed),host:popupHost,screen:popupHost,bar:delegate.hud.panel.frame,display:false)
        delegate.receive(["sessions":[["id":"session_test","title":longTitle,"tps":123.4,"avgTtftMs":1234,"lastTurn":["tps":88,"ttftMs":600],"totalTokens":9999999,"totalMs":200000]]])
        let refreshed = Dictionary(uniqueKeysWithValues:delegate.hud.popover.rows)
        check(refreshed["最近一轮速度"] == "88.0 tok/s" && refreshed["最近一轮 TTFT"] == "0.60 秒", "the open merged inspector refreshes both metrics from new snapshots")
        delegate.hud.popover.close()
        check(delegate.hud.panel.contentView?.toolTip?.contains(SessionTitle.singleLine(longTitle))==true,"complete normalized title is available on hover")
        for moduleCount in [0,1,3,8,20,40] {
            delegate.modules = (0..<moduleCount).map{HUDModule(metric:HUDMetric.available(for:provider.rawValue)[$0 % HUDMetric.available(for:provider.rawValue).count])}
            delegate.hud.applyModules(); delegate.presentFixtureTitle(longTitle); delegate.hud.updateBarTitles()
            let host=NSRect(x:0,y:0,width:500,height:650)
            delegate.hud.panel.setFrame(delegate.hud.placement.frame(host:host,screen:host),display:false)
            delegate.hud.panel.contentView!.layoutSubtreeIfNeeded()
            check(!delegate.hud.panel.contentView!.subviews.contains{$0 is NSButton},"no configuration controls return after module changes")
            check(delegate.hud.panel.frame.maxY==host.maxY-8,"the bar always sits on the host's top edge")
            if moduleCount>0{check(delegate.hud.panel.contentView!.bounds.contains(delegate.hud.metricScroll.frame),"metric viewport stays inside the HUD")}
            for module in delegate.modules {
                let button=delegate.hud.moduleButtons[module.id]!
                check(delegate.hud.metricDocument.bounds.contains(button.frame),"every metric is reachable in the scroll document")
            }
            if moduleCount==40 {
                let scroll=delegate.hud.metricScroll
                let end=NSPoint(x:max(0,delegate.hud.metricDocument.frame.width-scroll.contentSize.width),y:0)
                scroll.contentView.scroll(to:end);scroll.reflectScrolledClipView(scroll.contentView)
                let lastButton=delegate.hud.moduleButtons[delegate.modules.last!.id]!
                check(scroll.documentVisibleRect.intersects(lastButton.frame),"the last module can be reached by scrolling")
            }
            if moduleCount==0{continue}
            check(metricButton(.speed).cell?.usesSingleLineMode==true,"horizontal metrics stay on one line")
            check(metricButton(.speed).title=="速度 88.0 tok/s","the bar prefers the latest turn")
        }
        // Real native Int values exercise Swift Any bridging without a JSON round trip.
        delegate.modules=HUDMetric.available(for:provider.rawValue).map{HUDModule(metric:$0)}
        delegate.current=["tps":70,"avgTtftMs":1000,"lastTurn":["tps":42,"ttftMs":500,"durationMs":2000],"input":10,"cacheWrite":20,"cacheRead":40,"output":50,"totalTokens":120,"cacheHit":50,"reasoningTokens":7,"totalMs":4000,"toolMs":200,"decodeMs":300,"reasoningMs":400,"modelMs":450,"llmMs":600,"firstTokenWaitMs":700,"contextTokens":134088,"turns":12,"completedTurns":10,"backgroundRunning":2,"backgroundTotal":5,"pendingApprovals":1,"pendingQuestions":2,"permissionMode":"auto","agents":[] as [JSONObject]]
        delegate.hud.applyModules()
        for module in delegate.modules { check(!delegate.hud.moduleButtons[module.id]!.title.contains("—"),"every available metric renders native integer data: \(module.metric)") }
        check(metricButton(.latency).title=="首延 0.5s" && metricButton(.input).title=="输入 30","independent latency and input modules render the selected metric")
        delegate.current=nil;delegate.hud.updateBarTitles()
        check(delegate.hud.moduleButtons.values.allSatisfy{$0.title.contains("—")},"unknown sessions clear every configured metric")
        delegate.modules=[];delegate.hud.applyModules()
        let emptyReload=AppCoordinator(preferences:defaults,provider:provider)
        check(emptyReload.modules.isEmpty,"zero modules remains an intentional saved configuration")
        delegate.editModules(.add(.latency))
        check(delegate.modules.count==1 && metricButton(.latency).title.contains("—"),"modules can be added after removing all data")
        // Exercise the actual editor controls: a click chooses a metric, a drag
        // reorders, and only the remove button deletes. The two gestures must never
        // share one trigger.
        delegate.modules=[HUDMetric.speed,.usage,.timing].map{HUDModule(metric:$0)};delegate.hud.applyModules()
        func makeEditor()->HUDModuleEditor {
            HUDModuleEditor(width:400,modules:delegate.modules,available:HUDMetric.available(for:provider.rawValue)){delegate.editModules($0)}
        }
        var editor=makeEditor()
        check(editor.rows.count==3 && editor.subviews.compactMap{$0 as? NSPopUpButton}.count==1,"the editor has one row per position and only the add control is a popup")
        let chooser=editor.metricPickerMenu(for:editor.rows[0].moduleID)
        check(!chooser.items.contains{$0.title==HUDMetric.speed.label && $0.state != .on} && chooser.items.contains{$0.state == .on && $0.title==HUDMetric.speed.label},"the chooser marks the current metric and omits nothing else")
        let chooserMetrics=chooser.items.compactMap{($0.representedObject as? HUDMetricMenuItem)?.metric}
        check(chooserMetrics == HUDMetric.available(for:provider.rawValue),"the chooser lists exactly this tool's metrics, in order")
        check(!chooserMetrics.map(\.rawValue).contains("reasoningTokens"),"the retired reasoning token metric stays out of the chooser")
        let replacement=chooser.items.first{($0.representedObject as? HUDMetricMenuItem)?.metric == .cacheHit}!
        app.sendAction(replacement.action!,to:replacement.target,from:replacement)
        check(delegate.modules.first?.metric == .cacheHit,"choosing from the menu changes only that position's metric")
        check(delegate.modules.count==3,"choosing a metric never reorders or adds a position")
        editor=makeEditor()
        // A short drag stays a click; a real drag only reorders.
        editor.dragRow(editor.rows[0].moduleID,translation:1)
        check(delegate.modules.map(\.metric)==[.cacheHit,.usage,.timing],"a press that barely moves never reorders")
        editor.dragRow(editor.rows[0].moduleID,translation:HUDModuleEditor.rowPitch*2)
        check(editor.rows.map(\.metric)==[.usage,.timing,.cacheHit] && delegate.modules.map(\.metric)==[.cacheHit,.usage,.timing],"dragging previews the new order without saving it")
        check(editor.rows.count==3,"the drag preview keeps every row addressable")
        editor.endRowDrag(editor.rows[2].moduleID)
        check(delegate.modules.map(\.metric)==[.usage,.timing,.cacheHit],"dropping commits exactly one move")
        editor=makeEditor()
        check(editor.rows.map(\.metric)==[.usage,.timing,.cacheHit],"the committed order is what the editor rebuilds from")
        check(HUDModuleReorder.targetIndex(from:0,translation:-1000,pitch:38,count:3)==0 && HUDModuleReorder.targetIndex(from:0,translation:1000,pitch:38,count:3)==2,"a drag is clamped to the existing positions")
        editor.rows.first!.subviews.compactMap{$0 as? NSButton}.first{$0.identifier?.rawValue.hasPrefix("remove-")==true}!.performClick(nil)
        check(delegate.modules.map(\.metric)==[.timing,.cacheHit],"the remove button deletes exactly the selected slot")
        let add=editor.subviews.compactMap{$0 as? NSPopUpButton}.first{$0.identifier?.rawValue=="add-module"}!
        add.selectItem(withTitle:HUDMetric.latency.label);app.sendAction(add.action!,to:add.target,from:add)
        check(delegate.modules.last?.metric == .latency,"editor adds the chosen metric")
        let editorHost=NSRect(x:0,y:0,width:520,height:300)
        delegate.hud.panel.setFrame(delegate.hud.placement.frame(host:editorHost,screen:editorHost),display:false)
        delegate.hud.popover.present(kind:"modules",title:"显示指标",anchor:delegate.hud.metricScroll,host:editorHost,screen:editorHost,bar:delegate.hud.panel.frame,display:false,customSize:CGSize(width:400,height:390),customBody:{width in HUDModuleEditor(width:width,modules:delegate.modules,available:HUDMetric.available(for:provider.rawValue)){delegate.editModules($0)}})
        check(editorHost.contains(delegate.hud.popover.window.frame),"module editor remains inside small windows")
        check(delegate.hud.popover.window.contentView!.layer?.masksToBounds == true,"the rounded detail card clips its material so no square corner wedges peek out")
        delegate.editModules(.add(.usage))
        check(delegate.hud.popover.kind=="modules","editing keeps the editor open")
        check(delegate.hud.popover.scroll.documentView is HUDModuleEditor,"editor survives viewport reflow")
        delegate.hud.popover.close()
        // Dragging moves the bar to a free position inside its host, and the offset
        // is saved as a fraction so host resizing keeps it in the same relative place.
        let dragHost=NSRect(x:120,y:100,width:900,height:650)
        delegate.hud.lastRect=dragHost
        let dragArea=HUDPlacement.container(host:dragHost,screen:delegate.hud.visibleScreen(for:dragHost))
        delegate.hud.panel.setFrame(delegate.hud.placement.frame(host:dragHost,screen:delegate.hud.visibleScreen(for:dragHost)),display:false)
        let startFrame=delegate.hud.panel.frame
        func barAnchor()->CGPoint {
            delegate.hud.panel.contentView!.layoutSubtreeIfNeeded()
            let rect=delegate.hud.panel.convertToScreen(delegate.hud.metricScroll.convert(delegate.hud.metricScroll.bounds,to:nil))
            return CGPoint(x:rect.midX,y:rect.midY)
        }
        let target=CGPoint(x:dragArea.minX+120,y:dragArea.minY+220)
        delegate.hud.beginHUDDrag(at:barAnchor())
        delegate.hud.moveHUDDrag(to:target)
        check(delegate.hud.isDragging && dragArea.contains(delegate.hud.panel.frame),"a drag moves the bar inside the visible host")
        check(delegate.hud.panel.frame != startFrame,"dragging actually moves the bar")
        check(delegate.hud.placement.relativePosition == nil,"an in-flight drag does not save a position yet")
        delegate.hud.endHUDDrag(commit:true)
        let saved=delegate.hud.placement.relativePosition
        check(saved != nil && delegate.hud.panel.frame==delegate.hud.placement.frame(host:dragHost,screen:delegate.hud.visibleScreen(for:dragHost)),"releasing saves a normalized position and keeps the bar where it was dropped")
        let restoredHUD=AppCoordinator(preferences:defaults,provider:provider).hud!
        check(restoredHUD.placement.relativePosition==saved,"the dragged position survives reloading preferences")
        let resized=NSRect(x:60,y:60,width:700,height:520)
        let resizedFrame=restoredHUD.placement.frame(host:resized,screen:delegate.hud.visibleScreen(for:resized))
        check(HUDPlacement.container(host:resized,screen:delegate.hud.visibleScreen(for:resized)).contains(resizedFrame),"a dragged position stays visible after the host resizes")
        delegate.hud.beginHUDDrag(at:barAnchor());delegate.hud.endHUDDrag(commit:false)
        check(delegate.hud.placement.relativePosition==saved && delegate.hud.panel.frame.maxY != dragArea.maxY,"cancelling keeps the dragged position instead of recentring the bar")
        // The bar keeps one shape: a horizontal strip, for compact hosts and for
        // hosts that are partly behind the screen edge.
        delegate.modules=HUDModuleSettings.defaults(provider:provider.rawValue);delegate.hud.applyModules()
        let barHost=NSRect(x:120,y:100,width:900,height:650)
        delegate.hud.lastRect=barHost
        let barScreen=delegate.hud.visibleScreen(for:barHost)
        for host in [barHost,NSRect(x:100,y:100,width:300,height:200)] {
            let frame=delegate.hud.placement.frame(host:host,screen:barScreen)
            delegate.hud.panel.setFrame(frame,display:false);delegate.hud.panel.contentView!.layoutSubtreeIfNeeded()
            check(host.contains(frame),"compact host windows contain the horizontal bar")
            check(delegate.hud.panel.contentView!.bounds.contains(delegate.hud.metricScroll.frame),"every layout reserves space for statistics")
        }
        let clippedHost=NSRect(x:-180,y:100,width:300,height:240),clippedScreen=NSRect(x:0,y:0,width:1440,height:900)
        delegate.hud.panel.setFrame(delegate.hud.placement.frame(host:clippedHost,screen:clippedScreen),display:false)
        delegate.hud.panel.contentView!.layoutSubtreeIfNeeded()
        check(delegate.hud.panel.contentView!.bounds.contains(delegate.hud.metricScroll.frame),"partially offscreen windows keep the statistics inside the visible strip")
        let narrowHost=NSRect(x:100,y:100,width:320,height:240)
        delegate.hud.panel.setFrame(delegate.hud.placement.frame(host:narrowHost,screen:barScreen),display:false)
        delegate.hud.panel.contentView!.layoutSubtreeIfNeeded()
        check(delegate.hud.metricScroll.frame.height==HUDWindowController.metricHeight && delegate.hud.metricScroll.contentSize.height==HUDWindowController.metricHeight,"a clamped bar keeps the full metric height so values are never cut")
        check(delegate.hud.metricDocument.frame.width>delegate.hud.metricScroll.contentSize.width,"a clamped bar becomes wheel-scrollable instead of showing a scroller")
        delegate.hud.panel.setFrame(delegate.hud.placement.frame(host:barHost,screen:barScreen),display:false)
        delegate.hud.panel.contentView!.layoutSubtreeIfNeeded()
        check(delegate.hud.metricDocument.frame.width==delegate.hud.metricScroll.contentSize.width,"a bar that fits has exactly the width its metrics need, so nothing scrolls or is clipped")
        check(delegate.hud.panel.contentView!.subviews.filter{!($0 is HUDBackdropView)}==[delegate.hud.metricScroll] && (delegate.hud.panel.contentView as? HUDContentView)?.backdrop.hitTest(.zero)==nil,"the bar contains only its metric strip and an inert backdrop; there is no separate grip")
        check(delegate.hud.panel.contentView!.layer?.masksToBounds == true,"the rounded bar clips its material so no square corner wedges peek out")
        // The bar is moved by dragging it directly: the grip, the values, the gaps and
        // the background all start the same gesture, while a plain click still opens
        // the detail card.
        check(delegate.hud.panel.contentView is HUDDragSurface && delegate.hud.metricScroll is HUDDragSurface,"both the bar background and the metric strip can start a drag")
        check(delegate.hud.metricScroll.toolTip?.contains("拖动")==true,"the bar explains that it is dragged directly")
        let metricButtons=delegate.modules.compactMap{delegate.hud.moduleButtons[$0.id]}
        check(!metricButtons.isEmpty && metricButtons.allSatisfy{$0 is HUDMetricButton && ($0 as? HUDMetricButton)?.drag.onMove != nil},"every metric value drags the bar while keeping its click action")
        check(metricButtons.allSatisfy{$0.action == #selector(HUDWindowController.showModule(_:))},"dragging from a value never steals its click action")
        delegate.hud.panel.contentView!.layoutSubtreeIfNeeded()
        check(metricButtons.allSatisfy{$0.frame.height==HUDWindowController.metricHeight && abs($0.frame.midY-delegate.hud.metricDocument.bounds.midY)<0.5},"every metric value keeps the fixed slim height and sits centred")
        check(HUDDragGesture.threshold>0 && HUDDragGesture.threshold<6,"a small press still counts as a click")
        // Clicking the bar activates this app before its panel is key; that transient
        // state must not hide the bar or clear the drag anchor.
        check(HUDVerificationGrace.holdsVisibleBar(
            hostContextActive:true,barVisible:true,verifiedNumber:7,verifiedAt:Date(),now:Date(),windowStillOnScreen:true),
            "activating the bar's own app keeps the visible bar in place")
        check(!delegate.hud.metricScroll.hasHorizontalScroller && !delegate.hud.metricScroll.hasVerticalScroller,"no scroller can ever cover the metric values")
        check(delegate.hud.metricScroll.frame.maxX<=delegate.hud.panel.contentView!.bounds.maxX,"the metric viewport stays inside the bar")
        delegate.hud.verifiedHostNumber=7
        delegate.hud.retainedHost=HostWindowReference(pid:1,number:7,bounds:barHost)
        delegate.hud.lastRect=barHost
        delegate.hud.panel.orderFrontRegardless()
        let shiftedHost=NSRect(x:180,y:140,width:900,height:650)
        delegate.hud.hostFrameSource={ _,_ in shiftedHost }
        delegate.hud.pointerHeld={ true }
        delegate.hud.startHostMotionTracking()
        delegate.hud.trackHostMotion()
        check(delegate.hud.panel.frame==delegate.hud.placement.frame(host:shiftedHost,screen:delegate.hud.visibleScreen(for:shiftedHost)),"host motion tracking keeps the floating bar at the same relative position")
        check(delegate.hud.lastRect==shiftedHost && delegate.hud.hostMotionAt != nil,"host motion tracking updates the cached host rect and extends motion grace while the pointer is held")
        delegate.hud.hostFrameSource={ _,_ in nil }
        delegate.hud.trackHostMotion()
        check(delegate.hud.motionTimer==nil,"host motion tracking stops when the tracked window disappears")
        delegate.hud.hostFrameSource=nil
        delegate.hud.pointerHeld={ NSEvent.pressedMouseButtons & 1 != 0 }
        delegate.hud.hideHUD()
        delegate.hud.lastRect=barHost
        delegate.hud.panel.setFrame(delegate.hud.placement.frame(host:barHost,screen:barScreen),display:false)
        delegate.hud.panel.orderFrontRegardless()
        let contentView=delegate.hud.panel.contentView as! HUDContentView
        delegate.hud.setSunk(true,animated:false)
        check(contentView.backdrop.alphaValue==0 && abs(delegate.hud.metricScroll.alphaValue-HUDIdleSink.sunkContentAlpha)<0.05,"idle sink hides the glass backdrop while keeping dimmed values readable")
        delegate.hud.setSunk(false,animated:false)
        check(contentView.backdrop.alphaValue==1 && delegate.hud.metricScroll.alphaValue==1,"restoring from idle sink returns full backdrop and metric opacity")
        delegate.hud.pointerLocation={ NSPoint(x:-10000,y:-10000) }
        delegate.hud.lastHUDActivity=Date().addingTimeInterval(-20)
        delegate.hud.updateIdleSink()
        check(delegate.hud.isSunk && !delegate.hud.panel.hasShadow,"idle sink drops the bar shadow and enters the sunk state")
        delegate.hud.pointerLocation={ NSPoint(x:delegate.hud.panel.frame.midX,y:delegate.hud.panel.frame.midY) }
        delegate.hud.updateIdleSink()
        check(!delegate.hud.isSunk && delegate.hud.panel.hasShadow,"hovering near the bar restores the full floating strip")
        delegate.setHUDIdleSink(false)
        delegate.hud.pointerLocation={ NSPoint(x:-10000,y:-10000) }
        delegate.hud.lastHUDActivity=Date().addingTimeInterval(-20)
        delegate.hud.updateIdleSink()
        check(!delegate.hud.isSunk,"disabling idle sink prevents the bar from sinking")
        delegate.setHUDIdleSink(true)
        delegate.hud.lastHUDActivity=Date().addingTimeInterval(-20)
        delegate.hud.updateIdleSink()
        check(delegate.hud.isSunk,"re-enabling idle sink allows sinking after the quiet period")
        delegate.hud.hideHUD()
        check(!delegate.hud.isSunk,"hiding the bar resets any sunk appearance before the next display")
        delegate.hud.pointerLocation={ NSEvent.mouseLocation }
        delegate.hud.lastRect=nil
        let window = HostWindowReference(pid:1,number:10,bounds:CGRect(x:0,y:0,width:900,height:650))
        delegate.selected = "__current__"; delegate.observeWindow(window)
        delegate.sessions = [["id":"recent","title":"后台最新会话","totalTokens":999], ["id":"old","title":"当前旧会话","totalTokens":12]]
        let follows = provider.supportsAutomaticSessionFollow
        let second = HostWindowReference(pid:1,number:11,bounds:CGRect(x:100,y:100,width:900,height:650))
        if follows {
            delegate.receive(["nativeSelection":CurrentSession(.current,id:"old",window:window.token).json])
            check(delegate.current?["id"] as? String == "old", "native following selects the displayed old session")
            delegate.receive(["nativeSelection":CurrentSession(.draft,window:window.token).json])
            check(delegate.current == nil, "blank drafts do not show recent session statistics")
            delegate.kimiSelection = ["status":"connected","known":true,"sessionId":"recent"]
            delegate.receive(["nativeSelection":CurrentSession(.permissionRequired,window:window.token).json])
            check(delegate.current == nil, "permission loss cannot fall back to recent activity or another source")
            delegate.receive(["nativeSelection":CurrentSession(.current,id:"old",window:window.token).json])
            delegate.observeWindow(second)
            check(delegate.current == nil, "switching windows immediately clears previous data")
            delegate.receive(["nativeSelection":CurrentSession(.current,id:"old",window:window.token).json])
            check(delegate.current == nil, "late callbacks from another window are rejected")
            delegate.receive(["nativeSelection":CurrentSession(.current,id:"recent",window:second.token).json])
            check(delegate.current?["id"] as? String == "recent", "the matching window can supply a new selection")
        } else {
            // A host without a live route never adopts the native signal: the stored
            // automatic preference is read as recent activity instead of waiting for
            // an identification that never arrives.
            delegate.observeWindow(second)
            delegate.receive(["nativeSelection":CurrentSession(.current,id:"old",window:second.token).json])
            check(delegate.selectionMode == .recent && delegate.current?["id"] as? String == "recent",
                  "a host without automatic following reads the stored preference as recent")
        }
        delegate.selected="old";delegate.render()
        check(delegate.current?["id"] as? String == "old", "manual selection remains usable")
        delegate.selected="__recent__";delegate.render()
        check(delegate.current?["id"] as? String == "recent", "explicit recent activity remains usable")
        let autoChoices=delegate.sessionModes().filter{["__current__","__bridge__"].contains($0.id)}
        check(autoChoices.count == (follows ? 1:0) && (follows ? autoChoices[0].title == "自动跟随当前对话":true), "technical source choices collapse into a single automatic mode, if the host has one")
        if !follows {
            delegate.selected="__current__"
            delegate.receive(["nativeSelection":CurrentSession(.routeUnavailable,window:second.token).json])
            check(delegate.selectionMode == .recent && delegate.current?["id"] as? String == "recent",
                  "an unavailable live route never blocks the recent fallback")
            check(!delegate.sessionModes().contains{$0.id=="__current__"}, "a host without a live route offers no automatic mode at all")
        }
        // Native status items exercise the real AppKit anchor without accessing a host window.
        delegate.menu.makeStatus()
        defer { delegate.hud.popover.close();NSStatusBar.system.removeStatusItem(delegate.menu.status) }
        check(delegate.menu.status.button?.window != nil,"the native menu bar item supplies its own inspector anchor")
        delegate.modules=[.init(metric:.speed),.init(metric:.usage),.init(metric:.timing)];delegate.hud.applyModules()
        delegate.selected="old";delegate.render()
        let savedModules=delegate.modules,savedSelection=delegate.selected
        // Suppress automatic host inspection while switching the presentation in this test.
        delegate.hud.interactionMenuOpen=true
        delegate.hud.panel.setHostOverlayActive(true)
        delegate.setDisplayMode(.menuBar)
        check(delegate.displayMode == .menuBar && !delegate.hud.panel.isVisible,"switching to menu bar presentation hides the floating panel")
        check(delegate.hud.panel.level == .normal && delegate.hud.popover.window.level == .normal,"switching to menu bar mode clears host overlay elevation before any follow pass")
        check(delegate.modules==savedModules && delegate.selected==savedSelection,"switching presentation preserves module identities and session selection")
        let statusModes=delegate.menu.status.menu!.items.first{$0.title=="展示模式"}!.submenu!.items
        check(statusModes.map(\.state)==[.off,.on] && modeItems.allSatisfy{delegate.menu.validateMenuItem($0)} && modeItems.map(\.state)==[.off,.on],"rebuilt and already-created mode menus validate the current selection")
        check(!delegate.menu.status.menu!.items.contains{$0.action == #selector(StatusMenuController.toggle)},"menu bar presentation has no misleading floating visibility toggle")
        delegate.hud.lastRect=nil;delegate.hud.retainedHost=nil;delegate.hudHidden=true
        let statusSettings=delegate.menu.status.menu!.items.first{$0.title=="设置…"}!
        check(delegate.menu.validateMenuItem(statusSettings),"menu bar settings remain available without a recognized or visible host")
        delegate.current=["tps":70,"lastTurn":["tps":42],"totalTokens":120,"totalMs":4000];delegate.presentFixtureTitle("菜单栏原生数值");delegate.hud.updateBarTitles()
        let prefix=""
        check(delegate.menu.menuBarTitle(maxWidth:1000)==prefix+"  速度 42.0 tok/s  Token 120  用时 4.0s","menu bar title renders native Int measurements in the configured order")
        check(delegate.menu.status.button!.title.contains("42.0 tok/s") && delegate.menu.status.button!.toolTip?.contains("菜单栏模式")==true,"live status button uses metric text and a menu bar tooltip")
        delegate.current?["lastTurn"]=["tps":0];delegate.current?["totalTokens"]=0;delegate.current?["totalMs"]=0;delegate.hud.updateBarTitles()
        check(delegate.menu.menuBarTitle(maxWidth:1000)==prefix+"  速度 0.0 tok/s  Token 0  用时 0.0s","measured native zero remains zero in the menu bar")
        delegate.current=nil;delegate.hud.updateBarTitles()
        check(delegate.menu.menuBarTitle(maxWidth:1000)==prefix+"  速度 —  Token —  用时 —","unknown menu bar measurements remain unknown")
        delegate.modules=(0..<40).map{_ in HUDModule(metric:.usage)};delegate.current=["totalTokens":123456789];delegate.hud.applyModules()
        let compactTitle=delegate.menu.menuBarTitle(maxWidth:180)
        check(compactTitle.hasSuffix("…") && (compactTitle as NSString).size(withAttributes:[.font:NSFont.monospacedDigitSystemFont(ofSize:11,weight:.medium)]).width<=180,"many modules remain within the menu bar width limit with visible overflow")
        check(delegate.menu.metricMenuItems.count==40 && delegate.menu.metricMenuItems.values.allSatisfy{$0.title=="Token 123.46M"},"every configured module remains available in the native menu when the title overflows")
        delegate.modules=[];delegate.hud.applyModules()
        check(delegate.menu.menuBarTitle()==prefix && delegate.menu.status.menu!.items.contains{$0.title=="指标设置"},"zero modules leaves an icon-only status item and a native entry to add metrics")
        delegate.modules=savedModules;delegate.hud.applyModules();delegate.selected=savedSelection;delegate.render()
        delegate.hud.interactionMenuOpen=false
        delegate.menu.showStatusMetric(delegate.menu.metricMenuItems[delegate.modules.first!.id]!)
        check(delegate.hud.popover.isShown && delegate.hud.popover.kind=="speed","native menu metric actions open a full inspector without a host rectangle")
        check(delegate.hud.popover.anchor===delegate.menu.status.button && delegate.hud.popover.owner==nil && delegate.hud.popover.window.parent==nil,"menu bar inspectors are independent of the elevated native status-item window")
        check(delegate.hud.popover.window.level == .normal && !delegate.hud.popover.window.isFloatingPanel,"menu bar inspectors retain ordinary window ordering")
        delegate.hud.follow()
        check(delegate.hud.popover.isShown && delegate.hud.lastRect==nil && !delegate.hud.panel.isVisible,"following with a manual menu bar selection preserves its inspector without a host")
        check(delegate.hud.panel.level == .normal && delegate.hud.popover.window.level == .normal,"menu bar following keeps both hidden HUD and independent inspector at ordinary levels")
        delegate.editModules(.add(.output))
        check(delegate.hud.popover.isShown && delegate.hud.popover.kind=="speed" && delegate.menu.status.menu!.items.contains{$0.title=="指标设置"},"metric editing keeps the open inspector while rebuilding the native menu")
        delegate.resignActive()
        check(!delegate.hud.popover.isShown,"leaving the stats application dismisses its menu bar inspector")
        delegate.menu.showStatusMetric(delegate.menu.metricMenuItems[delegate.modules.first!.id]!)
        check(delegate.hud.popover.isShown && delegate.hud.popover.kind=="speed","native menu metric actions reopen their full inspector")
        delegate.hud.interactionMenuOpen=true;delegate.setDisplayMode(.floating)
        check(!delegate.hud.popover.isShown && !delegate.hudHidden && delegate.displayMode == .floating,"returning to floating closes the status inspector and requests a visible HUD")
        check(delegate.hud.panel.level == .normal && delegate.hud.popover.window.level == .normal,"returning to floating mode does not elevate windows before a host is verified")
        check(delegate.hud.preferredHUDSize().height==28 && delegate.selected==savedSelection,"returning to floating restores the single horizontal bar and the selection")
        check(delegate.menu.status.button?.title==prefix && delegate.menu.visibilityMenuItem?.title=="隐藏悬浮条","floating presentation restores its compact status item and visibility menu")
        delegate.setDisplayMode(.menuBar);delegate.hud.interactionMenuOpen=false
        delegate.selected="__current__";delegate.observeWindow(window)
        if follows {
            delegate.receive(["nativeSelection":CurrentSession(.current,id:"old",window:window.token).json])
            check(delegate.current?["id"] as? String == "old" && delegate.menu.status.button?.toolTip?.contains("当前旧会话")==true,"menu bar automatic selection shows the matching window's old session")
            delegate.kimiSelection=["status":"connected","known":true,"sessionId":"recent"]
            delegate.receive(["nativeSelection":CurrentSession(.permissionRequired,window:window.token).json])
            check(delegate.current==nil && delegate.menu.menuBarTitle().contains("—"),"menu bar permission loss clears values instead of falling back to another source")
            delegate.observeWindow(second)
            delegate.receive(["nativeSelection":CurrentSession(.current,id:"old",window:window.token).json])
            check(delegate.current==nil,"menu bar ignores late session results from the previously observed window")
            delegate.receive(["nativeSelection":CurrentSession(.draft,window:second.token).json])
            check(delegate.current==nil && delegate.scopeText=="新对话 · 暂无统计","menu bar blank drafts never display recent-session values")
        } else {
            // Without automatic following the menu bar shows recent activity and
            // states which conversation that is.
            delegate.receive(["nativeSelection":CurrentSession(.current,id:"old",window:window.token).json])
            check(delegate.selectionMode == .recent && delegate.current?["id"] as? String == "recent","menu bar falls back to recent activity without automatic following")
            check(delegate.menu.status.button?.toolTip?.contains("后台最新会话")==true,"the menu bar names the conversation it is showing")
            let followMenu=delegate.menu.makeStatusMenu()
            check(followMenu.items.first{$0.title=="选择对话"}!.state == .on,"the menu bar marks the conversation item while it follows recent activity")
        }
        delegate.hud.interactionMenuOpen=true;delegate.setDisplayMode(.floating);delegate.hud.interactionMenuOpen=false
        // The dedicated settings window must work without a host or an Accessibility grant.
        do {
            let settingsSuite="stats-settings-tests-"+UUID().uuidString
            let settingsDefaults=UserDefaults(suiteName:settingsSuite)!
            defer{settingsDefaults.removePersistentDomain(forName:settingsSuite)}
            let settingsDelegate=AppCoordinator(preferences:settingsDefaults,provider:provider)
            settingsDelegate.followsActiveTool=false;settingsDelegate.hud.makePanel();settingsDelegate.menu.makeStatus();settingsDelegate.hud.interactionMenuOpen=true
            defer{settingsDelegate.settingsWindow?.close();NSStatusBar.system.removeStatusItem(settingsDelegate.menu.status)}
            settingsDelegate.selected="settings_first"
            settingsDelegate.sessions=[
                ["id":"settings_first","title":"第一条会话","totalTokens":12],
                ["id":"settings_target","title":"目标会话\n"+String(repeating:"很长的标题🙂",count:30),"totalTokens":42],
                ["id":"settings_archived","title":"目标会话归档","archived":true,"totalTokens":99]
            ]
            settingsDelegate.render()
            settingsDelegate.showSettings()
            let controller=settingsDelegate.settingsWindow!,settingsWindow=controller.window!
            check(settingsWindow.isVisible && settingsDelegate.hud.lastRect==nil,"settings opens without a recognized host")
            check(settingsWindow.level == .normal && settingsWindow.parent == nil && settingsWindow !== settingsDelegate.hud.popover.window,"settings uses its own ordinary independent window")
            check(settingsWindow.styleMask.contains(.titled) && settingsWindow.styleMask.contains(.closable),"settings provides standard native window controls")
            check([NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton].allSatisfy{settingsWindow.standardWindowButton($0)?.isHidden == false},"settings keeps standard macOS traffic lights visible")
            check(settingsWindow.toolbar != nil && settingsWindow.toolbarStyle == .unified,"settings uses unified toolbar geometry")
            check(max(settingsWindow.minSize.width,settingsWindow.contentMinSize.width)>=580 && max(settingsWindow.minSize.height,settingsWindow.contentMinSize.height)>=640,"settings enforces its usable minimum window size")
            settingsDelegate.showSettings()
            check(settingsDelegate.settingsWindow===controller,"repeated settings actions reuse one controller and window")
            func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap{descendants($0)}}
            func settingControl<T:NSView>(_ identifier:String,_ type:T.Type)->T {
                guard let result=descendants(settingsWindow.contentView!).first(where:{$0.identifier?.rawValue==identifier}) as? T else{preconditionFailure("missing settings control: "+identifier)}
                return result
            }
            func dispatch(_ control:NSControl){
                guard let action=control.action else{preconditionFailure("settings control has no action")}
                check(app.sendAction(action,to:control.target,from:control),"the native settings control dispatches its action")
            }
            for page in StatsSettingsPage.allCases {
                controller.selectPage(page);controller.refresh();settingsWindow.contentView!.layoutSubtreeIfNeeded()
                check(settingsWindow.isVisible && settingsWindow.contentView!.subviews.count>0,"every settings page is available independently of the host")
            }
            check(StatsSettingsPage.allCases.allSatisfy{ page in
                (descendants(settingsWindow.contentView!).first{$0.identifier?.rawValue=="settings-nav-\(page.rawValue)"} as? NSButton)?.focusRingType == NSFocusRingType.none
            },"page tabs never draw a keyboard focus ring on top of the selected tab")
            if let frameView=settingsWindow.contentView?.superview {
                for page in StatsSettingsPage.allCases {
                    let nav=settingControl("settings-nav-\(page.rawValue)",NSButton.self)
                    let center=nav.convert(NSPoint(x:nav.bounds.midX,y:nav.bounds.midY),to:frameView)
                    let hit=frameView.hitTest(center)
                    check(hit != nil && (hit===nav || hit!.isDescendant(of:nav)),"sidebar navigation hit-tests cleanly without titlebar obstruction")
                }
                let providerHit=settingControl("settings-provider",NSPopUpButton.self)
                let providerCenter=providerHit.convert(NSPoint(x:providerHit.bounds.midX,y:providerHit.bounds.midY),to:frameView)
                let hitProvider=frameView.hitTest(providerCenter)
                check(hitProvider != nil && (hitProvider===providerHit || hitProvider!.isDescendant(of:providerHit)),"header tool picker remains clickable inside the unified titlebar band")
                controller.selectPage(.help);controller.refresh();settingsWindow.contentView!.layoutSubtreeIfNeeded()
                let helpPickerHit=settingControl("settings-help-category",NSPopUpButton.self)
                let helpCenter=helpPickerHit.convert(NSPoint(x:helpPickerHit.bounds.midX,y:helpPickerHit.bounds.midY),to:frameView)
                let hitHelp=frameView.hitTest(helpCenter)
                check(hitHelp != nil && (hitHelp===helpPickerHit || hitHelp!.isDescendant(of:helpPickerHit)),"help category picker remains clickable in the header")
            }
            controller.selectPage(.general)
            let followToolControl=settingControl("settings-follow-tool",NSSwitch.self)
            check(followToolControl.state == .off,"the follow-tool switch reflects the manual tool state")
            followToolControl.state = .on;dispatch(followToolControl)
            check(settingsDelegate.followsActiveTool && AppCoordinator(preferences:settingsDefaults,provider:provider).followsActiveTool,"turning on follow-tool persists automatic foreground switching")
            controller.refresh()
            let followToolOff=settingControl("settings-follow-tool",NSSwitch.self)
            check(followToolOff.state == .on,"refresh keeps the follow-tool switch synchronized")
            followToolOff.state = .off;dispatch(followToolOff)
            check(!settingsDelegate.followsActiveTool && !AppCoordinator(preferences:settingsDefaults,provider:provider).followsActiveTool,"turning off follow-tool persists manual tool selection")
            if settingsDelegate.provider != provider { settingsDelegate.selectProvider(provider) }
            controller.refresh()
            let modeControl=settingControl("settings-display-mode",NSSegmentedControl.self)
            check(modeControl.selectedSegment==0,"the display control reflects the existing floating default")
            modeControl.selectedSegment=1;dispatch(modeControl)
            check(settingsDelegate.displayMode == .menuBar && AppCoordinator(preferences:settingsDefaults,provider:provider).displayMode == .menuBar,"changing the settings display control persists menu bar mode")
            controller.refresh()
            let floatingControl=settingControl("settings-display-mode",NSSegmentedControl.self)
            floatingControl.selectedSegment=0;dispatch(floatingControl)
            check(settingsDelegate.displayMode == .floating && !settingsDelegate.hudHidden,"switching back through settings restores floating mode")
            controller.refresh()
            let visibilityControl=settingControl("settings-visibility",NSSwitch.self)
            visibilityControl.state = .off;dispatch(visibilityControl)
            check(settingsDelegate.hudHidden && settingsWindow.isVisible,"the visibility switch hides the HUD without hiding settings")
            check(AppCoordinator(preferences:settingsDefaults,provider:provider).hudHidden,"the hidden HUD preference survives a new app delegate")
            controller.refresh()
            let showControl=settingControl("settings-visibility",NSSwitch.self)
            showControl.state = .on;dispatch(showControl)
            check(!settingsDelegate.hudHidden,"the visibility switch can restore the HUD without a host")
            check(!AppCoordinator(preferences:settingsDefaults,provider:provider).hudHidden,"restoring HUD visibility persists across app delegates")
            controller.refresh()
            let idleSinkControl=settingControl("settings-idle-sink",NSSwitch.self)
            check(idleSinkControl.state == .on,"idle sink defaults to enabled in settings")
            idleSinkControl.state = .off;dispatch(idleSinkControl)
            check(!settingsDelegate.hudIdleSink && !AppCoordinator(preferences:settingsDefaults,provider:provider).hudIdleSink,"turning off idle sink persists across app delegates")
            controller.refresh()
            let restoredIdleSink=settingControl("settings-idle-sink",NSSwitch.self)
            restoredIdleSink.state = .on;dispatch(restoredIdleSink)
            check(settingsDelegate.hudIdleSink && AppCoordinator(preferences:settingsDefaults,provider:provider).hudIdleSink,"re-enabling idle sink persists across app delegates")
            controller.refresh()
            let hideStatusControl=settingControl("settings-hide-status-item",NSSwitch.self)
            check(hideStatusControl.state == .off && hideStatusControl.isEnabled,"status item visibility switch starts off and enabled in floating mode")
            hideStatusControl.state = .on;dispatch(hideStatusControl)
            check(settingsDelegate.statusItemHidden && AppCoordinator(preferences:settingsDefaults,provider:provider).statusItemHidden,"hiding the status item persists across app delegates")
            controller.refresh()
            let restoredStatusControl=settingControl("settings-hide-status-item",NSSwitch.self)
            restoredStatusControl.state = .off;dispatch(restoredStatusControl)
            check(!settingsDelegate.statusItemHidden && !AppCoordinator(preferences:settingsDefaults,provider:provider).statusItemHidden,"restoring status item visibility persists across app delegates")
            controller.refresh()
            controller.selectPage(.metrics)
            let detailControl=settingControl("detail-row-usage.cacheRead",NSButton.self)
            check(detailControl.state == .on,"every expanded-detail row starts enabled for the active tool")
            detailControl.state = .off;dispatch(detailControl)
            check(!settingsDelegate.detailRowKeys.contains("usage.cacheRead") && !AppCoordinator(preferences:settingsDefaults,provider:provider).detailRowKeys.contains("usage.cacheRead"),"unchecking a detail row persists without a host")
            check(!settingsDelegate.metrics.content("usage").0.map(\.0).contains("缓存读取"),"a disabled detail row is omitted from the expanded card")
            let restoredRow=settingControl("detail-row-usage.cacheRead",NSButton.self)
            restoredRow.state = .on;dispatch(restoredRow)
            check(settingsDelegate.detailRowKeys.contains("usage.cacheRead") && settingsDelegate.metrics.content("usage").0.map(\.0).contains("缓存读取"),"re-enabling the row restores it immediately")
            controller.selectPage(.metrics)
            let settingsFirstID=settingsDelegate.modules.first!.id
            // A click on a row only opens the chooser; the metric changes when one is
            // picked. Neither gesture is allowed to reorder or add a position.
            let settingsRow=settingControl("metric-row-"+settingsFirstID,HUDModuleRow.self)
            check(settingsRow.onChoose != nil && settingsRow.onDrag != nil && settingsRow.onRemove != nil,"each settings row wires choose, drag and remove separately")
            let settingsEditor=settingsRow.superview as! HUDModuleEditor
            let settingsChooser=settingsEditor.metricPickerMenu(for:settingsFirstID)
            let settingsPick=settingsChooser.items.first{($0.representedObject as? HUDMetricMenuItem)?.metric == .cacheHit}!
            let settingsBefore=settingsDelegate.modules
            let settingsDispatched=app.sendAction(settingsPick.action!,to:settingsPick.target,from:settingsPick)
            check(settingsDispatched && settingsDelegate.modules.count==settingsBefore.count && settingsDelegate.modules.dropFirst().map(\.id)==settingsBefore.dropFirst().map(\.id),"choosing a metric changes only that position and keeps every other identity")
            check(settingsDelegate.modules.first?.metric == .cacheHit,"the settings metric editor changes the same saved layout as the HUD")
            controller.refresh()
            let settingsAdd=settingControl("add-module",NSPopUpButton.self)
            settingsAdd.selectItem(withTitle:HUDMetric.output.label);dispatch(settingsAdd)
            check(settingsDelegate.modules.last?.metric == .output && AppCoordinator(preferences:settingsDefaults,provider:provider).modules==settingsDelegate.modules,"metrics added from settings persist with identities and order")
            check(!HUDMetric.allCases.map(\.rawValue).contains("tokenStats"),"token stats never adds a floating HUD metric")
            check(!delegate.menu.makeStatusMenu().items.contains{$0.title.contains("Token 统计")},"token stats never adds a menu bar entry")
            check(StatsSettingsPage.allCases.contains(.tokenStats) && StatsSettingsPage.tokenStats.title=="Token 统计","settings exposes a dedicated Token 统计 page")
            controller.selectPage(.tokenStats)
            let nowMs = settingsDelegate.runtime.clock.milliseconds
            settingsDelegate.setTokenCorporaForTesting([
                .codex: ProviderTokenCorpus(
                    provider: .codex, collectedAt: nowMs,
                    entries: [
                        TokenUsageEntry(
                            provider: .codex, timestampMs: nowMs - 1000, model: "gpt-6-astra",
                            projectKey: "cwd:/work/test", projectTitle: "test", projectSubtitle: "/work/test",
                            sessionKey: "c1", sessionTitle: "Codex 测试会话", archived: false,
                            source: .requests, input: 120, cacheRead: 380, cacheWrite: 0, output: 100,
                            totalTokens: 600, requestCount: 2)
                    ],
                    totalSessions: 1),
                .kimi: ProviderTokenCorpus(
                    provider: .kimi, collectedAt: nowMs,
                    entries: [
                        TokenUsageEntry(
                            provider: .kimi, timestampMs: nowMs - 2000, model: "kimi-code/k3",
                            projectKey: "cwd:/work/test", projectTitle: "test", projectSubtitle: "/work/test",
                            sessionKey: "k1", sessionTitle: "Kimi 测试会话", archived: true,
                            source: .requests, input: 80, cacheRead: 220, cacheWrite: 20, output: 80,
                            totalTokens: 400, requestCount: 1)
                    ],
                    totalSessions: 1, archivedSessions: 1),
            ])
            controller.refresh()
            settingsWindow.contentView!.layoutSubtreeIfNeeded()
            let tokenScope = settingControl("settings-token-scope",NSSegmentedControl.self)
            check(tokenScope.selectedSegment == 0 && settingsDelegate.tokenStatsReport().totalTokens == 1000,"token stats combines all providers by default")
            tokenScope.selectedSegment = 2; dispatch(tokenScope)
            check(settingsDelegate.tokenStatsScope == .kimi && settingsDelegate.tokenStatsReport().totalTokens == 400 && AppCoordinator(preferences:settingsDefaults,provider:provider).tokenStatsScope == .kimi,"switching token stats tool scope filters and persists across restarts")
            tokenScope.selectedSegment = 0; dispatch(tokenScope)
            let tokenRange = settingControl("settings-token-range",NSSegmentedControl.self)
            tokenRange.selectedSegment = 0; dispatch(tokenRange)
            check(settingsDelegate.tokenStatsRange == .today && settingsDelegate.tokenStatsReport().buckets.count == 24 && AppCoordinator(preferences:settingsDefaults,provider:provider).tokenStatsRange == .today,"switching token stats time range updates trend buckets and persists")
            let tokenDim = settingControl("settings-token-dimension",NSSegmentedControl.self)
            tokenDim.selectedSegment = 1; dispatch(tokenDim)
            check(settingsDelegate.tokenStatsDimension == .projects && AppCoordinator(preferences:settingsDefaults,provider:provider).tokenStatsDimension == .projects,"switching token stats breakdown dimension persists")
            let tokenChart = descendants(settingsWindow.contentView!).first{$0.identifier?.rawValue=="settings-token-chart"} as? TokenTrendChartView
            let tokenSummary = descendants(settingsWindow.contentView!).first{$0.identifier?.rawValue=="settings-token-chart-summary"} as? NSTextField
            check(tokenChart != nil && tokenSummary != nil,"token trend chart and summary label are rendered")
            if let tokenChart, let activeIdx = tokenChart.buckets.firstIndex(where: { $0.totalTokens > 0 }) {
                tokenChart.inspectBucket(at: activeIdx)
                check(tokenSummary?.stringValue.contains("总计") == true,"hovering a bar updates the chart summary readout")
                tokenChart.inspectBucket(at: nil)
            }
            let tokenRefresh = settingControl("settings-token-refresh",NSButton.self)
            dispatch(tokenRefresh)
            controller.selectPage(.general)
            let generalUpdateBtn = settingControl("settings-general-check-updates",NSButton.self)
            check(generalUpdateBtn.title == "检查更新…","general page exposes software update shortcut")
            controller.selectPage(.about)
            let autoCheckSwitch = settingControl("settings-auto-check-updates",NSSwitch.self)
            let autoDownloadSwitch = settingControl("settings-auto-download-updates",NSSwitch.self)
            check(autoCheckSwitch.state == .on && autoDownloadSwitch.state == .on && autoDownloadSwitch.isEnabled,"update switches default to enabled")
            autoCheckSwitch.state = .off; dispatch(autoCheckSwitch)
            let refreshedDownloadOff = settingControl("settings-auto-download-updates",NSSwitch.self)
            check(!settingsDelegate.autoCheckUpdates && !refreshedDownloadOff.isEnabled && !AppCoordinator(preferences:settingsDefaults,provider:provider).autoCheckUpdates,"disabling auto-check persists and disables auto-download switch")
            autoCheckSwitch.state = .on; dispatch(autoCheckSwitch)
            let autoDownloadBack = settingControl("settings-auto-download-updates",NSSwitch.self)
            autoDownloadBack.state = .off; dispatch(autoDownloadBack)
            check(!settingsDelegate.autoDownloadUpdates && !AppCoordinator(preferences:settingsDefaults,provider:provider).autoDownloadUpdates,"disabling auto-download persists independently")
            autoDownloadBack.state = .on; dispatch(autoDownloadBack)

            let fakeRelease = AppReleaseInfo(
                version: "9.9.9", semanticVersion: SemanticVersion("9.9.9")!, tagName: "v9.9.9",
                title: "Agent Stats v9.9.9", notes: "Test release",
                htmlURL: URL(string: "https://github.com/moqiuren/agent-stats/releases/tag/v9.9.9")!,
                publishedAt: nil,
                asset: AppReleaseAsset(
                    name: "Agent-Stats-9.9.9-macos-arm64.zip",
                    downloadURL: URL(string: "https://github.com/moqiuren/agent-stats/releases/download/v9.9.9/Agent-Stats-9.9.9-macos-arm64.zip")!,
                    size: 1024, sha256: nil, kind: .zip))
            settingsDelegate.applyUpdateState(.available(fakeRelease, checkedAt: 1000))
            controller.refresh()
            check(settingControl("settings-update-primary",NSButton.self).title == "立即下载","available release offers download button")
            check(descendants(settingsWindow.contentView!).contains{$0.identifier?.rawValue=="settings-open-release-notes"},"release notes button appears when a release is available")
            check(settingsDelegate.menu.makeStatusMenu().items.contains{$0.title=="发现新版本 v9.9.9…"},"status menu highlights available release while preserving tail items")
            check(settingsDelegate.menu.makeStatusMenu().items.suffix(2).map(\.title) == ["使用说明","退出 " + Product.name],"update entry keeps help and quit as last two menu items")
            let fakeStagedApp = FileManager.default.temporaryDirectory.appendingPathComponent("FakeUpdate-\(UUID().uuidString).app")
            settingsDelegate.applyUpdateState(.downloaded(fakeRelease, StagedUpdateArtifact(version: "9.9.9", archiveURL: fakeStagedApp, stagedAppURL: fakeStagedApp)))
            controller.refresh()
            check(settingControl("settings-update-primary",NSButton.self).title == "安装并重启","verified staged update offers one-click install and relaunch")
            check(settingsDelegate.menu.makeStatusMenu().items.contains{$0.title=="重启以更新至 v9.9.9…"},"status menu highlights downloaded staged update")
            settingsDelegate.applyUpdateState(.idle(lastCheckedAt: nil))
            controller.selectPage(.sessions)
            let selectionMode=settingControl("settings-session-mode",NSPopUpButton.self)
            check(selectionMode.itemTitles.contains("最近活跃会话") && selectionMode.itemTitles.contains("固定会话"),"the session source control always offers recent activity and a fixed choice")
            check(selectionMode.itemTitles.count == (provider.supportsAutomaticSessionFollow ? 3:2) && selectionMode.itemTitles.contains("自动跟随当前对话") == provider.supportsAutomaticSessionFollow,"session settings offers automatic following only for the host that supports it")
            selectionMode.selectItem(at:selectionMode.itemTitles.firstIndex(of:"最近活跃会话")!);dispatch(selectionMode)
            check(settingsDelegate.selected=="__recent__","the session mode control selects recent activity without requesting permission")
            controller.refresh()
            let recentMode=settingControl("settings-session-mode",NSPopUpButton.self)
            check(recentMode.titleOfSelectedItem=="最近活跃会话" && recentMode.indexOfSelectedItem<recentMode.numberOfItems,"the session source control displays the active mode instead of going blank")
            let projectPicker=settingControl("settings-project-filter",NSPopUpButton.self)
            projectPicker.selectItem(withTitle:"未分组");dispatch(projectPicker)
            settingsDelegate.selectSession("settings_first");controller.refresh()
            let fixedMode=settingControl("settings-session-mode",NSPopUpButton.self)
            check(fixedMode.titleOfSelectedItem=="固定会话" && settingsDelegate.selected=="settings_first","a fixed selection is displayed as the active session source")
            let searchControl=settingControl("settings-search",NSSearchField.self)
            searchControl.stringValue="目标会话"
            searchControl.delegate?.controlTextDidChange?(Notification(name:NSControl.textDidChangeNotification,object:searchControl))
            if let action=searchControl.action{_ = app.sendAction(action,to:searchControl.target,from:searchControl)}
            let sessionTable=settingControl("settings-session-list",NSTableView.self)
            check(sessionTable.numberOfRows==1,"session search filters matching non-archived sessions")
            check(settingsDelegate.selected=="settings_first","filtering out the selected row never changes the statistics session")
            controller.refresh()
            let retainedSearch=settingControl("settings-search",NSSearchField.self)
            check(retainedSearch.stringValue=="目标会话" && settingsDelegate.selected=="settings_first","live settings refresh preserves the search and selected session")
            let filteredTable=settingControl("settings-session-list",NSTableView.self)
            filteredTable.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
            filteredTable.delegate?.tableViewSelectionDidChange?(Notification(name:NSTableView.selectionDidChangeNotification,object:filteredTable))
            if let action=filteredTable.action{_ = app.sendAction(action,to:filteredTable.target,from:filteredTable)}
            check(settingsDelegate.selected=="settings_target" && settingsDelegate.current?["totalTokens"] as? Int==42,"selecting the filtered row chooses its real session ID")
            check(AppCoordinator(preferences:settingsDefaults,provider:provider).selected=="settings_target","manual session selection from settings persists")
            settingsDelegate.hud.popover.close();settingsDelegate.resignActive()
            check(settingsWindow.isVisible,"settings survives popover dismissal and application deactivation")
            let originalSettingsFrame=settingsWindow.frame
            settingsWindow.setFrame(NSRect(origin:originalSettingsFrame.origin,size:NSSize(width:580,height:640)),display:false)
            for page in StatsSettingsPage.allCases {
                controller.selectPage(page);controller.refresh();settingsWindow.contentView!.layoutSubtreeIfNeeded()
                let content=settingsWindow.contentView!
                for control in descendants(content).compactMap({$0 as? NSControl}) where control.identifier?.rawValue.hasPrefix("settings-") == true {
                    let bounds=control.convert(control.bounds,to:content)
                    check(bounds.width>0 && bounds.minX>=0 && bounds.maxX<=content.bounds.width,"settings controls fit horizontally at the compact minimum size")
                }
            }
            settingsWindow.setFrame(originalSettingsFrame,display:false)
            if let path=ProcessInfo.processInfo.environment["STATS_PREVIEW_DIR"] {
                let folder=URL(fileURLWithPath:path);try! FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                let originalAppearance=settingsWindow.appearance
                for (compact,sizeSuffix) in [(false,""),(true,"-minimum")] {
                    settingsWindow.setFrame(compact ? NSRect(origin:originalSettingsFrame.origin,size:NSSize(width:580,height:640)):originalSettingsFrame,display:false)
                    for (appearance,appearanceSuffix) in [(NSAppearance.Name.aqua,""),(.darkAqua,"-dark")] {
                        settingsWindow.appearance=NSAppearance(named:appearance)
                        for (page,name) in [(StatsSettingsPage.general,"general"),(.metrics,"metrics"),(.tokenStats,"token-stats"),(.sessions,"sessions"),(.help,"help"),(.about,"about")] {
                            controller.selectPage(page);controller.refresh()
                            let view=settingsWindow.contentView!;view.layoutSubtreeIfNeeded();view.displayIfNeeded()
                            let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
                            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in:view.bounds,to:bitmap) }
                            try! bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(provider.rawValue+"-settings-"+name+sizeSuffix+appearanceSuffix+".png"))
                        }
                    }
                }
                settingsWindow.appearance=originalAppearance
                settingsWindow.setFrame(originalSettingsFrame,display:false)
            }
            check(!settingsDelegate.shouldPauseReader(hostAvailable:false,hostOrStatsActive:false),"visible settings keeps its data reader active without a host")
            controller.close()
            check(!settingsWindow.isVisible,"closing settings leaves its background app available")
            check(settingsDelegate.shouldPauseReader(hostAvailable:false,hostOrStatsActive:true),"closing floating settings pauses the reader when no host is available")
            check(settingsDelegate.shouldPauseReader(hostAvailable:true,hostOrStatsActive:false),"floating statistics pause when neither the host nor Stats is active")
            check(!settingsDelegate.shouldPauseReader(hostAvailable:true,hostOrStatsActive:true),"floating statistics keep reading while their host is available and active")
            settingsDelegate.displayMode = .menuBar
            for available in [false,true] { for active in [false,true] {
                check(!settingsDelegate.shouldPauseReader(hostAvailable:available,hostOrStatsActive:active),"menu bar statistics keep reading independently of host availability and focus")
            } }
            settingsDelegate.displayMode = .floating
            settingsDelegate.showSettings()
            check(settingsDelegate.settingsWindow===controller && settingsWindow.isVisible,"settings can reopen after close without creating another controller")
        }
        if let path=ProcessInfo.processInfo.environment["STATS_PREVIEW_DIR"] {
            let folder=URL(fileURLWithPath:path);try! FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            func snapshot(_ view:NSView,_ name:String){
                view.layoutSubtreeIfNeeded();view.displayIfNeeded()
                let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
                view.cacheDisplay(in:view.bounds,to:bitmap)
                try! bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(provider.rawValue+"-"+name+".png"))
            }
            delegate.current=["tps":70,"avgTtftMs":1000,"lastTurn":["tps":42,"ttftMs":500],"totalTokens":128450,"cacheHit":81,"totalMs":124000]
            delegate.presentFixtureTitle("模块化悬浮条")
            delegate.modules=[HUDMetric.speed,.latency,.usage,.cacheHit,.timing].map{HUDModule(metric:$0)}
            let host=NSRect(x:0,y:0,width:1000,height:750)
            delegate.hud.applyModules()
            delegate.hud.panel.setFrame(delegate.hud.placement.frame(host:host,screen:host),display:false)
            snapshot(delegate.hud.panel.contentView!,"top")
            let narrow=NSRect(x:0,y:0,width:420,height:600)
            delegate.hud.panel.setFrame(delegate.hud.placement.frame(host:narrow,screen:narrow),display:false)
            snapshot(delegate.hud.panel.contentView!,"top-clamped")
            delegate.hud.popover.present(kind:"modules",title:"显示指标",anchor:delegate.hud.metricScroll,host:host,screen:host,bar:delegate.hud.panel.frame,display:false,customSize:CGSize(width:400,height:390),customBody:{width in HUDModuleEditor(width:width,modules:delegate.modules,available:HUDMetric.available(for:provider.rawValue)){delegate.editModules($0)}})
            snapshot(delegate.hud.popover.window.contentView!,"editor")
            delegate.hud.popover.close()
            delegate.displayMode = .menuBar;delegate.menu.status.menu=delegate.menu.makeStatusMenu();delegate.menu.updateStatusPresentation()
            // NSStatusBarButton finalizes its native title geometry on the next run-loop pass.
            // Capture only after that pass, otherwise the bitmap can clip a correctly rendered title.
            let statusButton=delegate.menu.status.button!,layoutDeadline=Date().addingTimeInterval(1)
            var statusTitleRect=NSRect.zero
            repeat {
                RunLoop.main.run(until:Date().addingTimeInterval(0.02))
                statusButton.window?.contentView?.layoutSubtreeIfNeeded()
                statusTitleRect=statusButton.cell!.titleRect(forBounds:statusButton.bounds)
                if !statusTitleRect.isEmpty && statusButton.bounds.contains(statusTitleRect){break}
            }while Date()<layoutDeadline
            check(!statusTitleRect.isEmpty && statusButton.bounds.contains(statusTitleRect),"menu bar preview captures a fully laid-out native title inside the button bounds: \(statusButton.bounds) title: \(statusTitleRect)")
            snapshot(statusButton,"menubar")
            let context=delegate.hud.inspectorContext(anchor:delegate.hud.metricScroll)!
            delegate.hud.popover.present(kind:"modules",title:"显示指标",anchor:context.anchor,host:context.host,screen:context.screen,bar:context.bar,display:false,attachToOwner:false,customSize:CGSize(width:400,height:390),customBody:{width in HUDModuleEditor(width:width,modules:delegate.modules,available:HUDMetric.available(for:provider.rawValue)){delegate.editModules($0)}})
            snapshot(delegate.hud.popover.window.contentView!,"menubar-editor")
            delegate.hud.popover.close()
            delegate.hud.popover.present(kind:"detail-rows",title:"展开明细",anchor:context.anchor,host:context.host,screen:context.screen,bar:context.bar,display:false,attachToOwner:false,customSize:CGSize(width:400,height:520),customBody:{width in HUDDetailRowEditor(width:width,provider:provider,enabled:delegate.detailRowKeys){key,on in delegate.editDetailRow(key,enabled:on)}})
            snapshot(delegate.hud.popover.window.contentView!,"detail-rows")
            delegate.hud.popover.close()
        }
        print("\(checks) \(provider.rawValue) app integration checks passed")
        testProjectAccounting(provider)
    }

    static func testMenuControls(_ provider:StatsProvider) {
        var checks=0
        func check(_ value:Bool,_ message:String){precondition(value,message);checks+=1}
        let suite="stats-menu-controls-"+UUID().uuidString
        let isolated=UserDefaults(suiteName:suite)!
        defer{isolated.removePersistentDomain(forName:suite)}
        let delegate=AppCoordinator(preferences:isolated,provider:provider)
        delegate.followsActiveTool=false;delegate.hud.makePanel();delegate.menu.makeStatus()
        defer{delegate.hud.popover.close();NSStatusBar.system.removeStatusItem(delegate.menu.status);delegate.hud.panel.close()}
        delegate.sessions=[["id":"chosen","title":"项目中的对话","totalTokens":42],["id":"other","title":"另一个对话","totalTokens":99]]
        delegate.selected="chosen";delegate.render()
        let originalModules=delegate.modules
        for mode in StatsDisplayMode.allCases {
            delegate.hud.interactionMenuOpen=true;delegate.setDisplayMode(mode);delegate.hud.interactionMenuOpen=false
            delegate.hudHidden=true;delegate.hud.lastRect=nil
            let menu=delegate.menu.makeStatusMenu()
            let chooser=menu.items.filter{$0.title=="选择对话"}
            let editors=menu.items.filter{$0.title=="指标设置"}
            check(chooser.count==1 && chooser[0].submenu != nil && chooser[0].representedObject==nil,"both presentation modes expose one native conversation submenu")
            check(editors.count==1 && editors[0].submenu != nil && editors[0].representedObject==nil,"both presentation modes expose one native metric submenu")
            check(menu.items.contains{$0.title=="闲置后下沉"} == (mode == .floating),"idle sink toggle appears in the status menu only during floating mode")
            check(delegate.menu.validateMenuItem(chooser[0]) && delegate.menu.validateMenuItem(editors[0]),"menu configuration stays enabled with a hidden HUD and no host")
            check(!delegate.menu.menuBarTitle(maxWidth:1000).contains("项目中的对话"),"menu bar summary does not contain the conversation selector")
            let conversation=chooser[0].submenu!
            delegate.menu.menuNeedsUpdate(conversation)
            let automatic=provider.supportsAutomaticSessionFollow
            let modes=conversation.items.filter{$0.action == #selector(StatusMenuController.pickMenuSession(_:)) && ($0.title.hasPrefix("自动跟随") || $0.title=="最近活跃会话")}
            check(modes.count == (automatic ? 2:1) && modes.last?.title=="最近活跃会话" && (automatic ? modes[0].title.hasPrefix("自动跟随"):true),"automatic following appears in the chooser only for the host that supports it")
            check(delegate.sessionModes().contains{$0.id=="__current__"} == automatic,"the session modes agree with the chooser")
            check(modes.allSatisfy{$0.state == (((($0.title.hasPrefix("自动跟随")) ? SessionSelectionMode.automatic:.recent) == delegate.selectionMode) ? .on:.off)},"the native chooser marks the active selection mode")
            let ungrouped=conversation.items.first{$0.title=="未分组"}
            check(ungrouped?.submenu != nil && ungrouped?.representedObject==nil,"each project is a hover-opened submenu rather than a click action")
            delegate.menu.menuNeedsUpdate(ungrouped!.submenu!)
            let other=ungrouped!.submenu!.items.first{$0.title=="另一个对话"}!
            check(other.action == #selector(StatusMenuController.pickMenuSession(_:)) && other.target === delegate.menu && other.state == .off,"conversation rows are native items with native state marks")
            _=NSApp.sendAction(other.action!,to:other.target,from:other)
            check(delegate.selected=="other" && delegate.current?["totalTokens"] as? Int==99,"a native conversation row selects and displays the requested dialogue")
            check(!delegate.hud.popover.isShown,"the native chooser never falls back to the retired custom panel")
            delegate.menu.menuNeedsUpdate(conversation)
            let reopened=conversation.items.first{$0.title=="未分组"}!.submenu!
            delegate.menu.menuNeedsUpdate(reopened)
            check(reopened.items.first{$0.title=="另一个对话"}!.state == .on,"reopening a hover submenu marks the live selection")
            let metrics=editors[0].submenu!
            delegate.menu.menuNeedsUpdate(metrics)
            let target=HUDMetric.output
            func metricRow(_ title:String)->NSMenuItem{metrics.items.first{$0.title==title}!}
            check(metricRow(target.label).state == (delegate.modules.contains{$0.metric==target} ? .on:.off),"the metric submenu marks configured metrics")
            let chosen=metricRow(target.label)
            _=NSApp.sendAction(chosen.action!,to:chosen.target,from:chosen)
            check(delegate.modules.contains{$0.metric==target} && AppCoordinator(preferences:isolated,provider:provider).modules==delegate.modules,"a native metric row changes and persists the selected provider's layout")
            delegate.menu.menuNeedsUpdate(metrics)
            let removal=metricRow(target.label)
            _=NSApp.sendAction(removal.action!,to:removal.target,from:removal)
            check(!delegate.modules.contains{$0.metric==target},"the same native row removes the metric again")
            delegate.menu.menuNeedsUpdate(metrics)
            let reset=metricRow("恢复默认指标")
            _=NSApp.sendAction(reset.action!,to:reset.target,from:reset)
            check(delegate.modules.map(\.metric)==HUDModuleSettings.defaults(provider:provider.rawValue).map(\.metric),"restoring defaults stays a native menu command")
            delegate.menu.menuNeedsUpdate(metrics)
            let handoff=metricRow("在设置中编辑…")
            _=NSApp.sendAction(handoff.action!,to:handoff.target,from:handoff)
            check(delegate.settingsWindow?.page == .metrics && delegate.settingsWindow?.window?.isVisible==true,"the metric submenu hands off to the settings window")
            delegate.settingsWindow?.close()
            delegate.modules=originalModules;delegate.hud.applyModules();delegate.selected="chosen";delegate.render()
        }
        // Automatic and recent modes must still name the conversation in use: the
        // parent item is checked and the followed row is checked inside its project.
        let followWindow=HostWindowReference(pid:1,number:12,bounds:CGRect(x:0,y:0,width:900,height:650))
        delegate.observeWindow(followWindow)
        delegate.selected = provider.supportsAutomaticSessionFollow ? "__current__":"__recent__"
        if provider.supportsAutomaticSessionFollow {
            delegate.receive(["nativeSelection":CurrentSession(.current,id:"other",window:followWindow.token).json])
        }
        delegate.render()
        let displayedID=delegate.current?["id"] as? String
        check(displayedID != nil,"both following modes resolve a conversation to display")
        let followedMenu=delegate.menu.makeStatusMenu();delegate.menu.menuNeedsUpdate(followedMenu)
        let followedChooser=followedMenu.items.first{$0.title=="选择对话"}!
        check(followedChooser.state == .on,"a following mode checks the conversation item")
        delegate.menu.menuNeedsUpdate(followedChooser.submenu!)
        let followedGroup=followedChooser.submenu!.items.first{$0.title=="未分组"}!.submenu!
        delegate.menu.menuNeedsUpdate(followedGroup)
        let followedRows=followedGroup.items.filter{$0.action == #selector(StatusMenuController.pickMenuSession(_:))}
        check(followedRows.filter{$0.state == .on}.count==1 && followedRows.first{$0.state == .on}?.title==displayedID.map{_ in followedRows.first{$0.state == .on}!.title},"the followed conversation is checked inside its project")
        check(followedRows.first{$0.state == .on}?.toolTip?.hasPrefix("当前显示的对话")==true,"the followed row states that it is the displayed conversation")
        check(followedRows.first{$0.state == .on}?.representedObject.map{($0 as! StatsSessionMenuItem).session} == displayedID,"the checked row is the displayed conversation, not merely the pinned one")
        if !provider.supportsAutomaticSessionFollow {
            delegate.selected="__current__";delegate.render()
            check(delegate.selectionMode == .recent,"a stored automatic preference falls back to recent instead of an unavailable mode")
        }
        delegate.selected="chosen";delegate.render()
        check(delegate.menu.makeStatusMenu().items.first{$0.title=="选择对话"}!.state == .off,"a fixed selection does not check the parent item")
        check(delegate.menu.makeStatusMenu().items.first{$0.title=="选择对话"}!.state == .off,"a fixed selection does not check the parent item")
        // Kimi reports a context length measured by the host itself, plus host task
        // and interaction records. It never turns those into a ratio or a guessed limit.
        let available=HUDMetric.available(for:provider.rawValue)
        check(available.contains(where:{HUDMetric.kimiOnly.contains($0)}) == (provider == .kimi),"only Kimi offers its own context length, background tasks and waiting state")
        if provider == .kimi {
            check(available.contains(.contextLength) && available.contains(.backgroundTasks) && available.contains(.waitingUser),"Kimi exposes context length, background tasks and waiting state")
            check(available.firstIndex(of:.contextLength)! > available.firstIndex(of:.cacheHit)! && available.firstIndex(of:.contextLength)! < available.firstIndex(of:.subagents)!,"the context length sits with the usage metrics")
            let running:JSONObject=["id":"bash-y","description":"npm run dev","status":"running","startedAt":Date().timeIntervalSince1970*1000-60000]
            let state:JSONObject=["id":"kimi-state","title":"Kimi 运行状态","totalTokens":10,"contextTokens":134088,
                "backgroundRunning":2,"backgroundTotal":5,"backgroundItems":[running],
                "pendingApprovals":1,"pendingQuestions":2,"permissionMode":"yolo"]
            delegate.sessions=[state];delegate.selected="kimi-state";delegate.render()
            check(HUDMetric.contextLength.value(in:state) as? Double == 134088,"the context length uses the host measurement")
            check(HUDMetric.backgroundTasks.value(in:state) as? Double == 2,"the background module counts running host tasks")
            check(HUDMetric.waitingUser.value(in:state) as? Double == 3,"the waiting module adds approvals and questions")
            check(HUDMetric.waitingUser.value(in:["id":"none","title":"无记录"]) == nil,"a missing interaction record stays unknown instead of zero")
            let status=Dictionary(uniqueKeysWithValues:delegate.metrics.content("kimi").0)
            check(status["后台任务运行中"]=="2" && status["等待批准"]=="1" && status["等待回答"]=="2","the Kimi panel separates running tasks from approvals and questions")
            check(status["权限模式"]=="yolo（不再逐次询问）","the recorded permission mode is shown in words")
            check(status["npm run dev"]=="运行中 · 已运行 1m","a running host task is listed with its recorded description")
            check(status.keys.contains("插件上报"),"the panel reports the last plugin event for diagnosis")
            check(Dictionary(uniqueKeysWithValues:delegate.metrics.content("usage").0)["上下文长度"]=="134,088","the usage panel shows the context length")
            delegate.modules=[HUDModule(metric:.backgroundTasks)];delegate.hud.applyModules()
            check(delegate.hud.moduleButtons.count==1 && delegate.modules.count==1,"a Kimi-only metric behaves like any other module")
            delegate.modules=originalModules;delegate.hud.applyModules()
        }
        // A native menu grows to fit its content, so long titles and long
        // conversation lists must be bounded instead of stretching the panel.
        let longTitle=String(repeating:"很长的会话名称",count:20)
        let big:JSONObject=["id":"big","title":"大项目"]
        delegate.sessionGroups=[big]
        var many:[JSONObject]=[["id":"long","title":longTitle,"group":big,"totalTokens":7]]
        many+=(1...30).map{["id":"row-\($0)","title":"对话 \($0)","group":big,"totalTokens":$0]}
        delegate.sessions=many;delegate.selected="row-1";delegate.render()
        let bounded=delegate.menu.makeSessionMenu();delegate.menu.menuNeedsUpdate(bounded)
        check(bounded.items.compactMap{$0.submenu}.map(\.title)==["大项目","未分组"],"a project still opens as a native folder")
        let folder=bounded.items.first{$0.title=="大项目"}!.submenu!
        delegate.menu.menuNeedsUpdate(folder)
        let menuFont=NSFont.menuFont(ofSize:0)
        func menuWidth(_ title:String)->CGFloat{(title as NSString).size(withAttributes:[.font:menuFont]).width}
        let rows=folder.items.filter{$0.action == #selector(StatusMenuController.pickMenuSession(_:))}
        check(rows.count==31 && rows.count<StatusMenuController.menuSessionLimit,"every conversation is listed so the native menu scrolls instead of sending the user to the settings window")
        check(!folder.items.contains{$0.title.hasPrefix("还有 ")},"no overflow placeholder appears while the list still fits the scrollable menu")
        check(rows.allSatisfy{menuWidth($0.title)<=StatusMenuController.menuTitleWidth},"native menu titles stay inside the width budget")
        check(rows.first?.title.hasSuffix("…")==true && rows.first?.title != longTitle,"over-long titles are shortened with an ellipsis")
        check(rows.first?.toolTip==longTitle,"a shortened row keeps the complete title in its tooltip")
        // Past the guard cap the settings window takes over the remainder.
        delegate.sessions=many+(1...StatusMenuController.menuSessionLimit).map{["id":"cap-\($0)","title":"上限对话 \($0)","group":big,"totalTokens":$0]}
        delegate.render()
        let capped=delegate.menu.makeSessionMenu();delegate.menu.menuNeedsUpdate(capped)
        let capFolder=capped.items.first{$0.title=="大项目"}!.submenu!
        delegate.menu.menuNeedsUpdate(capFolder)
        check(capFolder.items.contains{$0.title.hasPrefix("还有 ") && !$0.isEnabled},"beyond the guard cap the remainder is reported instead of silently dropped")
        let overflow=capFolder.items.first{$0.title=="在设置中查看该项目…"}!
        _=NSApp.sendAction(overflow.action!,to:overflow.target,from:overflow)
        check(delegate.selectedProject=="big" && delegate.settingsWindow?.page == .sessions,"the overflow row hands the project to the settings window")
        delegate.settingsWindow?.close();delegate.selected="chosen";delegate.render()
        // The usage help lives in the settings window: fully laid out native
        // labels, never a clipped inspector row or a web page.
        let categories=HelpDocs.categories(for:provider)
        check(!categories.isEmpty && categories.allSatisfy{!$0.items.isEmpty},"the help keeps its categorized structure")
        let tools=categories.first{$0.id=="tools"}!
        check(!tools.items.isEmpty && categories.contains{$0.id=="tool-"+provider.rawValue && $0.items.contains{$0.1==HelpDocs.providerDetail(provider)}},"the categories cover the active tool's own notes")
        for category in categories {
            check(Set(category.items.map(\.0)).count==category.items.count && category.items.allSatisfy{!$0.0.isEmpty && !$0.1.isEmpty},"each help category has unique titled entries")
        }
        check(categories.flatMap(\.items).map{$0.0+$0.1}.joined(separator:" ").contains("python3 uninstall.py --app agent"),"the maintenance category keeps the explicit uninstall command")
        let helpContent=HUDHelpContentView(width:520,categories:categories)
        var helpText=""
        func collect(_ view:NSView){for sub in view.subviews{if let label=sub as? NSTextField{helpText+=label.stringValue+"\n"};collect(sub)}}
        collect(helpContent)
        for category in categories { for item in category.items {
            check(helpText.contains(item.0) && helpText.contains(item.1),"the help view shows every category entry in full: "+item.0)
        } }
        let entryHeight=ceil((categories[0].items[0].1 as NSString).boundingRect(with:NSSize(width:480,height:10000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:NSFont.systemFont(ofSize:12)]).height)
        check(entryHeight>18,"help body text wraps instead of staying a single clipped line")
        check(helpContent.frame.height>CGFloat(categories.count)*80,"the help content height fits its wrapped text")
        delegate.showHelpSettings()
        check(delegate.settingsWindow?.page == .help && delegate.settingsWindow?.window?.isVisible==true,"the help command opens the settings window's help page")
        // Choosing a category in the menu bar lands on that category in the window.
        let picked=NSMenuItem(title:"",action:#selector(StatusMenuController.showHelpCategory(_:)),keyEquivalent:"");picked.representedObject=categories[3].id;picked.target=delegate.menu
        delegate.settingsWindow?.close()
        _=NSApp.sendAction(picked.action!,to:picked.target,from:picked)
        check(delegate.settingsWindow?.page == .help && delegate.settingsWindow?.window?.isVisible==true,"a menu category opens the settings window instead of a web page")
        delegate.settingsWindow?.scrollHelpCategory(categories[3].id)
        check(delegate.settingsWindow!.window!.contentView!.subviews.count>0,"the chosen category is scrolled into the same native help page")
        let helpBody=delegate.settingsWindow!.window!.contentView!
        var helpWindowText="";func collectWindow(_ view:NSView){for sub in view.subviews{if let label=sub as? NSTextField{helpWindowText+=label.stringValue+"\n"};collectWindow(sub)}}
        collectWindow(helpBody)
        check(helpWindowText.contains(categories[0].items[0].1),"the settings help page renders the full help text")
        // The category picker is pinned in the window header: it must show the category
        // the menu bar opened, keep that state while the body scrolls, and stay clear of
        // the body whenever the page is at the top of its scroll.
        func helpDescendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap{(sub:NSView)->[NSView] in helpDescendants(sub)}}
        func helpPicker()->NSPopUpButton?{helpDescendants(helpBody).first{$0.identifier?.rawValue=="settings-help-category"} as? NSPopUpButton}
        helpBody.layoutSubtreeIfNeeded()
        guard let pinnedPicker=helpPicker() else{preconditionFailure("the help page keeps its category picker")}
        check(pinnedPicker.titleOfSelectedItem == categories[3].title,"the help category picker shows the category the menu bar opened")
        check(!pinnedPicker.isHidden && helpBody.bounds.contains(pinnedPicker.convert(pinnedPicker.bounds,to:helpBody)),"the help category picker stays pinned in the window while the body scrolls")
        delegate.settingsWindow?.selectPage(.help)
        helpBody.layoutSubtreeIfNeeded()
        guard let topPicker=helpPicker(),let helpContentView=helpDescendants(helpBody).first(where:{$0 is HUDHelpContentView}) else{preconditionFailure("the help page keeps its picker and its body")}
        check(topPicker.convert(topPicker.bounds,to:helpBody).maxY <= helpContentView.convert(helpContentView.bounds,to:helpBody).minY,"the help body starts below the pinned category picker instead of covering it")
        // A category header inside the body jumps that category to the top of the page.
        guard let section=helpDescendants(helpContentView).compactMap({$0 as? HUDHelpCategoryLabel}).first(where:{$0.stringValue==categories[2].title}) else{preconditionFailure("every help category keeps a clickable header")}
        check(section.onSelect != nil && section.toolTip != nil,"a help category header advertises its jump target")
        let point=section.convert(NSPoint(x:section.bounds.midX,y:section.bounds.midY),to:nil)
        let press=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        let release=NSEvent.mouseEvent(with:.leftMouseUp,location:point,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:1,clickCount:1,pressure:0)!
        section.mouseDown(with:press);section.mouseUp(with:release)
        helpBody.layoutSubtreeIfNeeded()
        let pageScroll=helpDescendants(helpBody).compactMap{$0 as? NSScrollView}.first{$0.identifier?.rawValue=="settings-page-scroll"}
        let offset=pageScroll?.contentView.bounds.origin.y ?? -1
        // The jump aligns the category's own header row with the top of the body.
        let headerTop=helpContentView.frame.minY+section.frame.minY
        check(offset>0 && abs(headerTop-offset)<=1,"clicking a category header scrolls that category to the top")
        check(helpPicker()?.titleOfSelectedItem == categories[2].title,"clicking a category header keeps the pinned picker in step")
        check(helpDescendants(helpContent).compactMap({$0 as? HUDHelpCategoryLabel}).allSatisfy{$0.onSelect == nil},"a standalone help view keeps its headers inert")
        delegate.settingsWindow?.close()
        delegate.displayMode = .floating
        let expectedSize=NSSize(width:12+delegate.hud.metricStripWidth(),height:28)
        check(delegate.hud.preferredHUDSize()==expectedSize,"HUD dimensions contain exactly the metric strip and its insets")
        delegate.modules=[];delegate.hud.applyModules()
        check(delegate.hud.preferredHUDSize()==NSSize(width:24,height:28),"an empty HUD reserves only its minimum width")
        check(delegate.menu.makeStatusMenu().items.contains{$0.title=="指标设置" && $0.submenu != nil},"an empty display remains configurable from the native menu")
        print("\(checks) \(provider.rawValue) menu control checks passed")
    }

    static func testStatusItemVisibility() {
        var checks=0
        func check(_ value:Bool,_ message:String){precondition(value,message);checks+=1}
        let suite="stats-status-item-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let delegate=AppCoordinator(preferences:defaults,provider:.codex)
        delegate.followsActiveTool=false;delegate.hud.makePanel();delegate.menu.makeStatus();delegate.hud.interactionMenuOpen=true
        defer{delegate.settingsWindow?.close();delegate.menu.removeStatusItem();delegate.hud.panel.close()}
        check(!delegate.statusItemHidden && delegate.menu.status.isVisible,"the menu bar icon is visible by default")
        delegate.setStatusItemHidden(true)
        check(!delegate.menu.status.isVisible && AppCoordinator(preferences:defaults,provider:.codex).statusItemHidden,"hiding the menu bar icon hides the status item and persists")
        delegate.setDisplayMode(.menuBar)
        check(delegate.menu.status.isVisible,"menu bar mode forces the status item visible")
        delegate.setDisplayMode(.floating)
        check(!delegate.menu.status.isVisible,"returning to floating mode respects the hidden status item preference")
        delegate.setStatusItemHidden(false)
        check(delegate.menu.status.isVisible,"disabling the hidden preference restores the status item")
        delegate.handleReopen()
        check(delegate.settingsWindow == nil,"reopen ignores calls before the coordinator has started")
        check(AppCoordinator.showSettingsNotification.rawValue == Product.bundleID + ".showSettings","duplicate-launch handoff uses the product's distributed notification name")
        print("\(checks) status item visibility checks passed")
    }

    static func testProjectAccounting(_ provider:StatsProvider) {
        let suite="stats-project-tests-"+UUID().uuidString
        let isolated=UserDefaults(suiteName:suite)!
        defer{isolated.removePersistentDomain(forName:suite)}
        let delegate=AppCoordinator(preferences:isolated,provider:provider);delegate.followsActiveTool=false;delegate.hud.makePanel();delegate.hud.interactionMenuOpen=true
        var checks=0
        func check(_ value:Bool,_ message:String){precondition(value,message);checks+=1}
        let accounting=usageProject(cwd:"/temporary/12345")
        let a:JSONObject=["id":"123456789","title":"我的项目"],b:JSONObject=["id":"987654321","title":"另一个项目"]
        delegate.sessionGroups=[a,b,ProjectCatalog.ungrouped]
        delegate.agents=[["key":"first:main","sessionID":"first","agentID":"main","role":"main","project":accounting,"totalTokens":30],
                         ["key":"first:worker","sessionID":"first","agentID":"worker","role":"subagent","project":accounting,"totalTokens":60]]
        delegate.sessions=[["id":"first","title":"项目中的对话","group":a,"project":accounting,"totalTokens":90,"agents":delegate.agents,"coverageNote":"不应显示的说明"],
                           ["id":"other","title":"另一段对话","group":b,"totalTokens":120],
                           ["id":"loose","title":"独立对话","totalTokens":10]]
        delegate.selected="first";delegate.render()
        check(delegate.metrics.content("usage").1.isEmpty,"usage inspector has no path, coverage, or explanatory footer")
        check(delegate.metrics.content("usage").0.contains{$0.0=="主代理 Token" && $0.1=="30"} && !delegate.metrics.content("usage").0.contains{$0.0.hasPrefix("子代理 ·")},"usage summary separates the main agent and leaves child details in the dedicated module")
        check(delegate.projectGroups.map{identifier($0["title"])}==["我的项目","另一个项目","未分组"],"project names are user labels, never generated IDs or paths")
        let host=NSRect(x:100,y:100,width:900,height:650)
        delegate.hud.lastRect=host;delegate.hud.panel.setFrame(NSRect(x:120,y:650,width:600,height:34),display:false)
        let sessions=delegate.menu.makeSessionMenu()
        delegate.menu.menuNeedsUpdate(sessions)
        check(!sessions.items.contains{$0.title=="项目中的对话"},"root navigation contains project folders instead of mixed conversations and aggregates")
        check(sessions.items.compactMap{$0.submenu}.map(\.title)==["我的项目","另一个项目","未分组"],"native folders use the same saved project names as the settings window")
        let mine=sessions.items.first{$0.title=="我的项目"}!.submenu!
        delegate.menu.menuNeedsUpdate(mine)
        check(mine.items.map(\.title)==["项目中的对话"],"a project folder lists only its own conversations")
        check(mine.items[0].state == .on && delegate.selected=="first","browsing a project folder never changes statistics and marks the open conversation")
        let peer=sessions.items.first{$0.title=="另一个项目"}!.submenu!
        delegate.menu.menuNeedsUpdate(peer)
        let peerRow=peer.items[0]
        _=NSApp.sendAction(peerRow.action!,to:peerRow.target,from:peerRow)
        check(delegate.selected=="other" && number(delegate.current?["totalTokens"])==120 && delegate.selectedProject=="987654321","a native row selects its real conversation ID and records its project")
        let loose=sessions.items.first{$0.title=="未分组"}!.submenu!
        delegate.menu.menuNeedsUpdate(loose)
        check(loose.items.map(\.title)==["独立对话"],"unassigned conversations appear together under Ungrouped")
        let looseRow=loose.items[0]
        _=NSApp.sendAction(looseRow.action!,to:looseRow.target,from:looseRow)
        check(delegate.selected=="loose" && delegate.selectedProject==ProjectCatalog.ungroupedID,"choosing an unassigned conversation selects its real ID")
        delegate.showSettings();let controller=delegate.settingsWindow!;controller.selectPage(.sessions)
        func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap{descendants($0)}}
        let popup=descendants(controller.window!.contentView!).first{$0.identifier?.rawValue=="settings-project-filter"} as! NSPopUpButton
        check(popup.itemTitles==["选择项目","我的项目","另一个项目","未分组"],"settings uses the same project hierarchy and human names")
        popup.selectItem(withTitle:"我的项目");_ = NSApp.sendAction(popup.action!,to:popup.target,from:popup)
        let table=descendants(controller.window!.contentView!).first{$0.identifier?.rawValue=="settings-session-list"} as! NSTableView
        check(table.numberOfRows==1 && delegate.selected=="loose","settings project browsing never changes the selected conversation")
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        table.delegate?.tableViewSelectionDidChange?(Notification(name:NSTableView.selectionDidChangeNotification,object:table))
        check(delegate.selected=="first" && number(delegate.current?["totalTokens"])==90,"settings selects a project's conversation and retains aggregated usage")
        delegate.sessionGroups[0]["title"]="重命名项目";controller.refresh()
        check(popup.itemTitles.contains("重命名项目") && !popup.itemTitles.contains("我的项目"),"project renames update without changing identity")
        if let path=ProcessInfo.processInfo.environment["STATS_PREVIEW_DIR"] {
            let folder=URL(fileURLWithPath:path);try! FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            func snapshot(_ view:NSView,_ name:String){
                view.layoutSubtreeIfNeeded();view.displayIfNeeded()
                let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
                view.effectiveAppearance.performAsCurrentDrawingAppearance{view.cacheDisplay(in:view.bounds,to:bitmap)}
                try! bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(provider.rawValue+"-"+name+".png"))
            }
            snapshot(controller.window!.contentView!,"project-settings")
            let content=delegate.metrics.content("usage")
            delegate.hud.popover.present(kind:"usage",title:"Token 用量",rows:content.0,note:content.1,anchor:delegate.hud.metricScroll,host:host,screen:host,bar:delegate.hud.panel.frame,display:false)
            snapshot(delegate.hud.popover.window.contentView!,"usage-no-footer")
        }
        controller.close();delegate.hud.popover.close();delegate.hud.panel.close()
        print("\(checks) \(provider.rawValue) project hierarchy checks passed")
    }

    static func testPreferenceMigration() {
        var checks=0
        func check(_ condition:Bool,_ message:String){precondition(condition,message);checks += 1}
        let suite="stats-migration-tests-"+UUID().uuidString
        let migrated=UserDefaults(suiteName:suite)!
        defer{migrated.removePersistentDomain(forName:suite)}
        let codexLayout=[["id":"old-codex-speed","metric":"speed"],["id":"old-codex-reasoning","metric":"modelUseTime"]]
        let values:[String:[String:Any]]=[
            "codex":["selectedSession.codex":"codex-pinned","displayMode.codex":"floating","hudHidden.codex":true,
                     "hudModuleLayout.v1":codexLayout,"unrelatedLegacyPreference":"ignored"],
            "kimi":["selectedSession.kimi":"kimi-pinned","displayMode.kimi":"menuBar","hudHidden.kimi":false,
                    "hudModules":["usage","output"]]
        ]
        migrated.set("menuBar",forKey:"displayMode.codex")
        Product.migratePreferences(to:migrated,legacyValues:values)
        check(migrated.bool(forKey:"unifiedMigration.v1"),"successful migration records its one-time marker")
        check(migrated.string(forKey:"selectedSession.codex")=="codex-pinned" && migrated.string(forKey:"selectedSession.kimi")=="kimi-pinned","old app selections migrate into separate tool preferences")
        check(migrated.string(forKey:"displayMode.codex")=="menuBar","migration preserves an already configured unified preference")
        check(migrated.string(forKey:"placement.codex.dock")==nil && migrated.string(forKey:"placement.kimi.dock")==nil && migrated.object(forKey:"placement.codex.relativeX")==nil,"retired position preferences are not migrated into the unified app")
        check(migrated.bool(forKey:"hudHidden.codex") && !migrated.bool(forKey:"hudHidden.kimi"),"each tool retains its visibility preference")
        check(migrated.object(forKey:"unrelatedLegacyPreference")==nil,"migration leaves unrelated settings untouched")
        check(migrated.array(forKey:HUDModuleSettings.storageKey(for:"codex")) as? [[String:String]]==codexLayout,"module identities and order survive migration from the old app")
        let codex=AppCoordinator(preferences:migrated,provider:.codex),kimi=AppCoordinator(preferences:migrated,provider:.kimi)
        check(codex.modules.map(\.id)==["old-codex-speed","old-codex-reasoning"] && codex.modules.map(\.metric)==[.speed,.modelTime],"the unified app consumes the migrated native module layout")
        check(kimi.modules.map(\.metric)==[.usage,.output],"older module-name preferences migrate into the correct tool's current layout")
        migrated.set("new-codex-pinned",forKey:"selectedSession.codex")
        let saved=migrated.persistentDomain(forName:suite)!
        Product.migratePreferences(to:migrated,legacyValues:["codex":["selectedSession.codex":"stale-selection"],"kimi":["hudModules":["timing"]]])
        check(NSDictionary(dictionary:saved).isEqual(to:migrated.persistentDomain(forName:suite)!),"repeated migration is idempotent and cannot undo post-upgrade choices")
        print("\(checks) unified preference migration checks passed")
    }

    static func testProviderSwitching() {
        var checks=0
        func check(_ condition:Bool,_ message:String){precondition(condition,message);checks += 1}
        final class FixtureReader: StatsReading {
            let identity: Int
            let provider: StatsProvider
            var reads = 0
            init(_ identity: Int, provider: StatsProvider) { self.identity = identity; self.provider = provider }
            func scan(selected: String?, now: Double) -> StatsSnapshot {
                reads += 1
                return StatsSnapshot(provider: provider, collectedAt: now, sessions: [SessionSnapshot([
                    "id": String(identity), "title": nullable(selected), "totalTokens": reads
                ])])
            }
        }
        var identities = 0
        let readers = StatsReaderStore(capacity: 2, idleLifetime: 60) { provider in
            identities += 1
            return FixtureReader(identities, provider: provider)
        }
        func read(_ provider: StatsProvider, _ uptime: Double, selected: String? = nil) -> StatsSnapshot {
            readers.queue.sync { readers.scan(provider: provider, selected: selected, now: 10000, uptime: uptime) }
        }
        let first = read(.codex, 0)
        let kimi = read(.kimi, 1)
        let resumed = read(.codex, 2, selected: "pinned")
        check(first.sessions.first?.statistics.id == resumed.sessions.first?.statistics.id && resumed.sessions.first?.statistics.usage.totalTokens.value == 2,
              "switching back reuses the native reader and verifies files with a fresh scan")
        check(resumed.sessions.first?.statistics.title == "pinned", "cached readers receive the new selection")
        check(first.sessions.first?.statistics.id != kimi.sessions.first?.statistics.id, "providers never share a reader")
        check(first.provider == .codex && kimi.provider == .kimi && resumed.provider == .codex && resumed.collectedAt == 10000,
              "typed collection results retain their own provider and millisecond timestamp")
        let expired = read(.kimi, 70)
        check(expired.sessions.first?.statistics.id != kimi.sessions.first?.statistics.id, "idle readers expire before reuse")
        let suite="stats-provider-tests-"+UUID().uuidString
        // A dedicated defaults domain makes these checks independent of installed app preferences.
        let preferences=UserDefaults(suiteName:suite)!
        defer{preferences.removePersistentDomain(forName:suite)}
        let delegate=AppCoordinator(preferences:preferences,provider:.codex)
        delegate.hud.makePanel();delegate.menu.makeStatus();delegate.hud.interactionMenuOpen=true
        defer{delegate.settingsWindow?.close();delegate.hud.popover.close();NSStatusBar.system.removeStatusItem(delegate.menu.status)}
        check(Product.name=="Agent Stats","all providers share a single product identity")
        check(delegate.followsActiveTool,"the unified app defaults to following the foreground tool")
        let codexModules=[HUDModule(metric:.speed),HUDModule(metric:.modelTime)]
        let kimiModules=[HUDModule(metric:.usage),HUDModule(metric:.latency)]
        let layouts:[StatsProvider:[HUDModule]]=[.codex:codexModules,.kimi:kimiModules]
        let modes:[StatsProvider:StatsDisplayMode]=[.codex:.floating,.kimi:.menuBar]
        for provider in StatsProvider.allCases {
            delegate.switchProvider(provider)
            delegate.selected="shared-id";delegate.modules=layouts[provider]!
            delegate.displayMode=modes[provider]!
            delegate.hudHidden=provider == .kimi
        }
        // Expanded detail rows are stored per tool, like modules and selection.
        delegate.switchProvider(.codex);delegate.editDetailRow("usage.cacheRead",enabled:false)
        delegate.switchProvider(.kimi);delegate.editDetailRow("usage.cacheRead",enabled:true)
        check(!AppCoordinator(preferences:preferences,provider:.codex).detailRowKeys.contains("usage.cacheRead") && AppCoordinator(preferences:preferences,provider:.kimi).detailRowKeys.contains("usage.cacheRead"),"expanded detail rows are stored per tool")
        let codexDetail=MetricPresenter(provider:.codex,record:StatsRecord(["totalTokens":10,"cacheRead":5]),detailKeys:AppCoordinator(preferences:preferences,provider:.codex).detailRowKeys)
        check(delegate.detailRowKeys.contains("usage.cacheRead") && !codexDetail.content("usage").0.map(\.0).contains("缓存读取"),"the active tool keeps its own enabled detail rows")
        check(!codexDetail.content("usage").0.map(\.0).contains("上下文长度") && delegate.metrics.content("usage").0.isEmpty,"another tool's rows never render, and an unknown session keeps the card empty")
        check(!delegate.followsActiveTool,"a manual tool choice turns off automatic tool switching")
        for provider in StatsProvider.allCases {
            delegate.switchProvider(provider)
            check(delegate.modules==layouts[provider]! && delegate.displayMode==modes[provider]!,"tool switching restores its own layout and presentation")
            check(delegate.hudHidden==(provider == .kimi) && delegate.selected=="shared-id","tool switching preserves visibility and the selected session separately")
            check(delegate.sessions.isEmpty && delegate.current==nil && delegate.observedWindow==nil && delegate.hud.retainedHost==nil,"a new tool never inherits the previous catalog, values or host window")
            check(delegate.kimiSelection["sessionId"]==nil && delegate.nativeSelection["known"] as? Bool==false,"switching clears page bridge and native selection state")
            check(!delegate.hud.panel.isVisible && delegate.hud.panel.level == .normal && delegate.hud.popover.window.level == .normal,"a tool switch clears the host overlay until the next verified host")
            let restored=AppCoordinator(preferences:preferences)
            check(restored.activeProvider==provider.rawValue && restored.modules==layouts[provider]!,"the last selected tool and its module identities survive app restart")
        }
        delegate.switchProvider(.codex)
        let generation=delegate.readerGeneration
        let oldWindow=HostWindowReference(pid:1,number:70,bounds:CGRect(x:0,y:0,width:900,height:650))
        delegate.observeWindow(oldWindow)
        delegate.receive(["provider":"codex","sessions":[["id":"shared-id","title":"Codex 会话","totalTokens":12]]],generation:generation)
        check(delegate.current?["totalTokens"] as? Int==12,"the active collector can publish native integer statistics")
        delegate.kimiSelection=["status":"connected","known":true,"sessionId":"shared-id"]
        delegate.nativeSelection=CurrentSession(.current,id:"shared-id",window:oldWindow.token).json
        delegate.hud.panel.setHostOverlayActive(true)
        delegate.switchProvider(.kimi)
        check(delegate.readerGeneration != generation && delegate.current==nil,"switching invalidates in-flight collector callbacks immediately")
        delegate.receive(["provider":"codex","sessions":[["id":"shared-id","totalTokens":999]],"kimiSelection":["status":"connected","known":true,"sessionId":"stale"],"nativeSelection":CurrentSession(.current,id:"shared-id",window:oldWindow.token).json],generation:generation)
        check(delegate.sessions.isEmpty && delegate.current==nil && delegate.kimiSelection["sessionId"]==nil,"late callbacks cannot restore another tool's catalog or selection")
        delegate.receive(["provider":"codex","sessions":[["id":"shared-id","totalTokens":999]]])
        check(delegate.sessions.isEmpty,"provider identity rejects snapshots even without a generation token")
        delegate.receive(["provider":"kimi","sessions":[["id":"shared-id","title":"Kimi 会话","totalTokens":42]]],generation:delegate.readerGeneration)
        check(delegate.current?["totalTokens"] as? Int==42,"identical session IDs in different tools stay isolated")
        delegate.switchProvider(.codex)
        delegate.receive(["provider":"codex","sessions":[["id":"shared-id","totalTokens":999]]],generation:generation)
        check(delegate.sessions.isEmpty,"a round trip back to the same tool still rejects its previous collector generation")
        delegate.receive(["provider":"codex","sessions":[["id":"shared-id","totalTokens":24]]],generation:delegate.readerGeneration)
        check(delegate.current?["totalTokens"] as? Int==24,"the new collector generation remains usable after the round trip")
        delegate.receive(["provider":"codex","error":"stale collector error"],generation:generation)
        check(delegate.current?["totalTokens"] as? Int==24 && delegate.errorText==nil,"a late collector error cannot clear the active collector's values")
        delegate.receive(["provider":"codex","error":"test database unavailable"],generation:delegate.readerGeneration)
        check(delegate.sessions.isEmpty && delegate.current==nil && delegate.errorText=="test database unavailable","an active read failure clears stale measurements immediately")
        delegate.receive(["provider":"codex","sessions":[["id":"shared-id","totalTokens":30]]],generation:delegate.readerGeneration)
        check(delegate.current?["totalTokens"] as? Int==30 && delegate.errorText==nil,"a successful read recovers cleanly after a temporary database failure")
        delegate.followsActiveTool=true;delegate.switchProvider(.kimi,manual:false)
        check(delegate.followsActiveTool,"foreground-driven switches preserve automatic tool following")
        delegate.showSettings()
        let settings=delegate.settingsWindow!,settingsWindow=settings.window!
        func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap{descendants($0)}}
        for provider in StatsProvider.allCases {
            let picker=descendants(settingsWindow.contentView!).first{$0.identifier?.rawValue=="settings-provider"} as! NSPopUpButton
            guard let item=picker.itemArray.first(where:{$0.representedObject as? String==provider.rawValue}) else{preconditionFailure("missing tool in unified settings")}
            picker.select(item)
            check(NSApp.sendAction(picker.action!,to:picker.target,from:picker),"the settings tool picker dispatches a native action")
            check(delegate.activeProvider==provider.rawValue && delegate.settingsWindow===settings && settingsWindow.isVisible,"switching tools reuses the one settings window")
            check(delegate.modules==layouts[provider]!,"settings tool selection preserves each provider's configured module identities")
        }
        print("\(checks) unified provider isolation checks passed")
    }

}
