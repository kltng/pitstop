import XCTest
@testable import PitStop

@MainActor
final class GeminiRowTests: XCTestCase {
    func testGeminiSourceMerge() {
        XCTAssertEqual(AppDelegate.geminiSource(onCli: true, onAntigravity: true), .geminiBoth)
        XCTAssertEqual(AppDelegate.geminiSource(onCli: true, onAntigravity: false), .geminiCli)
        XCTAssertEqual(AppDelegate.geminiSource(onCli: false, onAntigravity: true), .geminiAntigravity)
    }
}
