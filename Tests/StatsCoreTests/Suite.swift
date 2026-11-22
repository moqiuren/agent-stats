import XCTest
@testable import StatsCore

final class StatsCoreTests: XCTestCase {
    func testPlacementTests() throws { try PlacementTests.main() }
    func testStatsStateTests() throws { try StatsStateTests.main() }
    func testStatsSnapshotTests() throws { try StatsSnapshotTests.main() }
    func testTokenStatsTests() throws { try TokenStatsTests.main() }
    func testAppUpdateModelsTests() throws { try AppUpdateModelsTests.main() }
}
