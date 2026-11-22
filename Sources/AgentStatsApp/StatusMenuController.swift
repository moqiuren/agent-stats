import StatsCore
import StatsAdapters
import AppKit

final class StatusMenuController: NSObject, NSMenuDelegate, NSMenuItemValidation {
  private weak var app: AppCoordinator?
  private let stats: StatsState
  private let configuration: StatsPreferencesStore
  init(app: AppCoordinator) {
    self.app = app
    stats = app.stats
    configuration = app.configuration
    super.init()
  }
  var status: NSStatusItem!
  var visibilityMenuItem: NSMenuItem?, conversationMenuItem: NSMenuItem?
  var metricMenuItems = [String: NSMenuItem]()
  private var provider: StatsProvider { stats.provider }
  private var activeProvider: String { provider.rawValue }
  private var followsActiveTool: Bool { configuration.followsActiveTool }
  private var displayMode: StatsDisplayMode { configuration.displayMode(for: provider) }
  private var hudHidden: Bool { configuration.hudHidden(for: provider) }
  private var selectionMode: SessionSelectionMode {
    SessionSelectionMode.resolve(
      configuration.selectedSession(for: provider), provider: activeProvider)
  }
  private var scopeText: String { app?.scopeText ?? "" }
  private var modules: [HUDModule] { configuration.modules(for: provider) }
  private var moduleButtons: [String: NSButton] { app?.hud.moduleButtons ?? [:] }
  private var projectGroups: [JSONObject] { stats.navigationGroups.map(\.json) }
  private var metrics: MetricPresenter {
    app?.metrics ?? MetricPresenter(provider: provider, record: stats.current)
  }
  var statusItemShouldBeVisible: Bool { !configuration.statusItemHidden || displayMode == .menuBar }
  func updateStatusItemVisibility() {
    guard let status else { return }
    let visible = statusItemShouldBeVisible
    if status.isVisible != visible { status.isVisible = visible }
  }
  func rebuild() {
    if status != nil {
      status.menu = makeStatusMenu()
      updateStatusPresentation()
      updateStatusItemVisibility()
    }
  }
  func removeStatusItem() {
    if let status { NSStatusBar.system.removeStatusItem(status) }
    status = nil
  }
  func updateVisibilityTitle() { visibilityMenuItem?.title = hudHidden ? "显示悬浮条" : "隐藏悬浮条" }
  private func metricTitle(_ metric: HUDMetric, inventory: AgentInventory? = nil) -> String
  { metrics.title(metric, inventory: inventory) }
  private func sessionModes() -> [InspectorChoice] { app?.sessionModes() ?? [] }
  private func conversationChoices(in project: String) -> [InspectorChoice] {
    app?.conversationChoices(in: project) ?? []
  }
  @objc func selectProvider(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String, let provider = StatsProvider(rawValue: raw)
    else { return }
    app?.selectProvider(provider)
  }
  @objc func enableToolFollowing() { app?.enableToolFollowing() }
  @objc func selectDisplayMode(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String, let mode = StatsDisplayMode(rawValue: raw)
    else { return }
    app?.setDisplayMode(mode)
  }
  @objc func toggle() { app?.toggle() }
  @objc func toggleIdleSink() { app?.setHUDIdleSink(!configuration.hudIdleSink) }
  @objc func showSettings() { app?.showSettings() }
  @objc func checkUpdatesFromMenu() { app?.checkForUpdatesAndShowAbout() }
  @objc func authorizeWindowRecognition() { app?.authorizeWindowRecognition() }
  @objc func quit() { NSApp.terminate(nil) }
  func makeStatus() {
    status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    status.button?.image = NSImage(
      systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: Product.name)
    status.button?.image?.isTemplate = true
    status.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    status.menu = makeStatusMenu()
    updateStatusPresentation()
    updateStatusItemVisibility()
  }
  func makeStatusMenu() -> NSMenu {
    let menu = NSMenu()
    conversationMenuItem = nil
    visibilityMenuItem = nil
    metricMenuItems.removeAll()
    func item(_ title: String, _ action: Selector?) -> NSMenuItem {
      let result = NSMenuItem(title: title, action: action, keyEquivalent: "")
      result.target = self
      return result
    }
    let tool = item("工具：" + provider.name, nil)
    let providers = NSMenu(title: "Agent 工具")
    let automatic = item("跟随当前工具", #selector(enableToolFollowing))
    automatic.state = followsActiveTool ? .on : .off
    providers.addItem(automatic)
    providers.addItem(.separator())
    for provider in StatsProvider.allCases {
      let choice = item(provider.name, #selector(selectProvider(_:)))
      choice.representedObject = provider.rawValue
      choice.state = provider.rawValue == activeProvider ? .on : .off
      providers.addItem(choice)
    }
    tool.submenu = providers
    menu.addItem(tool)
    menu.addItem(.separator())
    let conversation = item("选择对话", nil)
    conversation.toolTip = scopeText
    conversation.state = conversationItemState
    conversationMenuItem = conversation
    conversation.submenu = makeSessionMenu()
    menu.addItem(conversation)
    let metrics = item("指标设置", nil)
    metrics.submenu = makeMetricSettingsMenu()
    menu.addItem(metrics)
    menu.addItem(.separator())
    if displayMode == .menuBar {
      for module in modules {
        let metric = item(
          metricTitle(module.metric), #selector(showStatusMetric(_:)))
        metric.representedObject = module.metric.rawValue
        metric.toolTip = moduleButtons[module.id]?.toolTip
        metricMenuItems[module.id] = metric
        menu.addItem(metric)
      }
      if !modules.isEmpty { menu.addItem(.separator()) }
    } else {
      let visibility = item(hudHidden ? "显示悬浮条" : "隐藏悬浮条", #selector(toggle))
      visibilityMenuItem = visibility
      menu.addItem(visibility)
      let idleSink = item("闲置后下沉", #selector(toggleIdleSink))
      idleSink.state = configuration.hudIdleSink ? .on : .off
      idleSink.toolTip = "约 \(Int(HUDIdleSink.delay)) 秒未操作后隐去悬浮条背景；指针移入即浮现。"
      menu.addItem(idleSink)
      if app?.isAccessibilityAuthorized == false {
        menu.addItem(item("授权辅助功能以显示悬浮条…", #selector(authorizeWindowRecognition)))
      }
    }
    let presentation = item("展示模式", nil)
    let modes = NSMenu(title: "展示模式")
    for mode in StatsDisplayMode.allCases {
      let choice = item(mode.title, #selector(selectDisplayMode(_:)))
      choice.representedObject = mode.rawValue
      choice.state = mode == displayMode ? .on : .off
      modes.addItem(choice)
    }
    presentation.submenu = modes
    menu.addItem(presentation)
    let settings = item("设置…", #selector(showSettings))
    settings.keyEquivalent = ","
    menu.addItem(settings)
    let updateTitle: String
    switch app?.updateState {
    case .downloaded(let release, _):
      updateTitle = "重启以更新至 v\(release.version)…"
    case .available(let release, _):
      updateTitle = "发现新版本 v\(release.version)…"
    default:
      updateTitle = "检查更新…"
    }
    menu.addItem(item(updateTitle, #selector(checkUpdatesFromMenu)))
    menu.addItem(.separator())
    let help = item("使用说明", nil)
    help.submenu = makeHelpMenu()
    menu.addItem(help)
    menu.addItem(item("退出 " + Product.name, #selector(quit)))
    return menu
  }
  func menuBarTitle(maxWidth: CGFloat = 360, inventory: AgentInventory? = nil) -> String {
    let labels = modules.map { metricTitle($0.metric, inventory: inventory) }
    var title = ""
    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    for (index, label) in labels.enumerated() {
      let next = title + "  " + label
      let reserved = index < labels.count - 1 ? "  …" : ""
      if ((next + reserved) as NSString).size(withAttributes: [.font: font]).width > maxWidth {
        return title + "  …"
      }
      title = next
    }
    return title
  }
  /// In automatic and recent modes nothing inside the submenu identifies the
  /// conversation being displayed, so the parent item and the matching row carry a
  /// checkmark. A fixed selection already marks its own row.
  private var conversationItemState: NSControl.StateValue {
    let followed = selectionMode == .automatic || selectionMode == .recent
    return followed && stats.current != nil ? .on : .off
  }
  func updateStatusPresentation() {
    guard let button = status?.button else { return }
    conversationMenuItem?.toolTip = scopeText
    conversationMenuItem?.state = conversationItemState
    if displayMode == .floating {
      button.title = ""
      button.setAccessibilityLabel(Product.name)
      button.toolTip = Product.name + " · 悬浮条模式\n" + SessionTitle.singleLine(scopeText)
      return
    }
    let screenWidth = button.window?.screen?.frame.width ?? NSScreen.main?.frame.width ?? 1440
    let inventory = AgentInventory(stats.current?.values)
    button.title = menuBarTitle(
      maxWidth: min(360, max(100, screenWidth * 0.28)), inventory: inventory)
    let details = modules.compactMap { moduleButtons[$0.id]?.accessibilityLabel() }.joined(
      separator: "\n")
    button.toolTip =
      Product.name + " · 菜单栏模式\n" + scopeText + (details.isEmpty ? "" : "\n" + details)
    button.setAccessibilityLabel(
      Product.name + "，" + scopeText + "，" + details.replacingOccurrences(of: "\n", with: "，"))
    for module in modules {
      metricMenuItems[module.id]?.title = metricTitle(
        module.metric, inventory: inventory)
      metricMenuItems[module.id]?.toolTip = moduleButtons[module.id]?.toolTip
    }
  }
  // Both commands are ordinary native submenus. Contents are filled from live
  // state when the menu bar opens them, so a hover-opened list is never stale and
  // no custom panel is needed at either level.
  // A native menu sizes itself to its widest and tallest content, so unbounded
  // titles or conversation lists would stretch it across the screen. Titles are
  // shortened to one bounded line (the complete name stays in the tooltip), and a
  // long list falls back to the settings window instead of growing without limit.
  static let menuTitleWidth: CGFloat = 240
  // A native menu scrolls when it is taller than the screen, so these are only a
  // guard against pathological catalogs: real projects list every conversation and
  // are browsed by scrolling, never by opening the settings window.
  static let menuSessionLimit = 200
  static let menuProjectLimit = 60
  func menuTitle(_ text: String) -> String {
    let single = SessionTitle.singleLine(text)
    let font = NSFont.menuFont(ofSize: 0)
    func width(_ value: String) -> CGFloat {
      (value as NSString).size(withAttributes: [.font: font]).width
    }
    guard width(single) > Self.menuTitleWidth else { return single }
    var trimmed = single
    while !trimmed.isEmpty, width(trimmed + "…") > Self.menuTitleWidth { trimmed.removeLast() }
    return trimmed + "…"
  }
  func menuItem(_ title: String, _ action: Selector?, _ represented: Any? = nil) -> NSMenuItem {
    let entry = NSMenuItem(title: menuTitle(title), action: action, keyEquivalent: "")
    entry.target = self
    entry.representedObject = represented
    return entry
  }
  func makeSessionMenu() -> NSMenu {
    let menu = NSMenu(title: "选择对话")
    menu.identifier = NSUserInterfaceItemIdentifier(Self.sessionMenuIdentifier)
    menu.delegate = self
    populateSessionMenu(menu)
    return menu
  }
  func makeMetricSettingsMenu() -> NSMenu {
    let menu = NSMenu(title: "指标设置")
    menu.identifier = NSUserInterfaceItemIdentifier(Self.metricSettingsMenuIdentifier)
    menu.delegate = self
    populateMetricSettingsMenu(menu)
    return menu
  }
  static let sessionMenuIdentifier = "stats-session-menu",
    metricSettingsMenuIdentifier = "stats-metric-settings-menu"
  static let helpMenuIdentifier = "stats-help-menu"
  // The help submenu lists the categories only; choosing one opens that category
  // in the settings window. No web page is ever opened.
  func makeHelpMenu() -> NSMenu {
    let menu = NSMenu(title: "使用说明")
    menu.identifier = NSUserInterfaceItemIdentifier(Self.helpMenuIdentifier)
    menu.delegate = self
    populateHelpMenu(menu)
    return menu
  }
  func populateHelpMenu(_ menu: NSMenu) {
    menu.removeAllItems()
    for category in HelpDocs.categories(for: provider) {
      menu.addItem(menuItem(category.title, #selector(showHelpCategory(_:)), category.id))
    }
    menu.addItem(.separator())
    menu.addItem(menuItem("在设置中查看…", #selector(showHelpSettings)))
  }
  static let sessionGroupPrefix = "stats-session-project:"
  func menuNeedsUpdate(_ menu: NSMenu) {
    switch menu.identifier?.rawValue ?? "" {
    case Self.sessionMenuIdentifier: populateSessionMenu(menu)
    case Self.metricSettingsMenuIdentifier: populateMetricSettingsMenu(menu)
    case Self.helpMenuIdentifier: populateHelpMenu(menu)
    case let value where value.hasPrefix(Self.sessionGroupPrefix):
      populateSessionGroup(menu, project: String(value.dropFirst(Self.sessionGroupPrefix.count)))
    default: break
    }
  }
  func populateSessionMenu(_ menu: NSMenu) {
    menu.removeAllItems()
    for mode in sessionModes() where mode.id != "__current__" || provider.supportsAutomaticSessionFollow {
      let entry = menuItem(
        mode.title, #selector(pickMenuSession(_:)),
        StatsSessionMenuItem(project: nil, session: mode.id))
      entry.state = mode.selected ? .on : .off
      entry.isEnabled = mode.enabled
      menu.addItem(entry)
    }
    menu.addItem(.separator())
    let groups = projectGroups
    let listed = Array(groups.prefix(Self.menuProjectLimit))
    for group in listed {
      let id = identifier(group["id"])
      let title = identifier(group["title"])
      let parent = menuItem(title, nil)
      parent.toolTip = title
      let submenu = NSMenu(title: title)
      submenu.identifier = NSUserInterfaceItemIdentifier(Self.sessionGroupPrefix + id)
      submenu.delegate = self
      parent.submenu = submenu
      menu.addItem(parent)
    }
    if groups.count > listed.count {
      menu.addItem(menuItem("还有 \(groups.count-listed.count) 个项目…", nil))
    }
    menu.addItem(.separator())
    menu.addItem(menuItem("在设置中选择…", #selector(showSessionSettings)))
  }
  func populateSessionGroup(_ menu: NSMenu, project: String) {
    menu.removeAllItems()
    let choices = conversationChoices(in: project)
    guard !choices.isEmpty else {
      let empty = NSMenuItem(title: "该项目暂无对话", action: nil, keyEquivalent: "")
      empty.isEnabled = false
      menu.addItem(empty)
      return
    }
    // Conversations arrive most-recent-first, so the cap keeps the newest ones.
    let listed = Array(choices.prefix(Self.menuSessionLimit))
    for choice in listed {
      let entry = menuItem(
        choice.title, #selector(pickMenuSession(_:)),
        StatsSessionMenuItem(project: project, session: choice.id))
      entry.state = choice.selected ? .on : .off
      entry.toolTip = choice.selected ? "当前显示的对话：" + choice.title : choice.title
      menu.addItem(entry)
    }
    guard choices.count > listed.count else { return }
    // Beyond the guard cap the native menu can no longer be scrolled to the end, so
    // the settings window takes over the remainder.
    menu.addItem(.separator())
    let more = NSMenuItem(
      title: "还有 \(choices.count-listed.count) 个对话…", action: nil, keyEquivalent: "")
    more.isEnabled = false
    menu.addItem(more)
    menu.addItem(menuItem("在设置中查看该项目…", #selector(showProjectSettings(_:)), project))
  }
  func populateMetricSettingsMenu(_ menu: NSMenu) {
    menu.removeAllItems()
    let configured = Set(modules.map(\.metric))
    var group: String?
    for metric in HUDMetric.available(for: activeProvider) {
      if let current = group, current != metric.group { menu.addItem(.separator()) }
      group = metric.group
      let entry = menuItem(metric.label, #selector(toggleMenuMetric(_:)), metric.rawValue)
      entry.state = configured.contains(metric) ? .on : .off
      entry.toolTip = configured.contains(metric) ? "从悬浮条移除" : "添加到悬浮条"
      menu.addItem(entry)
    }
    menu.addItem(.separator())
    menu.addItem(menuItem("恢复默认指标", #selector(resetMenuMetrics)))
    menu.addItem(menuItem("在设置中编辑…", #selector(showMetricSettings)))
  }
  @objc func pickMenuSession(_ sender: NSMenuItem) {
    guard let choice = sender.representedObject as? StatsSessionMenuItem else { return }
    app?.pickSession(choice.session, project: choice.project)
  }
  @objc func toggleMenuMetric(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String, let metric = HUDMetric(rawValue: raw)
    else { return }
    if let module = modules.first(where: { $0.metric == metric }) {
      app?.editModules(.remove(module.id))
    } else {
      app?.editModules(.add(metric))
    }
  }
  @objc func resetMenuMetrics() { app?.editModules(.reset) }
  @objc func showSessionSettings() { app?.openSettingsPage(.sessions) }
  @objc func showProjectSettings(_ sender: NSMenuItem) {
    if let project = sender.representedObject as? String { app?.browseProject(project) }
    app?.openSettingsPage(.sessions)
  }
  @objc func showMetricSettings() { app?.openSettingsPage(.metrics) }
  @objc func showHelpSettings() { app?.showHelpSettings() }
  @objc func showHelpCategory(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else {
      app?.showHelpSettings()
      return
    }
    app?.showHelpCategory(id)
  }
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(selectDisplayMode(_:)) {
      menuItem.state = (menuItem.representedObject as? String) == displayMode.rawValue ? .on : .off
      return true
    }
    if menuItem.action == #selector(pickMenuSession(_:)) {
      let session = (menuItem.representedObject as? StatsSessionMenuItem)?.session
      return session != "__current__" || stats.canFollowCurrentConversation
    }
    if menuItem.action == #selector(authorizeWindowRecognition) {
      menuItem.isHidden = app?.isAccessibilityAuthorized == true
      menuItem.toolTip = "用于识别宿主主窗口，在系统设置中管理授权。"
    }
    return true
  }
  @objc func showStatusMetric(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String, let metric = HUDMetric(rawValue: raw),
      let anchor = status?.button
    else { return }
    if metric == .subagents {
      app?.hud.showAgentInspector(anchor: anchor)
      return
    }
    let group = metric.group
    let title = metric.definition.group.title
    app?.hud.showMetric(group, title: title, anchor: anchor)
  }
  func makeApplicationMenu() {
    let menu = NSMenu()
    let app = NSMenuItem()
    let commands = NSMenu(title: Product.name)
    let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
    settings.target = self
    commands.addItem(settings)
    let checkUpdates = NSMenuItem(
      title: "检查更新…", action: #selector(checkUpdatesFromMenu), keyEquivalent: "")
    checkUpdates.target = self
    commands.addItem(checkUpdates)
    commands.addItem(.separator())
    commands.addItem(
      withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    let quit = NSMenuItem(title: "退出 " + Product.name, action: #selector(quit), keyEquivalent: "q")
    quit.target = self
    commands.addItem(quit)
    app.submenu = commands
    menu.addItem(app)
    let edit = NSMenuItem()
    let editing = NSMenu(title: "编辑")
    for (title, action, key) in [
      ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"),
      ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a"),
    ] {
      editing.addItem(withTitle: title, action: action, keyEquivalent: key)
    }
    edit.submenu = editing
    menu.addItem(edit)
    // Help lives in the settings window now; the standard app-menu entry
    // opens that page instead of a web page.
    let helpEntry = NSMenuItem(title: "帮助", action: #selector(showHelpSettings), keyEquivalent: "?")
    helpEntry.target = self
    menu.addItem(helpEntry)
    NSApp.mainMenu = menu
  }
}
