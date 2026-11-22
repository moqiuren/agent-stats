import AppKit
import XCTest
@testable import StatsCore
@testable import StatsAdapters
@testable import AgentStatsApp

private final class AppClock: StatsClock {
    var now = Date(timeIntervalSince1970: 100)
    var uptime: TimeInterval = 0
}
private final class AppScheduler: StatsScheduling {
    final class Job: StatsCancellation {
        let interval: TimeInterval?, tolerance: TimeInterval
        var cancelled = false
        init(_ interval: TimeInterval?, _ tolerance: TimeInterval) { self.interval = interval; self.tolerance = tolerance }
        func cancel() { cancelled = true }
    }
    var isIsolated: Bool { true }
    var jobs = [Job]()
    func execute(_ action: @escaping () -> Void) { action() }
    func schedule(after delay: TimeInterval, repeating interval: TimeInterval?, tolerance: TimeInterval, _ action: @escaping () -> Void) -> StatsCancellation {
        let job = Job(interval, tolerance); jobs.append(job); return job
    }
}
private final class AppBridge: PageSelectionBridging {
    var starts = 0, stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func snapshot() -> PageSessionSelection { PageSessionSelection() }
}
private final class AppHostMonitor: HostWindowMonitoring {
    func reset() {}
    func observe(windows: [HostWindowReference], requireFocused: Bool, provider: String) -> UInt32? { nil }
}
private final class AppSessionMonitor: CurrentSessionMonitoring {
    var onChange: ((CurrentSession) -> Void)?
    func start() {}
    func stop() { onChange = nil }
    func observe(_ window: HostWindowReference?) {}
    func setEnabled(_ enabled: Bool) {}
}
private final class AppReader: StatsReading {
    let provider: StatsProvider
    init(_ provider: StatsProvider) { self.provider = provider }
    func scan(selected: String?, now: Double) -> StatsSnapshot { StatsSnapshot(provider: provider, collectedAt: now) }
}

final class AppRuntimeInjectionTests: XCTestCase {
    func testCompositionSharesClockAndBridgeAndCancelsTimers() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "stats-runtime-ui-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = AppClock(), scheduler = AppScheduler(), bridge = AppBridge()
        let runtime = AppRuntimeDependencies(clock: clock, uiScheduler: scheduler, bridge: bridge,
                                             makeHostMonitor: { AppHostMonitor() }, makeSessionMonitor: { _ in AppSessionMonitor() })
        let readers = StatsReaderStore(clock: clock, scheduler: scheduler, factory: { AppReader($0) })
        let app = AppCoordinator(preferences: defaults, provider: .codex, readers: readers, runtime: runtime, readHook: { nil })
        app.followsActiveTool = false; app.hud.interactionMenuOpen = true
        app.start(); app.start()
        XCTAssertEqual(bridge.starts, 1)
        XCTAssertEqual(scheduler.jobs.filter { $0.interval == 0.1 }.count, 1)
        XCTAssertEqual(scheduler.jobs.first { $0.interval == 0.1 }?.tolerance, 0.05)
        XCTAssertEqual(app.stats.lastReceived, clock.now)
        clock.now.addTimeInterval(5); app.switchProvider(.kimi)
        XCTAssertEqual(bridge.starts, 2); XCTAssertEqual(bridge.stops, 0)
        XCTAssertEqual(app.stats.windowChangedAt, 105000)
        XCTAssertEqual(app.metrics.now(), 105000)
        clock.now.addTimeInterval(1)
        app.observeWindow(HostWindowReference(pid: 1, number: 2, bounds: .zero))
        XCTAssertEqual(app.stats.windowChangedAt, 106000)
        app.stop()
        XCTAssertEqual(bridge.stops, 1)
        XCTAssertTrue(scheduler.jobs.allSatisfy(\.cancelled))

        weak var released: AppCoordinator?
        var presentation: MetricPresenter?
        autoreleasepool {
            let temporary = AppCoordinator(preferences: defaults, runtime: runtime)
            released = temporary; presentation = temporary.metrics
        }
        XCTAssertNil(released, "a retained presenter must retain the clock, not the coordinator")
        clock.now.addTimeInterval(1)
        XCTAssertEqual(presentation?.now(), 107000)
    }
}
