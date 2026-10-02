import XCTest
@testable import PitStop

final class ProviderDashboardTests: XCTestCase {
    func testDashboardURLs() {
        XCTAssertEqual(Provider.claude.dashboardURL?.absoluteString,
                       "https://claude.ai/new#settings/usage")
        XCTAssertEqual(Provider.codex.dashboardURL?.absoluteString,
                       "https://chatgpt.com/codex/cloud/settings/analytics#usage")
        XCTAssertEqual(Provider.gemini.dashboardURL?.absoluteString,
                       "https://gemini.google.com/usage")
        // opencode.ai/auth is the Go console — despite the path, it's where
        // the docs say subscribers track usage, not just a sign-in page.
        XCTAssertEqual(Provider.openCode.dashboardURL?.absoluteString,
                       "https://opencode.ai/auth")
    }

    func testEveryProviderHasADashboard() {
        for p in Provider.allCases { XCTAssertNotNil(p.dashboardURL, "\(p) missing dashboardURL") }
    }
}
