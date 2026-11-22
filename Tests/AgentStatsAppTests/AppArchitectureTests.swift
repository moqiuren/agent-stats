@testable import StatsCore
@testable import StatsAdapters
@testable import AgentStatsApp
import AppKit

// Exercise boundaries through commands and independently retained controllers,
// not through AppDelegate implementation details or live host applications.
enum AppArchitectureTests {
  private final class Collector: StatsCollecting {
    let provider: StatsProvider
    var onUpdate: ((StatsUpdate) -> Void)?
    var starts = 0, stops = 0
    var updates = [(SessionSelectionMode, Bool?, Bool)]()
    var windows = [HostWindowReference?]()
    init(_ provider: StatsProvider) { self.provider = provider }
    func start() { starts += 1 }
    func stop() {
      stops += 1
      onUpdate = nil
    }
    func update(selection: SessionSelectionMode, paused: Bool?, refresh: Bool) {
      updates.append((selection, paused, refresh))
    }
    func observe(_ window: HostWindowReference?) { windows.append(window) }
    func publish(_ total: Int) {
      onUpdate?(
        StatsUpdate(
          snapshot: StatsSnapshot(
            provider: provider, collectedAt: 10000,
            sessions: [
              SessionSnapshot(["id": "recent", "title": "Recent", "totalTokens": total]),
              SessionSnapshot(["id": "old", "title": "Old", "totalTokens": 0]),
            ])))
    }
  }

  static func run() {
    var checks = 0
    func check(_ value: Bool, _ message: String) {
      precondition(value, message)
      checks += 1
    }
    let suite = "stats-architecture-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let configuration = StatsPreferencesStore(defaults)
    check(
      configuration.followsActiveTool && configuration.displayMode(for: .codex) == .floating,
      "configuration retains existing defaults")
    configuration.setSelectedSession("codex-pinned", for: .codex)
    configuration.setSelectedSession("__bridge__", for: .kimi)
    configuration.prepareLaunch(provider: .kimi, bridgeInstalled: true)
    check(
      configuration.selectedSession(for: .kimi) == "__current__"
        && configuration.selectedSession(for: .codex) == "codex-pinned",
      "launch migration updates only the legacy Kimi choice")
    configuration.setSelectedSession(nil, for: .kimi)
    configuration.prepareLaunch(provider: .kimi, bridgeInstalled: true)
    check(
      configuration.selectedSession(for: .kimi) == nil,
      "an installed bridge preserves the existing unspecified preference")
    configuration.prepareLaunch(provider: .kimi, bridgeInstalled: false)
    check(
      configuration.selectedSession(for: .kimi) == "__current__",
      "a missing bridge retains the native-follow launch default")
    check(
      configuration.placement(for: .codex).relativePosition == nil
        && configuration.placement(for: .codex).frame(
          host: CGRect(x: 0, y: 0, width: 900, height: 600),
          screen: CGRect(x: 0, y: 0, width: 1440, height: 900)).maxY == 592,
      "a tool without a dragged position starts centred on the host's top edge")
    var dragged = HUDPlacement(contentSize: CGSize(width: 400, height: 34))
    dragged.recordDrag(
      frame: CGRect(x: 120, y: 200, width: 400, height: 34),
      host: CGRect(x: 0, y: 0, width: 900, height: 600),
      screen: CGRect(x: 0, y: 0, width: 1440, height: 900))
    configuration.setPlacement(dragged, for: .kimi)
    let restoredPlacement = StatsPreferencesStore(defaults).placement(for: .kimi)
    check(
      restoredPlacement.relativePosition == dragged.relativePosition
        && configuration.placement(for: .codex).relativePosition == nil,
      "the dragged free position round-trips per tool without any edge or dock state")
    check(
      Set(defaults.dictionaryRepresentation().keys).filter {
        $0.hasPrefix("placement.kimi.")
      }.allSatisfy { $0.hasSuffix("relativeX") || $0.hasSuffix("relativeY") },
      "only the free position is stored, never a retired dock key")
    for retired in StatsPreferencesStore.retiredPlacementKeys {
      defaults.set(1, forKey: "placement.kimi." + retired)
    }
    // Leftovers from the removed Cursor product and from older unified builds.
    defaults.set("top", forKey: "placement.cursor.dock")
    defaults.set(0.5, forKey: "placement.cursor.relativeX")
    defaults.set([["id": "old", "metric": "usage"]], forKey: "hudModuleLayout.v1.cursor")
    defaults.set("floating", forKey: "displayMode.cursor")
    defaults.set([], forKey: "detailRows.v1.cursor")
    defaults.set("kimi-pinned", forKey: "selectedSession.kimi")
    configuration.removeRetiredPreferences()
    check(
      StatsPreferencesStore.retiredPlacementKeys.allSatisfy {
        defaults.object(forKey: "placement.kimi." + $0) == nil
          && defaults.object(forKey: "placement.codex." + $0) == nil
      },
      "retired docking keys are deleted instead of lingering in the preferences")
    check(
      ["placement.cursor.dock", "placement.cursor.relativeX", "hudModuleLayout.v1.cursor",
       "displayMode.cursor", "detailRows.v1.cursor"].allSatisfy {
        defaults.object(forKey: $0) == nil
      },
      "every leftover key of a removed tool is deleted")
    check(
      defaults.string(forKey: "selectedSession.kimi") == "kimi-pinned"
        && StatsPreferencesStore(defaults).placement(for: .kimi).relativePosition
          == dragged.relativePosition,
      "cleanup never touches a supported tool's own preferences")
    check(
      StatsPreferencesStore(defaults).placement(for: .kimi).relativePosition
        == dragged.relativePosition,
      "removing retired keys leaves the dragged position untouched")
    check(
      configuration.detailRowKeys(for: .codex) == DetailRowRegistry.defaultKeys(for: .codex)
        && configuration.detailRowKeys(for: .kimi).contains("usage.contextLength"),
      "every tool starts with every detail row it supports")
    configuration.setDetailRowKeys(["usage.total", "usage.contextLength", "not-a-row"], for: .kimi)
    let restored = StatsPreferencesStore(defaults).detailRowKeys(for: .kimi)
    check(
      restored == ["usage.total", "usage.contextLength"],
      "the store keeps the selected detail rows and drops unknown keys")
    check(
      configuration.detailRowKeys(for: .codex).count > restored.count,
      "another tool's detail rows remain independent")
    configuration.setDetailRowKeys([], for: .kimi)
    check(
      StatsPreferencesStore(defaults).detailRowKeys(for: .kimi).isEmpty,
      "an intentionally empty selection survives instead of falling back to the defaults")
    let slots = [HUDModule(id: "one", metric: .usage), HUDModule(id: "two", metric: .output)]
    configuration.setModules(slots, for: .codex)
    configuration.editModules(.move("two", -1), for: .codex)
    configuration.editModules(.replace("one", .speed), for: .codex)
    let reloaded = StatsPreferencesStore(defaults).modules(for: .codex)
    check(
      reloaded.map(\.id) == ["two", "one"] && reloaded.map(\.metric) == [.output, .speed],
      "module edits persist stable identities and order")

    var collectors = [Collector]()
    let app = AppCoordinator(
      preferences: defaults, provider: .codex,
      makeService: { provider, _ in
        let collector = Collector(provider)
        collectors.append(collector)
        return collector
      }, readHook: { nil })
    app.hud.makePanel()
    app.menu.makeStatus()
    app.hud.interactionMenuOpen = true
    defer {
      app.stop()
      app.hud.close()
      app.menu.removeStatusItem()
    }
    app.startReader()
    app.startReader()
    check(
      collectors.count == 1 && collectors[0].starts == 1,
      "repeated startup does not create a second collector")
    collectors[0].publish(42)
    let actions: StatsSettingsActions = app
    let updateCount = collectors[0].updates.count
    actions.selectSession("old")
    check(
      app.stats.current?.value(.totalTokens) == 0 && collectors[0].updates.count == updateCount + 1,
      "selecting through the settings boundary renders zero and refreshes the collector together")
    check(
      collectors[0].updates.last?.0 == .manual("old") && collectors[0].updates.last?.2 == true,
      "the collector receives the persisted manual selection")
    let beforeBrowse = collectors[0].updates.count
    actions.browseProject("project")
    check(
      app.selected == "old" && collectors[0].updates.count == beforeBrowse,
      "project browsing cannot change the conversation or trigger a collection")
    actions.selectRecentSession()
    check(
      app.stats.current?.id == "recent" && app.stats.current?.value(.totalTokens) == 42,
      "the recent-session action updates selection and presentation")
    let oldCallback = collectors[0].onUpdate!
    actions.selectProvider(.kimi)
    check(
      collectors.count == 2 && collectors[0].stops == 1 && collectors[1].starts == 1,
      "provider switching retires exactly the old service and starts its replacement")
    oldCallback(
      StatsUpdate(
        snapshot: StatsSnapshot(
          provider: .codex, collectedAt: 11000,
          sessions: [SessionSnapshot(["id": "recent", "totalTokens": 999])])))
    check(
      app.stats.catalog.sessions.isEmpty,
      "a retired collector cannot repopulate the new provider's catalog")
    collectors[1].publish(7)
    actions.selectRecentSession()
    check(
      app.stats.current?.value(.totalTokens) == 7 && configuration.activeProvider == .kimi,
      "the replacement collector and active-provider preference agree")
    let currentService = collectors[1]
    actions.selectProvider(.kimi)
    check(
      collectors.count == 2 && currentService.starts == 1,
      "reselecting the active tool keeps its collector")
    let count = app.modules.count
    actions.editModules(.add(.output))
    check(
      app.modules.count == count + 1 && app.hud.moduleButtons.count == app.modules.count
        && StatsPreferencesStore(defaults).modules(for: .kimi) == app.modules,
      "one module command updates persistence and the actual HUD")
    actions.setDisplayMode(.menuBar)
    check(
      app.displayMode == .menuBar && configuration.displayMode(for: .codex) == .floating
        && !app.hud.panel.isVisible,
      "display changes affect the active tool and hide its floating window")

    weak var released: AppCoordinator?
    var retainedHUD: HUDWindowController?
    var retainedMenu: StatusMenuController?
    autoreleasepool {
      let temporary = AppCoordinator(
        preferences: defaults, provider: .codex, makeService: { provider, _ in Collector(provider) }
      )
      released = temporary
      retainedHUD = temporary.hud
      retainedMenu = temporary.menu
    }
    check(released == nil, "controllers do not retain the application coordinator")
    check(
      retainedHUD!.preferredHUDSize().height == 28,
      "a retained controller can safely read configuration after its coordinator is released")
    retainedMenu!.showSettings()
    retainedMenu!.toggle()
    check(retainedMenu!.status == nil, "detached menu actions safely do nothing")
    retainedHUD = nil
    retainedMenu = nil

    check(
      Set(MetricRegistry.definitions.keys) == Set(HUDMetric.allCases),
      "every configurable metric has exactly one definition")
    check(
      !HUDMetric.available(for: "codex").contains(.contextLength)
        && HUDMetric.available(for: "kimi").contains(.contextLength),
      "provider-specific availability comes from the definition")
    let zero = StatsRecord([
      "input": 0, "cacheWrite": 5, "totalTokens": 0, "tps": 99,
      "lastTurn": ["tps": 0, "ttftMs": 0], "toolMs": NSNull(),
    ])
    let presenter = MetricPresenter(provider: .codex, record: zero)
    check(
      presenter.title(.speed) == "速度 0.0 tok/s"
        && presenter.title(.input) == "输入 5",
      "central definitions preserve zero speed and input including cache creation")
    check(
      presenter.presentation(.latency).accessibilityLabel.contains("0.00 秒")
        && presenter.title(.toolTime) == "工具 —",
      "formatting preserves zero latency and unknown duration")
    let state = StatsRecord([
      "backgroundRunning": 1, "backgroundTotal": 2, "pendingApprovals": 1, "pendingQuestions": 2,
      "backgroundItems": [["description": "Task", "startedAt": 90000]],
    ])
    let status = MetricPresenter(
      provider: .kimi, record: state, now: { 100000 },
      hookReport: {
        Lifecycle.HookReport(
          event: "Stop", sessionID: "synthetic", title: nil, source: nil, time: 1000)
      })
    let rows = Dictionary(uniqueKeysWithValues: status.content("kimi").0)
    check(
      status.title(.waitingUser) == "等待 3" && rows["Task"] == "运行中 · 已运行 10.0s"
        && rows["插件上报"]?.hasPrefix("Stop · ") == true,
      "Kimi detail rendering uses the supplied clock and hook source without changing semantics")
    print("\(checks) app architecture boundary checks passed")
  }
}
