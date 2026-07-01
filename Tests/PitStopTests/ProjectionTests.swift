import XCTest
@testable import PitStop

@MainActor
final class ProjectionTests: XCTestCase {
    private let delegate = AppDelegate()

    /// Samples rising at `ratePerHour` %/h over the past `minutes`, ending at `current`.
    private func samples(rate ratePerHour: Double, minutes: Double, endingAt current: Double)
        -> [(date: Date, util: Double)] {
        let now = Date()
        return stride(from: -minutes, through: 0, by: minutes / 4).map { m in
            (date: now.addingTimeInterval(m * 60),
             util: current + ratePerHour * (m / 60))
        }
    }

    func testLowWindowFarETAIsSuppressed() {
        // 10% used at ~18%/h → ETA ~5h out: noise, no projection.
        let s = samples(rate: 18, minutes: 20, endingAt: 10)
        XCTAssertNil(delegate.projectedFull(samples: s, current: 10, resetsAt: nil))
    }

    func testHotWindowProjects() {
        // Same pace but already 30% used → projection shows.
        let s = samples(rate: 18, minutes: 20, endingAt: 30)
        XCTAssertNotNil(delegate.projectedFull(samples: s, current: 30, resetsAt: nil))
    }

    func testImminentETAProjectsEvenWhenLow() {
        // 10% used but ~45%/h → ETA ~2h: warn even below the floor.
        let s = samples(rate: 45, minutes: 20, endingAt: 10)
        XCTAssertNotNil(delegate.projectedFull(samples: s, current: 10, resetsAt: nil))
    }
}
