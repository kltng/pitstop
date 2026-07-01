import XCTest
@testable import PitStop

final class FormatTests: XCTestCase {
    func testRelativeShort() {
        XCTAssertEqual(Format.relativeShort(45), "<1m")     // was "0m"
        XCTAssertEqual(Format.relativeShort(-90), "<1m")    // elapsed clamps
        XCTAssertEqual(Format.relativeShort(60), "1m")
        XCTAssertEqual(Format.relativeShort(3 * 3600 + 34 * 60), "3h 34m")
        XCTAssertEqual(Format.relativeShort(5 * 86400 + 16 * 3600), "5d 16h")
    }

    func testRelative() {
        XCTAssertEqual(Format.relative(-5), "now")          // was "in 0s"
        XCTAssertEqual(Format.relative(45), "in 45s")
        XCTAssertEqual(Format.relative(5 * 60), "in 5m")
    }
}
