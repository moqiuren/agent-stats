import XCTest
@testable import StatsCore
@testable import StatsAdapters
@testable import AgentStatsApp

final class AgentStatsAppTests: XCTestCase {
    func testCodexApplication() { AppTests.run(provider: .codex) }
    func testKimiApplication() { AppTests.run(provider: .kimi) }
    func testInspectorTests() throws { try InspectorTests.main() }
    func testOnboardingTests() { OnboardingTests.run() }
}
