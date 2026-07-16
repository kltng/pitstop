import XCTest
@testable import PitStop

final class SessionWarmingSettingsTests: XCTestCase {
    private let keys = ["sessionWarmingEnabled", "warmWindowStartMinutes",
                        "warmWindowEndMinutes"]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    func testDefaults() {
        XCTAssertFalse(Settings.sessionWarmingEnabled)      // opt-in
        XCTAssertEqual(Settings.warmWindowStartMinutes, 360)  // 6:00 AM
        XCTAssertEqual(Settings.warmWindowEndMinutes, 1080)   // 6:00 PM
    }

    func testStoredValuesHonoredIncludingMidnight() {
        UserDefaults.standard.set(true, forKey: "sessionWarmingEnabled")
        UserDefaults.standard.set(0, forKey: "warmWindowStartMinutes")
        UserDefaults.standard.set(720, forKey: "warmWindowEndMinutes")
        XCTAssertTrue(Settings.sessionWarmingEnabled)
        XCTAssertEqual(Settings.warmWindowStartMinutes, 0)   // midnight ≠ "unset"
        XCTAssertEqual(Settings.warmWindowEndMinutes, 720)
    }

    func testObservedKeysIncludeWarmingKeys() {
        keys.forEach { XCTAssertTrue(Settings.observedKeys.contains($0)) }
    }
}
