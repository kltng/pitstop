import XCTest
@testable import PitStop

final class LoopbackServerTests: XCTestCase {
    func testParseRequestLine() {
        let c = LoopbackServer.parse(requestLine: "GET /callback?code=ab%2Fc&state=xyz HTTP/1.1")
        XCTAssertEqual(c?.code, "ab/c")
        XCTAssertEqual(c?.state, "xyz")
        XCTAssertNil(LoopbackServer.parse(requestLine: "GET /favicon.ico HTTP/1.1"))
    }

    func testParsePastedFormats() {
        // Full redirect URL
        XCTAssertEqual(LoopbackServer.parsePasted(
            "https://platform.claude.com/oauth/code/callback?code=AAA&state=BBB")?.code, "AAA")
        // CODE#STATE
        let hash = LoopbackServer.parsePasted("AAA#BBB")
        XCTAssertEqual(hash?.code, "AAA"); XCTAssertEqual(hash?.state, "BBB")
        // urlencoded query fragment
        let q = LoopbackServer.parsePasted("code=AAA&state=BBB")
        XCTAssertEqual(q?.code, "AAA"); XCTAssertEqual(q?.state, "BBB")
        XCTAssertNil(LoopbackServer.parsePasted("   "))
    }

    func testRoundTrip() async throws {
        let srv = LoopbackServer()
        try srv.start(ports: [49260, 49261])
        defer { srv.stop() }
        XCTAssertGreaterThan(srv.port, 0)
        let waiter = Task { try await srv.waitForCallback(timeout: 5) }
        _ = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(srv.port)/callback?code=THECODE&state=THESTATE")!)
        let cap = try await waiter.value
        XCTAssertEqual(cap.code, "THECODE")
        XCTAssertEqual(cap.state, "THESTATE")
    }

    func testPortFallbackWhenBusy() throws {
        let hog = LoopbackServer(); try hog.start(ports: [49270]); defer { hog.stop() }
        let srv = LoopbackServer(); try srv.start(ports: [49270, 49271]); defer { srv.stop() }
        XCTAssertEqual(srv.port, 49271)
    }

    func testTimeoutThrows() async throws {
        let srv = LoopbackServer(); try srv.start(ports: [49280]); defer { srv.stop() }
        do {
            _ = try await srv.waitForCallback(timeout: 0.3)
            XCTFail("expected timeout")
        } catch { /* expected */ }
    }
}
