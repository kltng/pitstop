import XCTest
@testable import PitStop

/// maxUtilization(kinds:) — auto-switch's filtered view of each provider's
/// usage. nil means "no enabled window reports a number": never a trigger,
/// never a target.
final class LimitKindFilterTests: XCTestCase {
    // MARK: Claude (UsageReport)

    private func claudeReport(fiveHour: Double? = nil, sevenDay: Double? = nil,
                              scoped: [(String, Double)] = []) -> UsageReport {
        var r = UsageReport()
        if let fiveHour { r.fiveHour = UsageWindow(utilization: fiveHour, resetsAt: nil) }
        if let sevenDay { r.sevenDay = UsageWindow(utilization: sevenDay, resetsAt: nil) }
        r.scoped = scoped.map {
            ScopedWindow(label: $0.0, window: UsageWindow(utilization: $0.1, resetsAt: nil))
        }
        return r
    }

    func testClaudeFullSetMatchesBindingMax() {
        let r = claudeReport(fiveHour: 10, sevenDay: 20, scoped: [("Fable", 95)])
        XCTAssertEqual(r.maxUtilization(kinds: Set(LimitKind.allCases)), 95)
        XCTAssertEqual(r.maxUtilization(kinds: Set(LimitKind.allCases)), r.maxUtilization)
    }

    func testClaudeDisabledPerModelIgnoresHotFable() {
        let r = claudeReport(fiveHour: 10, sevenDay: 20, scoped: [("Fable", 95)])
        XCTAssertEqual(r.maxUtilization(kinds: [.session, .weekly]), 20)
    }

    func testClaudeSessionOnly() {
        let r = claudeReport(fiveHour: 64, sevenDay: 80, scoped: [("Fable", 95)])
        XCTAssertEqual(r.maxUtilization(kinds: [.session]), 64)
    }

    func testClaudeNoEnabledWindowWithDataIsNil() {
        let r = claudeReport(scoped: [("Fable", 95)])
        XCTAssertNil(r.maxUtilization(kinds: [.session, .weekly]))
    }

    func testClaudeWindowWithoutNumberDoesNotCount() {
        var r = claudeReport(sevenDay: 20)
        r.fiveHour = UsageWindow(utilization: nil, resetsAt: nil)
        XCTAssertEqual(r.maxUtilization(kinds: [.session, .weekly]), 20)
        XCTAssertNil(r.maxUtilization(kinds: [.session]))
    }
}
