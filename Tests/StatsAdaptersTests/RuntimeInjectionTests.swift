import Foundation
import XCTest
@testable import StatsCore
@testable import StatsAdapters

private final class TestClock: StatsClock {
    var now = Date(timeIntervalSince1970: 1000)
    var uptime: TimeInterval = 0
    func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds); uptime += seconds }
}
private final class ManualScheduler: StatsScheduling {
    final class Task: StatsCancellation {
        var deadline: TimeInterval
        let interval: TimeInterval?
        let tolerance: TimeInterval
        let action: () -> Void
        var cancelled = false
        init(_ deadline: TimeInterval, _ interval: TimeInterval?, _ tolerance: TimeInterval, _ action: @escaping () -> Void) {
            self.deadline = deadline; self.interval = interval; self.tolerance = tolerance; self.action = action
        }
        func cancel() { cancelled = true }
    }
    let clock: TestClock
    var isIsolated = false
    var jobs = [() -> Void]()
    var tasks = [Task]()
    init(_ clock: TestClock) { self.clock = clock }
    func execute(_ action: @escaping () -> Void) { jobs.append(action) }
    func schedule(after delay: TimeInterval, repeating interval: TimeInterval?, tolerance: TimeInterval, _ action: @escaping () -> Void) -> StatsCancellation {
        let task = Task(clock.uptime + delay, interval, tolerance, action); tasks.append(task); return task
    }
    func drain() {
        precondition(!isIsolated); isIsolated = true; defer { isIsolated = false }
        var budget = 1000
        while budget > 0 {
            budget -= 1
            if !jobs.isEmpty { jobs.removeFirst()(); continue }
            guard let next = tasks.first(where: { !$0.cancelled && $0.deadline <= clock.uptime }) else { return }
            if let interval = next.interval { next.deadline = clock.uptime + interval } else { next.cancelled = true }
            next.action()
        }
        XCTFail("manual scheduler did not quiesce")
    }
    var activeTasks: [Task] { tasks.filter { !$0.cancelled } }
}
private final class Monitor: CurrentSessionMonitoring {
    var onChange: ((CurrentSession) -> Void)?
    var starts = 0, stops = 0
    var enabled = false
    var window: HostWindowReference?
    func start() { starts += 1 }
    func stop() { stops += 1; onChange = nil }
    func setEnabled(_ enabled: Bool) { self.enabled = enabled }
    func observe(_ window: HostWindowReference?) { self.window = window }
}
private final class Bridge: PageSelectionBridging {
    var starts = 0, reads = 0, stops = 0
    var selection = PageSessionSelection(["status": "connected", "known": true, "sessionId": "session_fixture", "focused": true, "visible": true, "updatedAt": 1000000])
    func start() { starts += 1 }
    func snapshot() -> PageSessionSelection { reads += 1; return selection }
    func stop() { stops += 1 }
}
private final class Reader: StatsReading {
    let provider: StatsProvider
    var selections = [String?]()
    init(_ provider: StatsProvider) { self.provider = provider }
    func scan(selected: String?, now: Double) -> StatsSnapshot {
        selections.append(selected)
        return StatsSnapshot(provider: provider, collectedAt: now, sessions: [SessionSnapshot(["id": "fixture", "totalTokens": 0, "updatedAt": now])])
    }
}

final class RuntimeInjectionTests: XCTestCase {
    func testCollectorClockPauseCancellationAndBridgeOwnership() {
        let clock = TestClock(), bridge = Bridge(), monitor = Monitor()
        let worker = ManualScheduler(clock), ui = ManualScheduler(clock), reader = Reader(.kimi)
        let store = StatsReaderStore(clock: clock, scheduler: worker, factory: { $0 == .kimi ? reader : Reader($0) })
        let service = NativeStatsService(provider: .kimi, readers: store, bridge: bridge, clock: clock, uiScheduler: ui, monitor: monitor)
        var updates = [StatsUpdate]()
        service.onUpdate = { updates.append($0) }
        service.start(); worker.drain()
        XCTAssertTrue(updates.isEmpty, "publication stays on the injected UI scheduler")
        ui.drain()
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(bridge.starts, 1); XCTAssertEqual(bridge.reads, 1)
        XCTAssertEqual(updates[0].pageSelection?.sessionID, "session_fixture")
        guard case .replace(let catalog) = updates[0].catalog else { return XCTFail("missing catalog") }
        XCTAssertEqual(number(catalog.sessions[0].values["updatedAt"]), clock.milliseconds)
        XCTAssertEqual(worker.activeTasks.map(\.interval), [1.5])
        service.update(selection: .manual("pinned"), paused: true, refresh: true); worker.drain(); ui.drain()
        clock.advance(1.5); worker.drain(); ui.drain()
        XCTAssertEqual(reader.selections.count, 1, "paused timers never read")
        service.update(selection: .manual("pinned"), paused: false, refresh: true); worker.drain(); ui.drain()
        XCTAssertEqual(reader.selections.last!, "pinned")
        let window = HostWindowReference(pid: 1, number: 2, bounds: .zero)
        service.observe(window); XCTAssertEqual(monitor.window, window)
        let late = monitor.onChange!
        service.stop(); worker.drain(); ui.drain()
        let count = reader.selections.count, publications = updates.count
        late(CurrentSession(.current, id: "old", window: window.token)); clock.advance(15); worker.drain(); ui.drain()
        XCTAssertEqual(reader.selections.count, count); XCTAssertEqual(updates.count, publications)
        XCTAssertTrue(worker.activeTasks.isEmpty); XCTAssertEqual(monitor.stops, 1)
        XCTAssertEqual(bridge.stops, 0, "a replaceable collector never stops the process-owned bridge")
        let codex = NativeStatsService(provider: .codex, readers: store, bridge: bridge, clock: clock, uiScheduler: ui, monitor: Monitor())
        codex.start(); worker.drain(); ui.drain()
        XCTAssertEqual(bridge.starts, 2); XCTAssertEqual(bridge.reads, 2, "Codex does not consume a Kimi page selection")
        codex.stop(); worker.drain(); ui.drain()
    }

    func testReaderRetentionUsesMonotonicTime() {
        let clock = TestClock(), worker = ManualScheduler(clock)
        // One clock supplies the retention decision; wall time may jump independently.
        var creations = 0
        let store = StatsReaderStore(idleLifetime: 60, clock: clock, scheduler: worker, factory: { provider in creations += 1; return Reader(provider) })
        func scan() { worker.execute { _ = store.scan(provider: .codex, selected: nil, now: clock.milliseconds) }; worker.drain() }
        scan(); clock.now.addTimeInterval(86400); scan(); XCTAssertEqual(creations, 1)
        clock.uptime = 61; scan(); XCTAssertEqual(creations, 2)
    }

    func testCurrentSessionPollingCanBeDrivenWithoutSleeping() {
        let clock = TestClock(), worker = ManualScheduler(clock)
        var identifier = "one", reads = 0
        let monitor = CurrentSessionMonitor(provider: "kimi", clock: clock, scheduler: worker, read: { _, window in
            reads += 1; return CurrentSession(.current, id: identifier, window: window.token)
        })
        var results = [CurrentSession]()
        monitor.onChange = { results.append($0) }
        monitor.start(); monitor.start(); monitor.setEnabled(true)
        let window = HostWindowReference(pid: 1, number: 2, bounds: .zero)
        monitor.observe(window); worker.drain()
        XCTAssertEqual(worker.activeTasks.count, 1); XCTAssertEqual(worker.activeTasks.first?.interval, 0.5)
        XCTAssertEqual(results.last?.sessionID, "one")
        identifier = "two"; worker.clock.advance(0.5); worker.drain()
        XCTAssertEqual(results.last?.sessionID, "two")
        monitor.setEnabled(false); worker.drain(); let before = reads
        worker.clock.advance(0.5); worker.drain(); XCTAssertEqual(reads, before)
        monitor.stop(); worker.drain(); XCTAssertTrue(worker.activeTasks.isEmpty)
    }

    func testWindowProofDiscardsLateAndExpiredResults() {
        let clock = TestClock(), worker = ManualScheduler(clock), ui = ManualScheduler(clock)
        var authorized = true
        let monitor = HostWindowMonitor(clock: clock, scheduler: worker, uiScheduler: ui, authorized: { authorized }, readWindow: { _, windows, _ in
            HUDHostVerification(number: windows[0].number, focusConfirmed: true)
        })
        let first = HostWindowReference(pid: 1, number: 1, bounds: .zero), second = HostWindowReference(pid: 1, number: 2, bounds: .zero)
        XCTAssertNil(monitor.observe(windows: [first], requireFocused: true, provider: "kimi"))
        XCTAssertNil(monitor.observe(windows: [second], requireFocused: true, provider: "kimi"))
        worker.drain(); ui.drain()
        XCTAssertNil(monitor.observe(windows: [second], requireFocused: true, provider: "kimi"), "the first window's delayed proof cannot identify the second")
        worker.drain(); ui.drain()
        XCTAssertEqual(monitor.observe(windows: [second], requireFocused: true, provider: "kimi"), 2)
        clock.advance(0.76)
        XCTAssertNil(monitor.observe(windows: [second], requireFocused: true, provider: "kimi"), "expired proof fails closed while the next read is pending")
        worker.drain(); authorized = false; ui.drain()
        XCTAssertNil(monitor.observe(windows: [second], requireFocused: true, provider: "kimi"))
    }

    func testParseCacheFlushUsesInjectedClock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cache.json"), clock = TestClock()
        let cache = ParseCacheStore(path: file, clock: clock)
        cache.store("fixture", ["counter": 1]); cache.flushIfDue(interval: 60)
        let initial = try Data(contentsOf: file)
        cache.store("fixture", ["counter": 2]); clock.advance(59); cache.flushIfDue(interval: 60)
        XCTAssertEqual(try Data(contentsOf: file), initial)
        clock.advance(1); cache.flushIfDue(interval: 60)
        XCTAssertNotEqual(try Data(contentsOf: file), initial)
    }
}
