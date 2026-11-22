import Foundation
import XCTest
@testable import StatsCore

final class ClockStateTests: XCTestCase {
    func testAllStateTransitionsUseTheSuppliedTime() {
        var now = Date(timeIntervalSince1970: 100)
        let state = StatsState(provider: .codex, clock: { now })
        XCTAssertEqual(state.windowChangedAt, 100000)
        now.addTimeInterval(1); state.switchProvider(.kimi)
        XCTAssertEqual(state.windowChangedAt, 101000)
        now.addTimeInterval(1)
        let window = HostWindowReference(pid: 1, number: 2, bounds: .zero)
        state.observeWindow(window); XCTAssertEqual(state.windowChangedAt, 102000)
        now.addTimeInterval(1)
        state.receive(StatsUpdate(snapshot: StatsSnapshot(provider: .kimi, collectedAt: 102500)), generation: state.generation)
        XCTAssertEqual(state.lastReceived, now)
        now.addTimeInterval(1)
        state.receive(StatsUpdate(snapshot: StatsSnapshot(provider: .codex, collectedAt: 104000)), generation: state.generation)
        XCTAssertEqual(state.lastReceived, Date(timeIntervalSince1970: 103), "rejected providers do not advance reception time")
    }
}
