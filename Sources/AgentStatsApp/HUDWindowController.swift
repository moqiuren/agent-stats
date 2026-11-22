import StatsCore
import StatsAdapters
import AppKit
import CoreGraphics
import QuartzCore

// The floating bar is a single horizontal strip. It follows the verified host
// window, repaints its metrics, opens a detail card and can be dragged to a free
// position inside that window; it has no position menu and no docking.
final class HUDWindowController: NSObject {
  /// Leading inset, grip, gap, metric run and trailing inset. `metricStripWidth`
  /// is exactly the width the metric buttons occupy, so the bar never has to scroll
  /// at its preferred size and no scroller can ever cover the values.
  /// The bar has no grip: it is dragged directly, so only a small inset and the gap
  /// between metric values are reserved.
  static let barInset: CGFloat = 6, metricGap: CGFloat = 4
  /// A deliberately slim strip: 20pt of values with 4pt of glass above and below.
  static let metricHeight: CGFloat = 20
  static let barHeight: CGFloat = metricHeight + 8
  private weak var app: AppCoordinator?
  private let stats: StatsState
  private let configuration: StatsPreferencesStore
  private let scheduler: StatsScheduling
  init(app: AppCoordinator, scheduler: StatsScheduling, hostMonitor: HostWindowMonitoring) {
    self.scheduler = scheduler; hostWindowMonitor = hostMonitor
    self.app = app
    stats = app.stats
    configuration = app.configuration
    super.init()
  }
  var panel: HUDPanel!
  let popover = HUDInspector()
  let hostWindowMonitor: HostWindowMonitoring
  var retainedHost: HostWindowReference?
  var lastRect: NSRect?
  let metricScroll = HUDMetricScrollView(), metricDocument = FlippedContent()
  /// The native proof is asynchronous and is re-armed whenever the window list or the
  /// focus requirement changes, so single unverified passes are normal. Keeping the
  /// last verified geometry for a short grace prevents the bar from blinking out and
  /// back while nothing about the host actually changed.
  var verifiedHostNumber: UInt32?
  var verifiedHostAt = Date.distantPast
  /// Set while follow() is deliberately paused for a drag or menu tracking. The
  /// verification is not refreshed then, so the grace is restarted from the moment
  /// work resumes instead of from the last proof.
  var followPausedAt: Date?
  var motionTimer: StatsCancellation?
  var hostMotionAt: Date?
  var hostGeometryChangedAt = Date.distantPast
  static let motionInterval: TimeInterval = 1.0 / 120, motionIdle: TimeInterval = 0.3
  /// Injectable for tests.
  var pointerHeld: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
  var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
  var hostFrameSource: ((UInt32, Int32) -> NSRect?)?
  var lastHUDActivity = Date()
  private(set) var isSunk = false
  var isDragging = false
  var dragOrigin = NSRect.zero, dragPointer = CGPoint.zero, dragHost = NSRect.zero
  var interactionMenuOpen = false
  var moduleButtons = [String: NSButton]()
  var agentInspectorState = AgentInspectorState()
  private var timer: StatsCancellation?
  private var menuObservers = [NSObjectProtocol]()
  private var localMouseMonitor: Any?, globalMouseMonitor: Any?, escapeMonitor: Any?
  private var provider: StatsProvider { stats.provider }
  private var activeProvider: String { provider.rawValue }
  private var hostBundleID: String { provider.hostBundleID }
  private var bundleID: String { Product.bundleID }
  private var selectionMode: SessionSelectionMode {
    SessionSelectionMode.resolve(
      configuration.selectedSession(for: provider), provider: activeProvider)
  }
  private var displayMode: StatsDisplayMode { configuration.displayMode(for: provider) }
  private var hudHidden: Bool { configuration.hudHidden(for: provider) }
  private var scopeText: String { app?.scopeText ?? "" }
  private var modules: [HUDModule] { configuration.modules(for: provider) }
  private var status: NSStatusItem? { app?.menu.status }
  private var metrics: MetricPresenter {
    app?.metrics ?? MetricPresenter(provider: provider, record: stats.current)
  }
  private var hostWindowCount: Int {
    get { stats.hostWindowCount }
    set { stats.hostWindowCount = newValue }
  }
  var placement: HUDPlacement {
    var value = configuration.placement(for: provider)
    value.moduleCount = modules.count
    value.contentSize = preferredHUDSize()
    return value
  }
  func clearHost() {
    retainedHost = nil
    lastRect = nil
  }
  func preparePresentationChange() {
    stopHostMotionTracking()
    endHUDDrag(commit: false)
    popover.close()
    panel?.orderOut(nil)
    panel?.setHostOverlayActive(false)
    lastHUDActivity = Date()
    setSunk(false, animated: false)
  }
  func prepareProviderChange() {
    preparePresentationChange()
    hostWindowMonitor.reset()
  }
  func modulesDidChange() {
    noteHUDActivity()
    applyModules()
    popover.refreshCustomBody()
    if displayMode == .floating, let host = lastRect {
      panel.setFrame(placement.frame(host: host, screen: visibleScreen(for: host)), display: true)
    }
    positionInspector()
  }
  func stopMonitoring() {
    stopHostMotionTracking()
    timer?.cancel()
    timer = nil
    for monitor in [localMouseMonitor, globalMouseMonitor, escapeMonitor].compactMap({ $0 }) {
      NSEvent.removeMonitor(monitor)
    }
    localMouseMonitor = nil
    globalMouseMonitor = nil
    escapeMonitor = nil
    for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
    menuObservers.removeAll()
  }
  func close() {
    stopMonitoring()
    popover.close()
    panel?.close()
    panel = nil
  }
  func startMonitoring() {
    menuObservers = [
      NotificationCenter.default.addObserver(
        forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
      ) { [weak self] _ in self?.interactionMenuOpen = true },
      NotificationCenter.default.addObserver(
        forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
      ) { [weak self] _ in self?.interactionMenuOpen = false },
    ]
    localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [
      .leftMouseDown, .rightMouseDown,
    ]) { [weak self] event in
      guard let self else { return event }
      if event.window === self.panel || event.window === self.popover.window {
        self.noteHUDActivity()
      } else if !self.interactionMenuOpen {
        self.popover.close()
      }
      return event
    }
    globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [
      .leftMouseDown, .rightMouseDown,
    ]) { [weak self] event in
      guard let self else { return }
      self.popover.close()
      // This monitor sees every click anywhere. A click outside the host and this app
      // cannot change host validation, so the two verification passes below are skipped
      // rather than run for unrelated windows.
      let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
      guard front == self.hostBundleID || front == self.bundleID else { return }
      // Recheck focus and auxiliary windows both now and after the host processes
      // the click, so a newly opened dialog need not wait for the polling tick.
      self.follow()
      self.scheduler.execute { [weak self] in self?.follow() }
      if event.type == .leftMouseDown, front == self.hostBundleID {
        self.startHostMotionTracking()
      }
    }
    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if event.keyCode == 53, self?.isDragging == true {
        self?.endHUDDrag(commit: false)
        return nil
      }
      if event.keyCode == 53, self?.popover.isShown == true, self?.interactionMenuOpen == false {
        self?.popover.close()
        return nil
      }
      return event
    }
    timer = scheduler.schedule(after: 0.1, repeating: 0.1, tolerance: 0.05) { [weak self] in
      self?.follow()
    }
    // The follow loop only has to feel immediate. A tolerance lets the system coalesce
    // these wakeups with other timers instead of waking the app ten times a second.
    follow()
  }
  func button(_ title: String, _ action: Selector) -> NSButton {
    let b = NSButton(title: title, target: self, action: action)
    b.bezelStyle = .recessed
    b.isBordered = false
    b.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    b.setContentHuggingPriority(.required, for: .horizontal)
    return b
  }
  func makePanel() {
    panel = HUDPanel(
      contentRect: NSRect(x: 100, y: 100, width: 540, height: 28),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.title = Product.name + " · 悬浮统计"
    panel.isFloatingPanel = false
    panel.level = .normal
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    let glass = HUDContentView(frame: .zero)
    glass.wantsLayer = true
    glass.layer?.cornerRadius = 12
    glass.layer?.masksToBounds = true
    glass.backdrop.material = .popover
    glass.backdrop.blendingMode = .behindWindow
    glass.backdrop.state = .active
    glass.backdrop.wantsLayer = true
    glass.backdrop.layer?.cornerRadius = 12
    // The material paints its own rectangle: without clipping, square corners show
    // past the rounded stroke as small wedges.
    glass.backdrop.layer?.masksToBounds = true
    glass.backdrop.layer?.borderWidth = 0.5
    glass.backdrop.layer?.borderColor = NSColor.separatorColor.cgColor
    metricScroll.drawsBackground = false
    metricScroll.borderType = .noBorder
    metricScroll.scrollerStyle = .overlay
    metricScroll.autohidesScrollers = true
    metricScroll.documentView = metricDocument
    glass.addSubview(metricScroll)
    wireDrag(glass)
    wireDrag(metricScroll)
    glass.onLayout = { [weak self] in self?.layoutHUD() }
    panel.contentView = glass
    applyModules()
  }
  /// Every surface of the bar forwards the same press/drag/click discrimination, so
  /// the bar can be moved directly from its values and from its background.
  func wireDrag(_ surface: HUDDragSurface) {
    surface.drag.onBegin = { [weak self] point in
      self?.noteHUDActivity()
      self?.beginHUDDrag(at: point)
    }
    surface.drag.onMove = { [weak self] point in self?.moveHUDDrag(to: point) }
    surface.drag.onEnd = { [weak self] moved in
      self?.endHUDDrag(commit: moved)
      self?.noteHUDActivity()
      self?.follow()
    }
  }
  /// Recheck the visible host, then keep the dragged position inside it. The bar
  /// never changes shape, so the grabbed point stays under the pointer.
  func beginHUDDrag(at pointer: CGPoint) {
    guard let host = lastRect else { return }
    stopHostMotionTracking()
    popover.close()
    isDragging = true
    dragHost = host
    dragPointer = pointer
    dragOrigin = panel.frame
  }
  func moveHUDDrag(to pointer: CGPoint) {
    guard isDragging else { return }
    let area = HUDPlacement.container(host: dragHost, screen: dragScreen())
    let proposed = dragOrigin.offsetBy(dx: pointer.x - dragPointer.x, dy: pointer.y - dragPointer.y)
    panel.setFrame(HUDPlacement.clamp(proposed, to: area), display: true)
  }
  func endHUDDrag(commit: Bool) {
    guard isDragging else { return }
    isDragging = false
    if commit, lastRect != nil {
      var value = placement
      value.recordDrag(frame: panel.frame, host: dragHost, screen: dragScreen())
      configuration.setPlacement(value, for: provider)
    }
    if let host = lastRect {
      panel.setFrame(placement.frame(host: host, screen: visibleScreen(for: host)), display: true)
    }
    app?.refreshSettings()
  }
  func dragScreen() -> NSRect { visibleScreen(for: dragHost) }
  func applyModules() {
    let configured = modules
    let ids = Set(configured.map(\.id))
    for id in Array(moduleButtons.keys) where !ids.contains(id) {
      moduleButtons.removeValue(forKey: id)?.removeFromSuperview()
    }
    for module in configured where moduleButtons[module.id] == nil {
      let b = HUDMetricButton(title: "", target: self, action: #selector(showModule(_:)))
      b.identifier = NSUserInterfaceItemIdentifier(module.id)
      b.isBordered = false
      b.bezelStyle = .recessed
      b.setButtonType(.momentaryChange)
      wireDrag(b)
      moduleButtons[module.id] = b
      metricDocument.addSubview(b)
    }
    if let anchor = popover.anchor as? NSButton, anchor !== status?.button,
      !moduleButtons.values.contains(where: { $0 === anchor })
    {
      popover.close()
    }
    // A module added or replaced must show its current value immediately, not on the
    // next collection pass, so this repaints the rows before rebuilding the menu.
    updateBarTitles()
    app?.menu.rebuild()
  }
  func metricWidth(_ module: HUDModule) -> CGFloat {
    let title = metrics.title(module.metric)
    return max(
      76,
      ceil(
        (title as NSString).size(withAttributes: [
          .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        ]).width) + 16)
  }
  /// The metric run, in the exact width its buttons occupy.
  func metricStripWidth() -> CGFloat {
    modules.reduce(CGFloat(0)) { $0 + metricWidth($1) + Self.metricGap }
  }
  /// Only the grip and the metric strip are sized; no selector, menu or reserve.
  func preferredHUDSize() -> CGSize {
    CGSize(
      width: max(24, Self.barInset * 2 + metricStripWidth()), height: Self.barHeight)
  }
  func layoutHUD() {
    guard let glass = panel?.contentView else { return }
    let size = glass.bounds.size
    let configured = modules
    // No scroller is ever installed. A permanently visible horizontal scroller
    // shrinks the clip view under the "always show scroll bars" system setting and
    // cuts the metric values in half; wheel and trackpad scrolling are handled by
    // HUDMetricScrollView itself, and the bar is sized to fit whenever the host allows.
    let strip = metricStripWidth()
    metricScroll.hasVerticalScroller = false
    metricScroll.hasHorizontalScroller = false
    metricScroll.frame = NSRect(
      x: Self.barInset, y: (size.height - Self.metricHeight) / 2,
      width: max(0, size.width - Self.barInset * 2), height: Self.metricHeight)
    metricDocument.frame = NSRect(
      x: 0, y: 0, width: max(metricScroll.contentSize.width, strip),
      height: metricScroll.contentSize.height)
    var x: CGFloat = 0
    for module in configured {
      let width = metricWidth(module)
      moduleButtons[module.id]?.frame = NSRect(x: x, y: 0, width: width, height: Self.metricHeight)
      x += width + 4
    }
    metricScroll.isHidden = configured.isEmpty
    metricScroll.toolTip = "按住任意位置拖动即可移动悬浮条，位置按工具保存；轻点指标展开明细；滚动查看更多指标；在菜单栏的“指标设置…”中编辑。"
    metricScroll.reflectScrolledClipView(metricScroll.contentView)
  }
  func render(_ presentation: StatsPresentation) {
    guard panel != nil else { return }
    let followingCurrent = selectionMode == .automatic
    guard let record = presentation.record else {
      panel.contentView?.toolTip = followingCurrent ? "没有可靠会话 ID 时不显示其他对话的数据。" : "显示最近活跃或手动选择的会话。"
      updateBarTitles()
      panel.setAccessibilityLabel(provider.shortName + " · " + scopeText)
      refreshDetailCard()
      return
    }
    panel.contentView?.toolTip =
      "\(record.title)\n\(record.model ?? "未知模型")\n"
      + (followingCurrent ? "跟随当前窗口的会话标识。" : "手动选择或最近活跃会话。")
    updateBarTitles()
    panel.setAccessibilityLabel(
      "会话统计，" + scopeText + "，"
        + modules.compactMap { moduleButtons[$0.id]?.accessibilityLabel() }.joined(separator: "，"))
    refreshDetailCard()
  }
  /// Repaint the open detail card from the current record and row selection.
  func refreshDetailCard() {
    guard let kind = popover.kind, MetricRegistry.detailGroups.contains(kind) else { return }
    let content = metrics.content(kind)
    popover.update(rows: content.0, note: content.1)
  }
  func activeApplicationChanged(_ front: String?) {
    // `frontmostApplication` is nil during activation handoffs; that is unknown, not
    // another application, and must never hide the bar.
    if HUDHostContext.isActive(front: front, host: hostBundleID, selfBundle: bundleID) {
      follow()
      return
    }
    // A foreground change must hide the host overlay even during menu tracking or
    // dragging, when the regular positioning loop is deliberately paused.
    endHUDDrag(commit: false)
    hostWindowMonitor.reset()
    retainedHost = nil
    hostWindowCount = 0
    hideHUD()
  }
  func follow() {
    guard let app, panel != nil, !isDragging, !interactionMenuOpen else {
      if isDragging || interactionMenuOpen { followPausedAt = Date() }
      return
    }
    if let resumedAt = followPausedAt {
      if verifiedHostNumber != nil {
        verifiedHostAt = HUDVerificationGrace.resumedVerifiedAt(verifiedHostAt, pausedAt: resumedAt)
      }
      followPausedAt = nil
    }
    app.checkHookReport()
    app.checkPendingAccessibilityUpgrade()
    let frontApp = NSWorkspace.shared.frontmostApplication
    let front = frontApp?.bundleIdentifier
    if app.followsActiveTool, let next = StatsProvider.host(front), next != provider {
      app.switchProvider(next, manual: false)
    }
    let hosts = NSRunningApplication.runningApplications(withBundleIdentifier: hostBundleID)
    let host =
      front == hostBundleID
      ? frontApp : (hosts.first { $0.processIdentifier == retainedHost?.pid } ?? hosts.first)
    let allowed =
      HUDHostContext.isActive(front: front, host: hostBundleID, selfBundle: bundleID)
      || (front == bundleID && (panel.isKeyWindow || popover.window.isKeyWindow))
    if isStatusInspector {
      if app.paused { app.setCollectionPaused(false, refresh: true) }
      hostWindowMonitor.reset()
      retainedHost = nil
      hostWindowCount = 0
      hideHUD()
      positionInspector()
      return
    }
    let shouldPause = app.shouldPauseReader(hostAvailable: host != nil, hostOrStatsActive: allowed)
    if shouldPause != app.paused { app.setCollectionPaused(shouldPause) }
    if displayMode == .menuBar {
      panel.orderOut(nil)
      panel.setHostOverlayActive(false)
      positionInspector()
      if selectionMode != .automatic {
        hostWindowMonitor.reset()
        retainedHost = nil
        hostWindowCount = 0
        hideHUD()
        return
      }
    }
    guard displayMode == .menuBar || !hudHidden, allowed, let hostApplication = host else {
      hostWindowMonitor.reset()
      retainedHost = nil
      hostWindowCount = 0
      hideHUD()
      return
    }
    if displayMode == .floating {
      status?.button?.toolTip =
        Product.name + " · " + SessionTitle.singleLine(scopeText)
        + (app.isAccessibilityAuthorized ? " · 仅在已确认的主窗口显示" : " · 需要辅助功能权限识别主窗口：设置… → 会话与权限")
    }
    let windows =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    let matches = windows.filter {
      ($0[kCGWindowOwnerPID as String] as? Int) == Int(hostApplication.processIdentifier)
        && ($0[kCGWindowLayer as String] as? Int) == 0
        && (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0
    }
    let countChanged = hostWindowCount != matches.count
    hostWindowCount = matches.count
    if countChanged, selectionMode == .automatic { app.render() }
    let desktopTop = NSScreen.screens.first?.frame.maxY ?? 900
    let candidates = matches.compactMap { w -> HUDHostWindow? in
      guard let bounds = w[kCGWindowBounds as String] as? [String: CGFloat],
        let width = bounds["Width"], let height = bounds["Height"],
        let number = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value
      else { return nil }
      let cg = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: width, height: height)
      return HUDHostWindow(
        number: number, frame: HUDHostGeometry.appKitFrame(cg, desktopTop: desktopTop))
    }
    // Opening a HUD control must not switch to a different host window. Only the
    // host coming to the foreground can establish a new front-to-back target.
    let hudInteraction = front == bundleID || panel.isKeyWindow || popover.window.isKeyWindow
    let retained =
      hudInteraction && retainedHost?.pid == hostApplication.processIdentifier
      ? retainedHost?.number : nil
    let references = candidates.map {
      HostWindowReference(
        pid: hostApplication.processIdentifier, number: $0.number,
        bounds: HUDHostGeometry.appKitFrame($0.frame, desktopTop: desktopTop))
    }
    let verified = hostWindowMonitor.observe(
      windows: references, requireFocused: !hudInteraction, provider: activeProvider)
    let target =
      hudInteraction && retained == nil
      ? nil
      : HUDHostGeometry.select(
        candidates, screens: NSScreen.screens.map(\.visibleFrame), verifiedMain: verified,
        retaining: retained)
    if let window = target {
      let rect = window.frame
      let moved = noteHostGeometry(rect)
      retainedHost = HostWindowReference(
        pid: hostApplication.processIdentifier, number: window.number,
        bounds: HUDHostGeometry.appKitFrame(rect, desktopTop: desktopTop))
      app.observeWindow(retainedHost)
      verifiedHostNumber = window.number
      verifiedHostAt = Date()
      if displayMode == .menuBar {
        lastRect = rect
        return
      }
      let wasVisible = panel.isVisible
      panel.setHostOverlayActive(true)
      applyHostFrame(rect)
      let hostIndex = windows.firstIndex {
        ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == window.number
      }
      let panelIndex = windows.firstIndex {
        ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == panel.windowNumber
      }
      if HUDHostGeometry.needsOrdering(
        panelVisible: wasVisible, panelIndex: panelIndex, hostIndex: hostIndex)
      {
        panel.order(.above, relativeTo: Int(window.number))
      }
      if !wasVisible { noteHUDActivity() }
      if moved { startHostMotionTracking() }
      updateIdleSink()
      return
    }
    // No verified window this pass. While the host is still frontmost, its window is
    // still on screen and the bar is already visible, hold the current frame instead
    // of ordering the panel out and back in.
    if HUDVerificationGrace.holdsVisibleBar(
      hostContextActive: HUDHostContext.isActive(
        front: front, host: hostBundleID, selfBundle: bundleID),
      barVisible: panel.isVisible,
      verifiedNumber: verifiedHostNumber,
      verifiedAt: HUDVerificationGrace.resumedVerifiedAt(verifiedHostAt, pausedAt: hostMotionAt),
      now: Date(),
      windowStillOnScreen: verifiedHostNumber.map { number in
        candidates.contains { $0.number == number }
      } ?? false)
    {
      if displayMode == .floating, let number = verifiedHostNumber,
        let window = candidates.first(where: { $0.number == number }),
        window.frame != lastRect
      {
        _ = noteHostGeometry(window.frame)
        applyHostFrame(window.frame)
        startHostMotionTracking()
      }
      updateIdleSink()
      return
    }
    hideHUD()
  }
  func pointerNearBar() -> Bool {
    panel != nil && panel.isVisible && panel.frame.insetBy(dx: -6, dy: -6).contains(pointerLocation())
  }
  func noteHUDActivity() {
    lastHUDActivity = Date()
    setSunk(false, animated: true)
  }
  func updateIdleSink(now: Date = Date()) {
    guard panel != nil, displayMode == .floating, panel.isVisible else { return }
    let engaged = pointerNearBar() || popover.isShown || isDragging || interactionMenuOpen
    if engaged { lastHUDActivity = now }
    setSunk(
      HUDIdleSink.shouldSink(
        enabled: configuration.hudIdleSink, engaged: engaged, lastActivity: lastHUDActivity,
        now: now),
      animated: true)
  }
  func setSunk(_ sunk: Bool, animated: Bool) {
    guard let glass = panel?.contentView as? HUDContentView, sunk != isSunk else { return }
    isSunk = sunk
    let backdropAlpha: CGFloat = sunk ? 0 : 1
    let contentAlpha: CGFloat = sunk ? HUDIdleSink.sunkContentAlpha : 1
    if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      glass.backdrop.alphaValue = backdropAlpha
      metricScroll.alphaValue = contentAlpha
    } else {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = sunk ? 0.6 : 0.18
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glass.backdrop.animator().alphaValue = backdropAlpha
        metricScroll.animator().alphaValue = contentAlpha
      }
    }
    panel.hasShadow = !sunk
    panel.invalidateShadow()
  }
  func idleSinkPreferenceChanged() {
    noteHUDActivity()
  }
  func currentHostFrame(number: UInt32, pid: Int32) -> NSRect? {
    if let hostFrameSource { return hostFrameSource(number, pid) }
    let windows =
      CGWindowListCopyWindowInfo([.optionIncludingWindow], number) as? [[String: Any]] ?? []
    guard let w = windows.first,
      (w[kCGWindowOwnerPID as String] as? Int) == Int(pid),
      (w[kCGWindowLayer as String] as? Int) == 0,
      ((w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
      (w[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
      let bounds = w[kCGWindowBounds as String] as? [String: CGFloat],
      let width = bounds["Width"], let height = bounds["Height"]
    else { return nil }
    let cg = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: width, height: height)
    let desktopTop = NSScreen.screens.first?.frame.maxY ?? 900
    return HUDHostGeometry.appKitFrame(cg, desktopTop: desktopTop)
  }
  func applyHostFrame(_ rect: NSRect) {
    lastRect = rect
    let screen = visibleScreen(for: rect)
    let frame = placement.frame(host: rect, screen: screen)
    if panel.frame.size == frame.size {
      if panel.frame.origin != frame.origin { panel.setFrameOrigin(frame.origin) }
    } else {
      panel.setFrame(frame, display: true)
    }
    if popover.isShown {
      popover.position(host: rect, screen: screen, bar: panel.frame)
    }
  }
  @discardableResult
  func noteHostGeometry(_ rect: NSRect) -> Bool {
    let changed = lastRect != nil && lastRect != rect
    if changed {
      let now = Date()
      hostGeometryChangedAt = now
      hostMotionAt = HUDVerificationGrace.motionAt(
        previous: hostMotionAt, frameChanged: true, pointerHeld: pointerHeld(), now: now)
    }
    return changed
  }
  private var canTrackHostMotion: Bool {
    panel != nil && displayMode == .floating && panel.isVisible && verifiedHostNumber != nil
      && retainedHost != nil && lastRect != nil && !isDragging && !interactionMenuOpen
  }
  func startHostMotionTracking() {
    guard motionTimer == nil, canTrackHostMotion else { return }
    hostGeometryChangedAt = Date()
    motionTimer = scheduler.schedule(after: 0, repeating: Self.motionInterval, tolerance: 0) {
      [weak self] in
      self?.trackHostMotion()
    }
  }
  func stopHostMotionTracking() {
    motionTimer?.cancel()
    motionTimer = nil
  }
  func trackHostMotion() {
    guard canTrackHostMotion, let number = verifiedHostNumber, let retained = retainedHost else {
      stopHostMotionTracking()
      return
    }
    guard let rect = currentHostFrame(number: number, pid: retained.pid) else {
      stopHostMotionTracking()
      follow()
      return
    }
    if rect != lastRect {
      _ = noteHostGeometry(rect)
      let desktopTop = NSScreen.screens.first?.frame.maxY ?? 900
      retainedHost = HostWindowReference(
        pid: retained.pid, number: number,
        bounds: HUDHostGeometry.appKitFrame(rect, desktopTop: desktopTop))
      applyHostFrame(rect)
      return
    }
    if !pointerHeld(), Date().timeIntervalSince(hostGeometryChangedAt) >= Self.motionIdle {
      stopHostMotionTracking()
    }
  }
  func hideHUD() {
    stopHostMotionTracking()
    endHUDDrag(commit: false)
    lastRect = nil
    verifiedHostNumber = nil
    verifiedHostAt = .distantPast
    hostMotionAt = nil
    app?.observeWindow(nil)
    if !isStatusInspector { popover.close() }
    panel.orderOut(nil)
    panel.setHostOverlayActive(false)
    lastHUDActivity = Date()
    setSunk(false, animated: false)
  }
  func updateBarTitles() {
    // One inventory per render pass: the module rows, their tooltips and the status
    // presentation all describe the same snapshot.
    let inventory = AgentInventory(stats.current?.values)
    for module in modules {
      guard let b = moduleButtons[module.id] else { continue }
      let presentation = metrics.presentation(module.metric, inventory: inventory)
      b.title = presentation.title
      b.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
      b.cell?.usesSingleLineMode = true
      b.cell?.wraps = false
      b.lineBreakMode = .byTruncatingTail
      b.toolTip = presentation.toolTip
      b.setAccessibilityLabel(presentation.accessibilityLabel)
    }
    layoutHUD()
    app?.menu.updateStatusPresentation()
  }
  @objc func showModule(_ sender: NSButton) {
    noteHUDActivity()
    guard let module = modules.first(where: { $0.id == sender.identifier?.rawValue }) else {
      return
    }
    if module.metric == .subagents {
      showAgentInspector(anchor: sender)
      return
    }
    let group = module.metric.group
    let title = module.metric.definition.group.title
    showMetric(group, title: title, anchor: sender)
  }
  func showMetric(_ kind: String, title: String, anchor: NSView) {
    if popover.isShown, popover.kind == kind, popover.anchor === anchor {
      popover.close()
      return
    }
    guard let context = inspectorContext(anchor: anchor) else { return }
    activateInspector(context)
    let content = metrics.content(kind)
    popover.present(
      kind: kind, title: title, rows: content.0, note: content.1, anchor: context.anchor,
      host: context.host, screen: context.screen, bar: context.bar,
      attachToOwner: !context.isMenuBar)
  }
  func visibleScreen(for rect: NSRect) -> NSRect {
    HUDHostGeometry.screen(for: rect, screens: NSScreen.screens.map(\.visibleFrame))
      ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
  }
  func inspectorContext(anchor: NSView) -> StatsInspectorContext? {
    if displayMode == .menuBar || anchor === status?.button {
      guard let button = status?.button, let window = button.window else { return nil }
      let bar = window.convertToScreen(button.convert(button.bounds, to: nil))
      let screen = window.screen?.visibleFrame ?? visibleScreen(for: bar)
      return StatsInspectorContext(
        anchor: button, host: screen, screen: screen, bar: bar, isMenuBar: true)
    }
    guard let host = lastRect else { return nil }
    return StatsInspectorContext(
      anchor: anchor, host: host, screen: visibleScreen(for: host), bar: panel.frame)
  }
  func positionInspector() {
    guard popover.isShown, let anchor = popover.anchor,
      let context = inspectorContext(anchor: anchor)
    else { return }
    popover.position(host: context.host, screen: context.screen, bar: context.bar)
  }
  func activateInspector(_ context: StatsInspectorContext) {
    if context.isMenuBar { NSApp.activate(ignoringOtherApps: true) }
  }
  var isStatusInspector: Bool { popover.isShown && popover.anchor === status?.button }
  var agentInspectorSize: CGSize {
    let inventory = AgentInventory(stats.current?.values)
    if let id = agentInspectorState.selectedID {
      return CGSize(width: 360, height: inventory.entry(id) == nil ? 200 : 390)
    }
    let base: CGFloat = inventory.main == nil ? 116 : 168
    return CGSize(
      width: 360, height: min(390, base + 44 * CGFloat(max(1, min(5, inventory.children.count)))))
  }
  func showAgentInspector(anchor: NSView, display: Bool = true) {
    if popover.kind == "agents", popover.isShown, popover.anchor === anchor {
      popover.close()
      return
    }
    guard let context = inspectorContext(anchor: anchor) else { return }
    activateInspector(context)
    agentInspectorState.updateScope(
      provider: activeProvider, session: stats.current?.values, reset: true)
    popover.present(
      kind: "agents", title: "代理", anchor: context.anchor, host: context.host,
      screen: context.screen, bar: context.bar, display: display,
      attachToOwner: !context.isMenuBar, customSize: agentInspectorSize,
      fittedBody: { [weak self] size in
        guard let self else { return NSView(frame: NSRect(origin: .zero, size: size)) }
        return self.agentInspectorBody(size: size)
      })
  }
  func agentInspectorBody(size: CGSize) -> NSView {
    let inventory = AgentInventory(stats.current?.values)
    let layout = AgentPageLayout(size: size)
    if let id = agentInspectorState.selectedID {
      let groups = inventory.entry(id).map { AgentInspectorView.metricGroups($0.record) } ?? []
      agentInspectorState.detailPage = min(
        agentInspectorState.detailPage, max(0, layout.detailPages(groups).count - 1))
    } else {
      let capacity = layout.listCapacity(hasMain: inventory.main != nil)
      agentInspectorState.listPage = min(
        agentInspectorState.listPage, max(0, (inventory.children.count - 1) / capacity))
    }
    return AgentInspectorView(
      size: size, inventory: inventory, state: agentInspectorState,
      hasSession: stats.current?.values != nil,
      onOpen: { [weak self] id in
        self?.agentInspectorState.open(id)
        self?.refreshAgentInspector()
      },
      onBack: { [weak self] in
        self?.agentInspectorState.back()
        self?.refreshAgentInspector()
      },
      onPage: { [weak self] delta in
        guard let self else { return }
        if self.agentInspectorState.selectedID == nil {
          self.agentInspectorState.listPage = max(0, self.agentInspectorState.listPage + delta)
        } else {
          self.agentInspectorState.detailPage = max(0, self.agentInspectorState.detailPage + delta)
        }
        self.refreshAgentInspector()
      })
  }
  func refreshAgentInspector() {
    guard popover.kind == "agents" else { return }
    agentInspectorState.updateScope(provider: activeProvider, session: stats.current?.values)
    let entry = agentInspectorState.selectedID.flatMap {
      AgentInventory(stats.current?.values).entry($0)
    }
    popover.heading.stringValue =
      agentInspectorState.selectedID == nil ? "代理" : entry?.isMain == true ? "主代理详情" : "子代理详情"
    popover.desired = agentInspectorSize
    if let anchor = popover.anchor, let context = inspectorContext(anchor: anchor) {
      popover.position(host: context.host, screen: context.screen, bar: context.bar)
    }
    popover.refreshCustomBody()
  }
}
