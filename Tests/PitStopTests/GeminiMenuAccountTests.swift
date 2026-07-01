import XCTest
@testable import PitStop

final class GeminiMenuAccountTests: XCTestCase {
    func testGeminiSurfaces() {
        let both = MenuAccount(email: "a@x.com", source: .geminiBoth, planLabel: "AI Pro", isActive: true)
        XCTAssertEqual(both.provider, .gemini)
        XCTAssertTrue(both.isGemini)
        XCTAssertTrue(both.canSwitch)
        XCTAssertEqual(both.key, "gemini:a@x.com")
        XCTAssertEqual(both.surfaceTag, "CLI · Antigravity")

        XCTAssertEqual(MenuAccount(email: "a@x.com", source: .geminiCli, planLabel: "", isActive: false).surfaceTag, "CLI")
        XCTAssertEqual(MenuAccount(email: "a@x.com", source: .geminiAntigravity, planLabel: "", isActive: false).surfaceTag, "Antigravity")
        XCTAssertEqual(Provider.gemini.title, "Gemini")
    }
}
