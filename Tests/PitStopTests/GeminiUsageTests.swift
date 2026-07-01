import XCTest
@testable import PitStop

final class GeminiUsageTests: XCTestCase {
    // Shape captured from the live retrieveUserQuota probe.
    private let quotaJSON = """
    {"buckets":[
      {"modelId":"gemini-3.1-pro-preview","remainingFraction":0.62,"resetTime":"2026-07-02T12:47:13Z","tokenType":"REQUESTS"},
      {"modelId":"gemini-3-pro-preview","remainingFraction":0.78,"resetTime":"2026-07-02T12:47:13Z","tokenType":"REQUESTS"},
      {"modelId":"gemini-2.5-flash","remainingFraction":0.95,"resetTime":"2026-07-02T12:47:13Z","tokenType":"REQUESTS"},
      {"modelId":"gemini-2.5-flash-lite","remainingFraction":1.0,"resetTime":"2026-07-02T12:47:13Z","tokenType":"REQUESTS"}
    ]}
    """

    func testParseQuotaBindingAndExtras() {
        let u = Gemini.parseQuota(Data(quotaJSON.utf8))
        XCTAssertEqual(u.windows.count, 4)
        // Binding = highest used% = 3.1-pro (0.62 remaining -> 38% used).
        XCTAssertEqual(Int(u.maxUtilization.rounded()), 38)
        let binding = u.windows.max { $0.usedPercent < $1.usedPercent }
        XCTAssertEqual(binding?.label, "3.1-pro")
        XCTAssertNotNil(binding?.resetsAt)
        // Extras = next non-zero models (3-pro 22%, 2.5-flash 5%); flash-lite 0% omitted.
        let extras = Gemini.extrasLine(u)
        XCTAssertEqual(extras, "3-pro 22% · 2.5-flash 5%")
    }

    func testParseQuotaEmpty() {
        let u = Gemini.parseQuota(Data("{}".utf8))
        XCTAssertTrue(u.windows.isEmpty)
        XCTAssertEqual(u.maxUtilization, 0)
        XCTAssertNil(Gemini.extrasLine(u))
    }

    func testParseLoadCodeAssist() {
        let json = """
        {"currentTier":{"id":"standard-tier","name":"Gemini Code Assist"},
         "paidTier":{"id":"g1-pro-tier","name":"Gemini Code Assist in Google One AI Pro"},
         "cloudaicompanionProject":"mimetic-moonlight-6khfj"}
        """
        let r = Gemini.parseLoadCodeAssist(Data(json.utf8))
        XCTAssertEqual(r.project, "mimetic-moonlight-6khfj")
        XCTAssertEqual(r.planLabel, "AI Pro")
    }
}
