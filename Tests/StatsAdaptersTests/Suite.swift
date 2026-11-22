import XCTest
@testable import StatsCore
@testable import StatsAdapters

final class StatsAdaptersTests: XCTestCase {
    func testCurrentSessionTests() throws { try CurrentSessionTests.main() }
    func testHostAccessibilityTests() throws { try HostAccessibilityTests.main() }
    func testProviderReaderTests() throws { try ProviderReaderTests.main() }
    func testAppInstallationTests() throws { try AppInstallationTests.main() }
    func testUsageHistoryReaderTests() throws { try UsageHistoryReaderTests.main() }
    func testAppUpdaterTests() throws { try AppUpdaterTests.main() }
}
