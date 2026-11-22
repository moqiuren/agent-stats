import AppKit
@testable import AgentStatsApp
@testable import StatsAdapters
@testable import StatsCore

private final class TestClock: StatsClock {
  var now = Date(timeIntervalSince1970: 1000)
  var uptime: TimeInterval = 0
}

private final class TestScheduler: StatsScheduling {
  final class Task: StatsCancellation {
    var cancelled = false
    func cancel() { cancelled = true }
  }
  var isIsolated: Bool { true }
  var tasks = [Task]()
  func execute(_ action: @escaping () -> Void) { action() }
  func schedule(
    after delay: TimeInterval, repeating interval: TimeInterval?, tolerance: TimeInterval,
    _ action: @escaping () -> Void
  ) -> StatsCancellation {
    let task = Task()
    tasks.append(task)
    return task
  }
}

private final class TestBridge: PageSelectionBridging {
  func start() {}
  func stop() {}
  func snapshot() -> PageSessionSelection { PageSessionSelection() }
}

private final class TestHostMonitor: HostWindowMonitoring {
  func observe(windows: [HostWindowReference], requireFocused: Bool, provider: String) -> UInt32? {
    nil
  }
  func reset() {}
}

private final class TestSessionMonitor: CurrentSessionMonitoring {
  var onChange: ((CurrentSession) -> Void)?
  func start() {}
  func stop() { onChange = nil }
  func observe(_ window: HostWindowReference?) {}
  func setEnabled(_ enabled: Bool) {}
}

private final class StubReader: StatsReading {
  let provider: StatsProvider
  init(provider: StatsProvider) { self.provider = provider }
  func scan(selected: String?, now: Double) -> StatsSnapshot {
    StatsSnapshot(provider: provider, collectedAt: now)
  }
}

private final class StubUpdater: AppUpdateManaging {
  var state: AppUpdateState = .idle(lastCheckedAt: nil)
  var onStateChange: ((AppUpdateState) -> Void)?
  var onCheckRecorded: ((Double) -> Void)?
  var started = 0
  var stopped = 0
  var checkCalls = [Bool]()
  var stagedURL: URL?

  func start(autoCheck: Bool, autoDownload: Bool, lastCheckedAtMs: Double?) { started += 1 }
  func setPreferences(autoCheck: Bool, autoDownload: Bool) {}
  func checkForUpdates(userInitiated: Bool) { checkCalls.append(userInitiated) }
  func downloadUpdate() {}
  func stagedBundleForInstall() throws -> (release: AppReleaseInfo, stagedApp: URL) {
    guard case .downloaded(let rel, _) = state, let stagedURL else {
      throw Lifecycle.error("missing staged bundle")
    }
    return (rel, stagedURL)
  }
  func revealDownloadedUpdate() {}
  func stop() { stopped += 1; onStateChange = nil; onCheckRecorded = nil }
}

enum OnboardingTests {
  static func run() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    var checks = 0
    func check(_ value: Bool, _ message: String) {
      precondition(value, message)
      checks += 1
    }
    func descendants(_ view: NSView) -> [NSView] {
      [view] + view.subviews.flatMap { descendants($0) }
    }
    func control<T: NSView>(in window: NSWindow, _ id: String, _ type: T.Type) -> T {
      guard
        let found = descendants(window.contentView!).first(where: {
          $0.identifier?.rawValue == id
        }) as? T
      else { preconditionFailure("missing control \(id)") }
      return found
    }

    // 1. Zero-permission first launch falls back to menu bar, shows onboarding, and auto-upgrades on grant.
    do {
      let suite = "onboarding-upgrade-" + UUID().uuidString
      let defaults = UserDefaults(suiteName: suite)!
      defer { defaults.removePersistentDomain(forName: suite) }
      var authorized = false
      var terminated = false
      let system = InMemoryAppSystemIntegration()
      system.isInStandardApplicationsLocation = true
      system.isLaunchAtLoginEnabled = false
      let clock = TestClock()
      let scheduler = TestScheduler()
      let runtime = AppRuntimeDependencies(
        clock: clock, uiScheduler: scheduler, bridge: TestBridge(),
        makeHostMonitor: { TestHostMonitor() },
        makeSessionMonitor: { _ in TestSessionMonitor() },
        isAccessibilityAuthorized: { authorized },
        system: system,
        enablesLaunchSetup: true,
        terminateApp: { terminated = true })
      let readers = StatsReaderStore(
        clock: clock, scheduler: scheduler, factory: { StubReader(provider: $0) })
      let app = AppCoordinator(
        preferences: defaults, provider: .kimi, readers: readers, runtime: runtime, readHook: { nil })
      defer { app.stop() }
      app.start()

      check(system.launchMaintenanceCalls == 1, "start runs silent launch maintenance in standard directory")
      check(system.isLaunchAtLoginEnabled, "first launch enables launch at login by default")
      check(
        app.configuration.displayMode(for: .codex) == .menuBar
          && app.configuration.displayMode(for: .kimi) == .menuBar,
        "first launch without Accessibility falls back to menuBar for both tools")
      check(
        app.configuration.selectedSession(for: .kimi) == "__recent__",
        "first launch without Accessibility switches Kimi temporarily to recent activity")
      check(app.configuration.pendingFloatingActivation, "pending floating upgrade flag is recorded")
      check(app.onboardingWindow?.window?.isVisible == true, "onboarding window opens on first launch")

      let onboardingWindow = app.onboardingWindow!.window!
      let later = control(in: onboardingWindow, "onboarding-later", NSButton.self)
      _ = NSApp.sendAction(later.action!, to: later.target, from: later)
      check(
        app.configuration.onboardingCompleted && app.configuration.pendingFloatingActivation
          && !onboardingWindow.isVisible,
        "choosing menu bar first dismisses onboarding while keeping pending floating upgrade")

      // Menu bar mode has no floating authorize entry; switching to floating while unauthorized shows it.
      let menuBarMenu = app.menu.makeStatusMenu()
      check(
        !menuBarMenu.items.contains { $0.action == #selector(StatusMenuController.authorizeWindowRecognition) },
        "menu bar mode omits floating-only accessibility item")
      app.setDisplayMode(.floating)
      let floatingUnauthorizedMenu = app.menu.makeStatusMenu()
      check(
        floatingUnauthorizedMenu.items.contains {
          $0.title == "授权辅助功能以显示悬浮条…"
            && $0.action == #selector(StatusMenuController.authorizeWindowRecognition)
        },
        "floating mode while unauthorized exposes quick authorization entry")
      check(
        floatingUnauthorizedMenu.items.suffix(2).map(\.title) == ["使用说明", "退出 " + Product.name],
        "help and quit stay the last two items")

      // Grant Accessibility -> follow loop upgrades back to floating automatically
      app.setDisplayMode(.menuBar)
      app.configuration.pendingFloatingActivation = true
      authorized = true
      app.hud.follow()
      check(
        !app.configuration.pendingFloatingActivation
          && app.configuration.displayMode(for: .codex) == .floating
          && app.configuration.displayMode(for: .kimi) == .floating,
        "granting Accessibility upgrades both tools back to floating mode")
      check(
        app.configuration.selectedSession(for: .kimi) == "__current__",
        "granting Accessibility restores Kimi automatic current-conversation following")
      check(!terminated, "upgrade never terminates the running process")
    }

    // 2. Authorized + non-standard location shows relocate card in onboarding; standard skips popup.
    do {
      let suite = "onboarding-relocate-" + UUID().uuidString
      let defaults = UserDefaults(suiteName: suite)!
      defer { defaults.removePersistentDomain(forName: suite) }
      var terminated = false
      let system = InMemoryAppSystemIntegration()
      system.isInStandardApplicationsLocation = false
      let clock = TestClock()
      let scheduler = TestScheduler()
      let runtime = AppRuntimeDependencies(
        clock: clock, uiScheduler: scheduler, bridge: TestBridge(),
        makeHostMonitor: { TestHostMonitor() },
        makeSessionMonitor: { _ in TestSessionMonitor() },
        isAccessibilityAuthorized: { true },
        system: system,
        enablesLaunchSetup: true,
        terminateApp: { terminated = true })
      let app = AppCoordinator(
        preferences: defaults, provider: .codex,
        readers: StatsReaderStore(
          clock: clock, scheduler: scheduler, factory: { StubReader(provider: $0) }),
        runtime: runtime, readHook: { nil })
      defer { app.stop() }
      app.start()
      check(app.onboardingWindow?.window?.isVisible == true, "non-standard bundle location surfaces relocation onboarding")
      let relocate = control(in: app.onboardingWindow!.window!, "onboarding-relocate", NSButton.self)
      _ = NSApp.sendAction(relocate.action!, to: relocate.target, from: relocate)
      check(system.relocateCalls == 1 && terminated, "relocate button moves app and exits old instance")
    }

    do {
      let suite = "onboarding-silent-" + UUID().uuidString
      let defaults = UserDefaults(suiteName: suite)!
      defer { defaults.removePersistentDomain(forName: suite) }
      let system = InMemoryAppSystemIntegration()
      system.isInStandardApplicationsLocation = true
      let clock = TestClock()
      let scheduler = TestScheduler()
      let runtime = AppRuntimeDependencies(
        clock: clock, uiScheduler: scheduler, bridge: TestBridge(),
        makeHostMonitor: { TestHostMonitor() },
        makeSessionMonitor: { _ in TestSessionMonitor() },
        isAccessibilityAuthorized: { true },
        system: system,
        enablesLaunchSetup: true)
      let app = AppCoordinator(
        preferences: defaults, provider: .codex,
        readers: StatsReaderStore(
          clock: clock, scheduler: scheduler, factory: { StubReader(provider: $0) }),
        runtime: runtime, readHook: { nil })
      defer { app.stop() }
      app.start()
      check(
        app.onboardingWindow == nil && app.configuration.onboardingCompleted,
        "already-authorized standard installs skip onboarding without interruption")
    }

    // 3. Settings controls for launch at login, Kimi sync, onboarding reopen, and GUI uninstall
    do {
      let suite = "settings-system-" + UUID().uuidString
      let defaults = UserDefaults(suiteName: suite)!
      defer { defaults.removePersistentDomain(forName: suite) }
      var terminated = false
      var confirmResult = false
      let system = InMemoryAppSystemIntegration()
      system.isInStandardApplicationsLocation = false
      system.pluginStatus = .disabledByUser
      let clock = TestClock()
      let scheduler = TestScheduler()
      let runtime = AppRuntimeDependencies(
        clock: clock, uiScheduler: scheduler, bridge: TestBridge(),
        makeHostMonitor: { TestHostMonitor() },
        makeSessionMonitor: { _ in TestSessionMonitor() },
        isAccessibilityAuthorized: { false },
        system: system,
        enablesLaunchSetup: false,
        terminateApp: { terminated = true },
        updater: StubUpdater())
      let app = AppCoordinator(
        preferences: defaults, provider: .kimi,
        readers: StatsReaderStore(
          clock: clock, scheduler: scheduler, factory: { StubReader(provider: $0) }),
        runtime: runtime, readHook: { nil })
      app.followsActiveTool = false
      app.hud.makePanel()
      app.menu.makeStatus()
      app.hud.interactionMenuOpen = true
      defer { app.stop() }
      app.confirmUninstall = { confirmResult }
      app.showSettings()
      let controller = app.settingsWindow!
      let win = controller.window!

      controller.selectPage(.general)
      let launchSwitch = control(in: win, "settings-launch-at-login", NSSwitch.self)
      launchSwitch.state = .on
      _ = NSApp.sendAction(launchSwitch.action!, to: launchSwitch.target, from: launchSwitch)
      check(system.isLaunchAtLoginEnabled, "settings launch switch enables login item")

      controller.selectPage(.sessions)
      let syncBtn = control(in: win, "settings-sync-kimi", NSButton.self)
      _ = NSApp.sendAction(syncBtn.action!, to: syncBtn.target, from: syncBtn)
      check(system.syncCalls == 1 && system.pluginStatus == .synced, "settings sync button forces Kimi plugin sync")

      controller.selectPage(.about)
      let onboardBtn = control(in: win, "settings-open-onboarding", NSButton.self)
      _ = NSApp.sendAction(onboardBtn.action!, to: onboardBtn.target, from: onboardBtn)
      check(app.onboardingWindow?.window?.isVisible == true, "about page reopens onboarding window")
      app.onboardingWindow?.close()

      let updater = runtime.updater as! StubUpdater
      let updateBtn = control(in: win, "settings-update-primary", NSButton.self)
      _ = NSApp.sendAction(updateBtn.action!, to: updateBtn.target, from: updateBtn)
      check(updater.checkCalls == [true], "about page primary button triggers user-initiated update check")

      let fakeStaged = URL(fileURLWithPath: "/tmp/FakeStaged-\(UUID().uuidString).app")
      let rel = AppReleaseInfo(
        version: "9.9.9", semanticVersion: SemanticVersion("9.9.9")!, tagName: "v9.9.9",
        title: "v9.9.9", notes: "", htmlURL: URL(string: "https://github.com/moqiuren/agent-stats/releases/tag/v9.9.9")!,
        publishedAt: nil, asset: nil)
      updater.stagedURL = fakeStaged
      updater.state = .downloaded(rel, StagedUpdateArtifact(version: "9.9.9", archiveURL: fakeStaged, stagedAppURL: fakeStaged))
      app.applyUpdateState(updater.state)
      controller.refresh()
      let installBtn = control(in: win, "settings-update-primary", NSButton.self)
      check(installBtn.title == "安装并重启", "downloaded release transitions primary button to install & relaunch")
      _ = NSApp.sendAction(installBtn.action!, to: installBtn.target, from: installBtn)
      check(system.installedUpdatePaths == [fakeStaged] && terminated, "install action hands staged app to system integrator and exits")
      terminated = false

      let uninstallBtn = control(in: win, "settings-uninstall", NSButton.self)
      confirmResult = false
      _ = NSApp.sendAction(uninstallBtn.action!, to: uninstallBtn.target, from: uninstallBtn)
      check(system.uninstallCalls == 0 && !terminated, "declining uninstall confirmation leaves app intact")

      confirmResult = true
      _ = NSApp.sendAction(uninstallBtn.action!, to: uninstallBtn.target, from: uninstallBtn)
      check(system.uninstallCalls == 1 && terminated, "confirming uninstall removes app artifacts and terminates")
    }

    print("\(checks) onboarding and system settings checks passed")
  }
}
