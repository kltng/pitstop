import XCTest
@testable import PitStop

final class OpenCodeTests: XCTestCase {
    func testAPIKeyReadsOpenCodeGoEntryOnly() throws {
        let data = Data(#"{"openai":{"type":"api","key":"openai-key"},"opencode-go":{"type":"api","key":"go-key"}}"#.utf8)
        XCTAssertEqual(OpenCode.apiKey(from: data), "go-key")
    }

    func testAPIKeyRejectsOtherAuthShapes() throws {
        let data = Data(#"{"opencode-go":{"type":"oauth","key":"not-an-api-key"}}"#.utf8)
        XCTAssertNil(OpenCode.apiKey(from: data))
    }

    func testParseUsageMapsWindowsAndRelativeResets() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let data = Data(#"{"useBalance":true,"rollingUsage":{"usagePercent":65,"resetInSec":3600},"weeklyUsage":{"usagePercent":30,"resetInSec":7200},"monthlyUsage":{"usagePercent":12,"resetInSec":86400}}"#.utf8)

        let usage = try OpenCode.parseUsage(data, now: now)

        XCTAssertTrue(usage.useBalance)
        XCTAssertEqual(usage.windows.map(\.label), ["5h", "7d", "30d"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [65, 30, 12])
        XCTAssertEqual(usage.windows[0].resetsAt, now.addingTimeInterval(3600))
        XCTAssertEqual(usage.windows[2].resetsAt, now.addingTimeInterval(86400))
    }

    func testParseCurrentUsageShapeWithAbsoluteResets() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let data = Data(#"{"usage":{"rolling":{"percent":29,"resetsAt":"1970-01-01T01:16:40.000Z"},"weekly":{"percent":11,"resetsAt":"1970-01-01T02:00:00.000Z"},"monthly":{"percent":5,"resetsAt":"1970-01-02T00:00:00.000Z"}}}"#.utf8)

        let usage = try OpenCode.parseUsage(data, now: now)

        XCTAssertEqual(usage.windows.map(\.usedPercent), [29, 11, 5])
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 4600))
    }

    func testParseUsageClampsPercentages() throws {
        let data = Data(#"{"rollingUsage":{"usagePercent":120},"weeklyUsage":{"usagePercent":-5}}"#.utf8)
        let usage = try OpenCode.parseUsage(data)
        XCTAssertEqual(usage.windows.map(\.usedPercent), [100, 0])
    }

    // MARK: - Reset timestamps

    /// Go's RFC3339Nano omits the fraction entirely when it is zero, which is
    /// the common case on a whole-second reset boundary. A fractional-only
    /// formatter drops those silently, taking the projection clamp with them.
    func testParsesResetWithoutFractionalSeconds() throws {
        let data = Data(#"{"usage":{"rolling":{"percent":29,"resetsAt":"1970-01-01T01:16:40Z"}}}"#.utf8)
        let usage = try OpenCode.parseUsage(data)
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 4600))
    }

    /// The other half of RFC3339Nano: up to nine fractional digits, which
    /// ISO8601DateFormatter also refuses (it accepts milliseconds only).
    func testParsesResetWithNanosecondPrecision() throws {
        let data = Data(#"{"usage":{"rolling":{"percent":29,"resetsAt":"1970-01-01T01:16:40.123456789Z"}}}"#.utf8)
        let reset = try XCTUnwrap(OpenCode.parseUsage(data).windows[0].resetsAt)
        XCTAssertEqual(reset.timeIntervalSince1970, 4600, accuracy: 1)
    }

    func testParsesResetWithOffsetTimeZone() throws {
        let data = Data(#"{"usage":{"rolling":{"percent":1,"resetsAt":"1970-01-01T02:16:40+01:00"}}}"#.utf8)
        XCTAssertEqual(try OpenCode.parseUsage(data).windows[0].resetsAt,
                       Date(timeIntervalSince1970: 4600))
    }

    func testUnparseableResetLeavesWindowWithoutOne() throws {
        let data = Data(#"{"usage":{"rolling":{"percent":50,"resetsAt":"not a date"}}}"#.utf8)
        let usage = try OpenCode.parseUsage(data)
        XCTAssertEqual(usage.windows.map(\.usedPercent), [50])
        XCTAssertNil(usage.windows[0].resetsAt)
    }

    /// An absurd resetInSec used to become a Date so far out that formatting
    /// it trapped on Int conversion, crashing the menu on render.
    func testClampsAbsurdResetInSecAndFormatsWithoutTrapping() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let data = Data(#"{"rollingUsage":{"usagePercent":5,"resetInSec":1e300}}"#.utf8)
        let reset = try XCTUnwrap(OpenCode.parseUsage(data, now: now).windows[0].resetsAt)
        XCTAssertLessThanOrEqual(reset.timeIntervalSince(now), 400 * 86400)
        XCTAssertFalse(Format.compactReset(reset).isEmpty)
    }

    func testClampsAbsurdPercentage() throws {
        let data = Data(#"{"rollingUsage":{"usagePercent":1e300}}"#.utf8)
        XCTAssertEqual(try OpenCode.parseUsage(data).windows.map(\.usedPercent), [100])
    }

    /// A number too large for Double is rejected by JSONSerialization itself,
    /// so it surfaces as a thrown error rather than a non-finite reading.
    func testOverflowingNumberThrowsRatherThanProducingInfinity() {
        XCTAssertThrowsError(
            try OpenCode.parseUsage(Data(#"{"rollingUsage":{"usagePercent":1e400}}"#.utf8)))
    }

    // MARK: - Balance-funded accounts

    /// A balance-funded account legitimately reports no quota windows. Treating
    /// that as malformed pinned the row to a permanent error and made the
    /// "Balance" badge unreachable.
    func testBalanceFundedAccountWithNoWindowsIsNotMalformed() throws {
        let data = Data(#"{"useBalance":true,"balance":12.34}"#.utf8)
        let usage = try OpenCode.parseUsage(data)
        XCTAssertTrue(usage.useBalance)
        XCTAssertTrue(usage.windows.isEmpty)
        XCTAssertEqual(usage.maxUtilization, 0)
    }

    func testUseBalanceInsideUsageObjectIsHonored() throws {
        let data = Data(#"{"usage":{"useBalance":true}}"#.utf8)
        XCTAssertTrue(try OpenCode.parseUsage(data).useBalance)
    }

    /// Quota-funded payloads with nothing parseable are still an error.
    func testEmptyPayloadStillThrows() {
        XCTAssertThrowsError(try OpenCode.parseUsage(Data(#"{}"#.utf8)))
        XCTAssertThrowsError(try OpenCode.parseUsage(Data(#"{"useBalance":false}"#.utf8)))
        XCTAssertThrowsError(try OpenCode.parseUsage(Data("[]".utf8)))
    }

    // MARK: - Auth file location

    func testAuthURLHonorsXDGDataHome() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(OpenCode.authURL(xdgDataHome: "/custom/data", home: home).path,
                       "/custom/data/opencode/auth.json")
    }

    func testAuthURLFallsBackForUnsetOrRelativeXDG() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let fallback = "/Users/someone/.local/share/opencode/auth.json"
        XCTAssertEqual(OpenCode.authURL(xdgDataHome: nil, home: home).path, fallback)
        XCTAssertEqual(OpenCode.authURL(xdgDataHome: "", home: home).path, fallback)
        // Relative paths are invalid per the XDG spec and must be ignored.
        XCTAssertEqual(OpenCode.authURL(xdgDataHome: "relative/data", home: home).path, fallback)
    }

    // MARK: - Cache decoding

    /// Synthesized decoding ignores property defaults, and one throw here
    /// discards the whole shared snapshot — every other provider included.
    func testUsageDecodesWhenDefaultedFieldsAreAbsent() throws {
        let json = Data(#"{"windows":[{"label":"5h","usedPercent":42}]}"#.utf8)
        let usage = try JSONDecoder().decode(OpenCode.Usage.self, from: json)
        XCTAssertEqual(usage.windows.map(\.usedPercent), [42])
        XCTAssertFalse(usage.useBalance)
        // No stamp means the entry can't be aged, so it must not pass as fresh.
        XCTAssertEqual(usage.fetchedAt, .distantPast)
    }

    func testUsageRoundTrips() throws {
        let usage = OpenCode.Usage(
            windows: [.init(label: "5h", usedPercent: 12, resetsAt: Date(timeIntervalSince1970: 90))],
            useBalance: true,
            fetchedAt: Date(timeIntervalSince1970: 60))
        let decoded = try JSONDecoder().decode(
            OpenCode.Usage.self, from: JSONEncoder().encode(usage))
        XCTAssertEqual(decoded, usage)
    }

    // MARK: - Account identity

    /// The storage key is written in one place and derived in another; they
    /// have to agree or the fetcher and the row look at different entries.
    func testAccountKeyMatchesMenuAccountDerivation() {
        let row = MenuAccount(email: OpenCode.accountName, source: .openCodeGo,
                              planLabel: "Go", isActive: true)
        XCTAssertEqual(row.key, OpenCode.accountKey)
        XCTAssertEqual(row.provider, .openCode)
        XCTAssertFalse(row.canSwitch)
    }
}
