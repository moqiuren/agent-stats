import StatsCore
import StatsAdapters
import AppKit

final class AppCoordinator: NSObject, StatsSettingsActions {
  let configuration: StatsPreferencesStore
  let stats: StatsState
  let runtime: AppRuntimeDependencies
  let readerStore: StatsReaderStore
  private let makeService: (StatsProvider, StatsReaderStore) -> StatsCollecting
  private let readHook: () -> Lifecycle.HookReport?
  private(set) var service: StatsCollecting
  private(set) var hud: HUDWindowController!
  private(set) var menu: StatusMenuController!
  private(set) var settingsWindow: StatsSettingsWindowController?
  private(set) var onboardingWindow: OnboardingWindowController?
  private var readerStarted = false
  private var started = false
  private var promptedAccessibility = false
  private var workspaceObservers = [NSObjectProtocol]()
  private var distributedObservers = [NSObjectProtocol]()
  private var hookReportTime: Double = 0, hookTick = 0
  private var tokenCorpora = [StatsProvider: ProviderTokenCorpus]()
  private(set) var tokenStatsLoading = false
  private var hasInjectedTestCorpora = false
  private var tokenStatsLastLoadedAt: Double = -.infinity
  private struct TokenReportCacheKey: Equatable {
    let scope: TokenStatsToolScope
    let range: TokenStatsTimeRange
    let dayStartMs: Double
    let corporaRevision: UInt64
  }
  private var tokenCorporaRevision: UInt64 = 0
  private var cachedTokenReport: (key: TokenReportCacheKey, report: TokenStatsReport)?
  private(set) var updateState: AppUpdateState
  private(set) var paused = false
  private(set) var scopeText = ""

  init(
    preferences: UserDefaults = .standard, provider: StatsProvider? = nil,
    readers: StatsReaderStore? = nil,
    runtime: AppRuntimeDependencies = .live(),
    makeService: ((StatsProvider, StatsReaderStore) -> StatsCollecting)? = nil,
    readHook: @escaping () -> Lifecycle.HookReport? = {
      Lifecycle.hookReport(support: Product.support)
    }
  ) {
    configuration = StatsPreferencesStore(preferences)
    updateState = .idle(lastCheckedAt: configuration.lastUpdateCheckMs)
    let initial = provider ?? configuration.activeProvider
    self.runtime = runtime
    stats = StatsState(provider: initial, clock: { runtime.clock.now })
    let readers = readers ?? StatsReaderStore(clock: runtime.clock)
    readerStore = readers
    let factory = makeService ?? { provider, store in
      NativeStatsService(provider: provider, readers: store, bridge: runtime.bridge,
                         clock: runtime.clock, uiScheduler: runtime.uiScheduler,
                         monitor: runtime.makeSessionMonitor(provider))
    }
    self.makeService = factory
    self.readHook = readHook
    service = factory(initial, readers)
    super.init()
    hud = HUDWindowController(app: self, scheduler: runtime.uiScheduler, hostMonitor: runtime.makeHostMonitor())
    menu = StatusMenuController(app: self)
  }
  deinit {
    // Controllers may briefly outlive their owner (AppKit callbacks or tests).
    // Their action links are weak; release observers and owned UI deterministically.
    for observer in workspaceObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    for observer in distributedObservers {
      DistributedNotificationCenter.default().removeObserver(observer)
    }
    service.stop()
    runtime.updater?.stop()
    settingsWindow?.close()
    onboardingWindow?.close()
    hud.close()
    menu.removeStatusItem()
  }
  var provider: StatsProvider { stats.provider }
  var activeProvider: String { provider.rawValue }
  var readerGeneration: UUID { stats.generation }
  var observedWindow: HostWindowReference? { stats.observedWindow }
  var canFollowCurrentConversation: Bool { stats.canFollowCurrentConversation }
  var followsActiveTool: Bool {
    get { configuration.followsActiveTool }
    set { configuration.followsActiveTool = newValue }
  }
  var selected: String? {
    get { configuration.selectedSession(for: provider) }
    set { configuration.setSelectedSession(newValue, for: provider) }
  }
  var selectedProject: String {
    get { configuration.selectedProject(for: provider) }
    set { configuration.setSelectedProject(newValue, for: provider) }
  }
  var selectionMode: SessionSelectionMode {
    get { SessionSelectionMode.resolve(selected, provider: activeProvider) }
    set { selected = newValue.storedValue }
  }
  var hudHidden: Bool {
    get { configuration.hudHidden(for: provider) }
    set { configuration.setHUDHidden(newValue, for: provider) }
  }
  var hudIdleSink: Bool { configuration.hudIdleSink }
  var statusItemHidden: Bool { configuration.statusItemHidden }
  var displayMode: StatsDisplayMode {
    get { configuration.displayMode(for: provider) }
    set { configuration.setDisplayMode(newValue, for: provider) }
  }
  var modules: [HUDModule] {
    get { configuration.modules(for: provider) }
    set { configuration.setModules(newValue, for: provider) }
  }
  var metrics: MetricPresenter {
    let clock = runtime.clock
    return MetricPresenter(
      provider: provider, record: stats.current, now: { clock.milliseconds },
      hookReport: readHook, detailKeys: configuration.detailRowKeys(for: provider))
  }
  func metricTitle(_ metric: HUDMetric) -> String {
    metrics.title(metric)
  }
  var confirmUninstall: (() -> Bool)?
  private(set) var lastSystemError: String?
  var isAccessibilityAuthorized: Bool { runtime.isAccessibilityAuthorized() }
  var isLaunchAtLoginEnabled: Bool { runtime.system.isLaunchAtLoginEnabled }
  var isInStandardApplicationsLocation: Bool { runtime.system.isInStandardApplicationsLocation }
  var kimiPluginStatusText: String {
    switch runtime.system.kimiPluginStatus() {
    case .synced: return "已同步"
    case .disabledByUser: return "已在 Kimi 中手动停用"
    case .notSynced: return "尚未同步"
    case .error(let text): return text
    }
  }
  func start() {
    guard !started else { return }
    started = true
    configuration.prepareLaunch(
      provider: provider,
      bridgeInstalled: FileManager.default.fileExists(
        atPath: Product.support.appendingPathComponent("kimi-bridge/connection.json").path))
    let shouldShowOnboarding = runtime.enablesLaunchSetup ? prepareLaunchSetup() : false
    NSApp.setActivationPolicy(.accessory)
    hud.makePanel()
    menu.makeStatus()
    menu.makeApplicationMenu()
    startReader()
    workspaceObservers = [
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
      ) { [weak self] note in
        self?.activeApplicationChanged(
          (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
            .bundleIdentifier)
      }
    ]
    distributedObservers = [
      DistributedNotificationCenter.default().addObserver(
        forName: Self.showSettingsNotification, object: nil, queue: .main
      ) { [weak self] _ in self?.handleReopen() }
    ]
    hud.startMonitoring()
    if let updater = runtime.updater {
      updater.onStateChange = { [weak self] next in self?.applyUpdateState(next) }
      updater.onCheckRecorded = { [weak self] ms in self?.configuration.lastUpdateCheckMs = ms }
      updater.start(
        autoCheck: configuration.autoCheckUpdates,
        autoDownload: configuration.autoDownloadUpdates,
        lastCheckedAtMs: configuration.lastUpdateCheckMs)
    }
    if shouldShowOnboarding {
      showOnboarding()
    }
  }
  @discardableResult
  func prepareLaunchSetup() -> Bool {
    if runtime.system.isInStandardApplicationsLocation {
      runtime.system.performSilentLaunchMaintenance()
      if !configuration.onboardingCompleted && !runtime.system.isLaunchAtLoginEnabled {
        try? runtime.system.setLaunchAtLogin(true)
      }
    }
    guard !configuration.onboardingCompleted else { return false }
    if !runtime.isAccessibilityAuthorized() {
      for item in StatsProvider.allCases where !configuration.hasExplicitDisplayMode(for: item) {
        configuration.setDisplayMode(.menuBar, for: item)
      }
      if configuration.selectedSession(for: .kimi) == nil
        || configuration.selectedSession(for: .kimi) == "__current__"
      {
        configuration.setSelectedSession("__recent__", for: .kimi)
      }
      configuration.pendingFloatingActivation = true
      return true
    }
    if !runtime.system.isInStandardApplicationsLocation {
      return true
    }
    configuration.onboardingCompleted = true
    configuration.pendingFloatingActivation = false
    return false
  }
  func checkPendingAccessibilityUpgrade() {
    onboardingWindow?.refresh()
    if settingsWindow?.window?.isVisible == true { settingsWindow?.refresh() }
    guard configuration.pendingFloatingActivation, runtime.isAccessibilityAuthorized() else {
      return
    }
    configuration.pendingFloatingActivation = false
    configuration.onboardingCompleted = true
    for item in StatsProvider.allCases {
      configuration.setDisplayMode(.floating, for: item)
      configuration.setHUDHidden(false, for: item)
    }
    if configuration.selectedSession(for: .kimi) == "__recent__" {
      configuration.setSelectedSession("__current__", for: .kimi)
    }
    hud.preparePresentationChange()
    menu.rebuild()
    menu.updateStatusPresentation()
    updateReader(refresh: true)
    render()
    refreshSettings()
    onboardingWindow?.refresh()
  }
  func startReader() {
    guard !readerStarted else { return }
    readerStarted = true
    hookReportTime = readHook()?.time ?? 0
    let generation = readerGeneration
    service.onUpdate = { [weak self] update in self?.receive(update, generation: generation) }
    service.start()
    service.update(selection: selectionMode, paused: nil, refresh: true)
  }
  func switchProvider(_ next: StatsProvider, manual: Bool = true) {
    if manual { followsActiveTool = false }
    guard next != provider else {
      settingsWindow?.providerDidChange()
      menu.rebuild()
      return
    }
    hud.prepareProviderChange()
    let restart = readerStarted
    service.stop()
    readerStarted = false
    stats.switchProvider(next)
    configuration.activeProvider = next
    service = makeService(next, readerStore)
    scopeText = "加载会话…"
    paused = false
    hud.clearHost()
    if hud.panel != nil {
      hud.applyModules()
      render()
    }
    if restart { startReader() }
    settingsWindow?.providerDidChange()
    menu.rebuild()
    menu.updateStatusPresentation()
  }
  func selectProvider(_ provider: StatsProvider) {
    switchProvider(provider)
    hud.follow()
  }
  func enableToolFollowing() {
    followsActiveTool = true
    if let next = StatsProvider.host(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
      switchProvider(next, manual: false)
    }
    menu.rebuild()
    refreshSettings()
    hud.follow()
  }
  func updateReader(paused: Bool? = nil, refresh: Bool = false) {
    service.update(selection: selectionMode, paused: paused, refresh: refresh)
  }
  func setCollectionPaused(_ value: Bool, refresh: Bool = false) {
    paused = value
    updateReader(paused: value, refresh: refresh)
  }
  func checkHookReport() {
    hookTick = (hookTick + 1) % 5
    guard hookTick == 1, provider == .kimi, let report = readHook(), report.time != hookReportTime
    else { return }
    hookReportTime = report.time
    updateReader(refresh: true)
  }
  func receive(_ update: StatsUpdate, generation: UUID) {
    guard stats.receive(update, generation: generation) else { return }
    if runtime.tokenHistory == nil {
      cachedTokenReport = nil
    } else if settingsWindow?.window?.isVisible == true, settingsWindow?.page == .tokenStats {
      refreshTokenStats(force: false)
    }
    render()
  }
  func render() {
    let presentation = stats.resolve(selectionMode)
    scopeText = presentation.record?.title ?? presentation.placeholder.rawValue
    hud.render(presentation)
    refreshSettings()
    hud.refreshAgentInspector()
  }
  func observeWindow(_ window: HostWindowReference?) {
    if stats.observeWindow(window), selectionMode == .automatic { render() }
    service.observe(window)
  }
  func activeApplicationChanged(_ front: String?) {
    if followsActiveTool, let next = StatsProvider.host(front), next != provider {
      switchProvider(next, manual: false)
    }
    hud.activeApplicationChanged(front)
  }
  func refreshSettings() { settingsWindow?.refresh() }
  func browseProject(_ id: String) { selectedProject = id }
  func selectSession(_ id: String) {
    selected = id
    render()
    updateReader(refresh: true)
  }
  func selectRecentSession() {
    selectionMode = .recent
    render()
    updateReader(refresh: true)
  }
  var detailRowKeys: Set<String> { configuration.detailRowKeys(for: provider) }
  func editDetailRow(_ key: String, enabled: Bool) {
    guard DetailRowRegistry.allKeys.contains(key) else { return }
    var keys = detailRowKeys
    if enabled { keys.insert(key) } else { keys.remove(key) }
    configuration.setDetailRowKeys(keys, for: provider)
    hud.refreshDetailCard()
    refreshSettings()
  }
  func editModules(_ edit: HUDModuleEdit) {
    configuration.editModules(edit, for: provider)
    hud.modulesDidChange()
    refreshSettings()
  }
  func setDisplayMode(_ mode: StatsDisplayMode) {
    guard mode != displayMode else { return }
    hud.preparePresentationChange()
    displayMode = mode
    if mode == .floating { hudHidden = false }
    menu.rebuild()
    menu.updateStatusPresentation()
    hud.follow()
    refreshSettings()
  }
  func toggle() {
    hudHidden.toggle()
    menu.updateVisibilityTitle()
    hud.popover.close()
    hud.follow()
    refreshSettings()
  }
  func setHUDIdleSink(_ enabled: Bool) {
    configuration.hudIdleSink = enabled
    hud.idleSinkPreferenceChanged()
    menu.rebuild()
    refreshSettings()
  }
  func setStatusItemHidden(_ hidden: Bool) {
    configuration.statusItemHidden = hidden
    menu.updateStatusItemVisibility()
    refreshSettings()
  }
  static let showSettingsNotification = Notification.Name(Product.bundleID + ".showSettings")
  /// Opening the app again while it runs (Finder, Launchpad, `open`) shows settings,
  /// which is also the way back when the menu bar icon is hidden.
  func handleReopen() {
    guard started else { return }
    showSettings()
  }
  func shouldPauseReader(hostAvailable: Bool, hostOrStatsActive: Bool) -> Bool {
    displayMode == .floating && !hud.isStatusInspector && settingsWindow?.window?.isVisible != true
      && onboardingWindow?.window?.isVisible != true
      && (!hostAvailable || !hostOrStatsActive)
  }
  func showSettings() {
    hud.endHUDDrag(commit: false)
    hud.popover.close()
    if settingsWindow == nil { settingsWindow = StatsSettingsWindowController(actions: self) }
    settingsWindow?.present()
    hud.follow()
  }
  func openSettingsPage(_ page: StatsSettingsPage) {
    showSettings()
    settingsWindow?.selectPage(page)
  }
  func showHelpSettings() { openSettingsPage(.help) }
  func showHelpCategory(_ id: String) {
    showHelpSettings()
    settingsWindow?.scrollHelpCategory(id)
  }
  func showOnboarding() {
    hud.endHUDDrag(commit: false)
    hud.popover.close()
    if onboardingWindow == nil { onboardingWindow = OnboardingWindowController(actions: self) }
    onboardingWindow?.present()
  }
  func completeOnboarding(keepPendingUpgrade: Bool) {
    configuration.onboardingCompleted = true
    if !keepPendingUpgrade {
      configuration.pendingFloatingActivation = false
    }
  }
  private func presentSystemError(_ title: String, _ error: Error) {
    let message = error.localizedDescription
    lastSystemError = message
    guard NSApp.activationPolicy() != .prohibited else { return }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "好")
    alert.runModal()
  }
  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      try runtime.system.setLaunchAtLogin(enabled)
    } catch {
      presentSystemError("无法更改开机自动启动设置", error)
    }
    refreshSettings()
    onboardingWindow?.refresh()
  }
  func relocateToApplications() {
    do {
      _ = try runtime.system.relocateToApplicationsAndRelaunch()
      runtime.terminateApp()
    } catch {
      presentSystemError("无法移至应用程序文件夹", error)
    }
  }
  func syncKimiPlugin() {
    do {
      _ = try runtime.system.syncKimiPlugin(forceEnable: true)
    } catch {
      presentSystemError("无法同步 Kimi 生命周期插件", error)
    }
    refreshSettings()
    onboardingWindow?.refresh()
  }
  func revealAppInFinder() {
    runtime.system.revealCurrentAppInFinder()
  }
  func confirmAndUninstall() {
    let confirmed: Bool
    if let confirmUninstall {
      confirmed = confirmUninstall()
    } else if NSApp.activationPolicy() == .prohibited {
      confirmed = false
    } else {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "卸载 \(Product.name)？"
      alert.informativeText =
        "将停止服务并移除登录项、Kimi 生命周期插件登记、应用偏好与本地缓存，并将 \(Product.name).app 移至废纸篓。\n\nCodex 与 Kimi Code 宿主及历史会话数据不会受影响。"
      alert.addButton(withTitle: "移至废纸篓并卸载")
      alert.addButton(withTitle: "取消")
      confirmed = alert.runModal() == .alertFirstButtonReturn
    }
    guard confirmed else { return }
    do {
      try runtime.system.performGUIUninstall()
      runtime.terminateApp()
    } catch {
      presentSystemError("卸载失败", error)
    }
  }
  func resignActive() {
    if displayMode == .menuBar || hud.isStatusInspector { hud.popover.close() }
  }
  func stop() {
    hud.stopMonitoring()
    for observer in workspaceObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    workspaceObservers.removeAll()
    for observer in distributedObservers {
      DistributedNotificationCenter.default().removeObserver(observer)
    }
    distributedObservers.removeAll()
    service.stop()
    readerStarted = false
    started = false
    runtime.updater?.stop()
    runtime.bridge.stop()
  }
  @objc func enableNativeFollowing() {
    guard provider.supportsAutomaticSessionFollow else {
      selectionMode = .recent
      render()
      updateReader(refresh: true)
      return
    }
    let wasAutomatic = selectionMode == .automatic
    selected = "__current__"
    hud.popover.close()
    if !wasAutomatic {
      stats.nativeSelection = CurrentSession(
        isAccessibilityAuthorized ? .unknown : .permissionRequired,
        window: observedWindow?.token)
    }
    render()
    updateReader(refresh: true)
    if !isAccessibilityAuthorized,
      activeProvider != "kimi" || stats.pageSelection.status == .notInstalled
    {
      HostAccessibility.requestAuthorization()
    }
  }
  func openAccessibilitySettings() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    {
      NSWorkspace.shared.open(url)
    }
  }
  func authorizeWindowRecognition() {
    if isAccessibilityAuthorized {
      openAccessibilitySettings()
    } else if !promptedAccessibility {
      promptedAccessibility = true
      HostAccessibility.requestAuthorization()
    } else {
      openAccessibilitySettings()
    }
  }
  func conversationChoices(in project: String? = nil) -> [InspectorChoice] {
    // `selected` is the pinned preference; the currently displayed conversation is
    // marked as well, so automatic and recent modes still show which one is in use.
    let displayed = stats.current?.id
    return stats.conversations(in: project ?? selectedProject).map {
      let id = $0.id
      return InspectorChoice(
        id: id ?? "undefined", title: $0.title,
        selected: selected == id || (displayed != nil && displayed == id))
    }
  }
  func sessionModes() -> [InspectorChoice] {
    // A tool whose host exposes no reliable current-conversation identifier offers
    // no automatic mode at all; it is neither shown nor selectable.
    var modes = [InspectorChoice]()
    if provider.supportsAutomaticSessionFollow {
      let unavailable = !stats.canFollowCurrentConversation
      modes.append(
        InspectorChoice(
          id: "__current__", title: unavailable ? "自动跟随（宿主暂不支持）" : "自动跟随当前对话",
          selected: selectionMode == .automatic, enabled: !unavailable))
    }
    modes.append(
      InspectorChoice(id: "__recent__", title: "最近活跃会话", selected: selectionMode == .recent))
    return modes
  }
  func pickSession(_ id: String, project: String?) {
    if id == "__current__" {
      selectedProject = "all"
      enableNativeFollowing()
      return
    }
    if id == "__recent__" {
      selectedProject = "all"
      selectionMode = .recent
    } else {
      selectedProject = project ?? "all"
      selected = id.isEmpty ? nil : id
    }
    render()
    updateReader(refresh: true)
  }
  var projectGroups: [JSONObject] { stats.navigationGroups.map(\.json) }
  var tokenStatsScope: TokenStatsToolScope { configuration.tokenStatsScope }
  var tokenStatsRange: TokenStatsTimeRange { configuration.tokenStatsRange }
  var tokenStatsDimension: TokenStatsDimension { configuration.tokenStatsDimension }
  func setTokenStatsScope(_ scope: TokenStatsToolScope) {
    guard scope != configuration.tokenStatsScope else { return }
    configuration.tokenStatsScope = scope
    cachedTokenReport = nil
    refreshSettings()
  }
  func setTokenStatsRange(_ range: TokenStatsTimeRange) {
    guard range != configuration.tokenStatsRange else { return }
    configuration.tokenStatsRange = range
    cachedTokenReport = nil
    refreshSettings()
  }
  func setTokenStatsDimension(_ dimension: TokenStatsDimension) {
    guard dimension != configuration.tokenStatsDimension else { return }
    configuration.tokenStatsDimension = dimension
    refreshSettings()
  }
  func setTokenCorporaForTesting(_ corpora: [StatsProvider: ProviderTokenCorpus]) {
    hasInjectedTestCorpora = true
    tokenCorpora = corpora
    tokenStatsLastLoadedAt = runtime.clock.milliseconds
    tokenCorporaRevision &+= 1
    cachedTokenReport = nil
    refreshSettings()
  }
  func refreshTokenStats(force: Bool = false) {
    let nowMs = runtime.clock.milliseconds
    guard readerStarted, !hasInjectedTestCorpora, let tokenHistory = runtime.tokenHistory else {
      if hasInjectedTestCorpora {
        refreshSettings()
        return
      }
      if force || tokenCorpora[provider] == nil {
        tokenCorpora[provider] = ProviderTokenCorpus.fromCatalog(
          stats.catalog, provider: provider, collectedAt: nowMs)
        tokenCorporaRevision &+= 1
        cachedTokenReport = nil
        refreshSettings()
      }
      return
    }
    guard force || tokenCorpora.isEmpty || (nowMs - tokenStatsLastLoadedAt >= 15_000) else {
      return
    }
    tokenStatsLoading = true
    refreshSettings()
    tokenHistory.loadAll(now: nowMs) { [weak self] corpora in
      guard let self else { return }
      self.tokenCorpora = corpora
      self.tokenStatsLastLoadedAt = self.runtime.clock.milliseconds
      self.tokenStatsLoading = false
      self.tokenCorporaRevision &+= 1
      self.cachedTokenReport = nil
      self.refreshSettings()
    }
  }
  func tokenStatsReport() -> TokenStatsReport {
    var effective = tokenCorpora
    if effective[provider] == nil, !stats.catalog.sessions.isEmpty {
      effective[provider] = ProviderTokenCorpus.fromCatalog(
        stats.catalog, provider: provider, collectedAt: runtime.clock.milliseconds)
    }
    let nowDate = runtime.clock.now
    let dayStartMs = Calendar.autoupdatingCurrent.startOfDay(for: nowDate).timeIntervalSince1970 * 1000
    let key = TokenReportCacheKey(
      scope: tokenStatsScope, range: tokenStatsRange,
      dayStartMs: dayStartMs, corporaRevision: tokenCorporaRevision)
    if let cachedTokenReport, cachedTokenReport.key == key, !effective.isEmpty == true,
      tokenCorpora[provider] != nil || stats.catalog.sessions.isEmpty
    {
      return cachedTokenReport.report
    }
    let report = TokenStatsAggregator.aggregate(
      corpora: effective, scope: tokenStatsScope, range: tokenStatsRange, now: nowDate)
    if tokenCorpora[provider] != nil || stats.catalog.sessions.isEmpty {
      cachedTokenReport = (key, report)
    }
    return report
  }

  var autoCheckUpdates: Bool { configuration.autoCheckUpdates }
  var autoDownloadUpdates: Bool { configuration.autoDownloadUpdates }

  func setAutoCheckUpdates(_ enabled: Bool) {
    configuration.autoCheckUpdates = enabled
    runtime.updater?.setPreferences(autoCheck: enabled, autoDownload: configuration.autoDownloadUpdates)
    refreshSettings()
  }

  func setAutoDownloadUpdates(_ enabled: Bool) {
    configuration.autoDownloadUpdates = enabled
    runtime.updater?.setPreferences(autoCheck: configuration.autoCheckUpdates, autoDownload: enabled)
    refreshSettings()
  }

  func applyUpdateState(_ next: AppUpdateState) {
    updateState = next
    menu.rebuild()
    refreshSettings()
  }

  func checkForUpdates() {
    runtime.updater?.checkForUpdates(userInitiated: true)
  }

  func checkForUpdatesAndShowAbout() {
    openSettingsPage(.about)
    switch updateState {
    case .available, .downloading, .downloaded, .installing:
      break
    default:
      checkForUpdates()
    }
  }

  func performPrimaryUpdateAction() {
    switch updateState {
    case .idle, .upToDate, .failed(_, nil):
      checkForUpdates()
    case .available(let release, _):
      if release.asset != nil {
        runtime.updater?.downloadUpdate()
      } else {
        openLatestReleasePage()
      }
    case .downloaded(let release, let artifact):
      guard artifact.canInstallInPlace else {
        runtime.updater?.revealDownloadedUpdate()
        return
      }
      do {
        let stagedApp: URL
        if let updater = runtime.updater {
          stagedApp = try updater.stagedBundleForInstall().stagedApp
        } else if let direct = artifact.stagedAppURL {
          stagedApp = direct
        } else {
          return
        }
        applyUpdateState(.installing(release))
        _ = try runtime.system.installUpdateAndRelaunch(from: stagedApp)
        runtime.terminateApp()
      } catch {
        applyUpdateState(.downloaded(release, artifact))
        presentSystemError("安装更新失败", error)
      }
    case .failed(_, let release?):
      if release.asset != nil {
        runtime.updater?.downloadUpdate()
      } else {
        openLatestReleasePage()
      }
    case .checking, .downloading, .installing:
      break
    }
  }

  func openLatestReleasePage() {
    let url =
      updateState.availableRelease?.htmlURL
      ?? URL(string: "https://github.com/\(Product.githubRepository)/releases")!
    NSWorkspace.shared.open(url)
  }
}
