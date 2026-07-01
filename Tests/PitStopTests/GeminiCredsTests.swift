import XCTest
@testable import PitStop

final class GeminiCredsTests: XCTestCase {
    private func b64url(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func testCliCredsParse() {
        let jwt = "\(b64url("{}")).\(b64url(#"{"email":"user@example.com"}"#)).sig"
        let blob = try! JSONSerialization.data(withJSONObject: [
            "access_token": "AT", "refresh_token": "RT", "id_token": jwt,
            "scope": "cloud-platform", "token_type": "Bearer", "expiry_date": 1782897780386,
        ])
        let c = Gemini.cliCreds(from: blob)
        XCTAssertEqual(c?.accessToken, "AT")
        XCTAssertEqual(c?.refreshToken, "RT")
        XCTAssertEqual(c?.expiryMs, 1782897780386)
        XCTAssertEqual(c?.email, "user@example.com")
    }

    func testGoKeyringRoundTripAndAntigravityCreds() {
        let jwt = "\(b64url("{}")).\(b64url(#"{"email":"a@x.com"}"#)).sig"
        let inner = try! JSONSerialization.data(withJSONObject: [
            "token": ["access_token": "AT2", "token_type": "Bearer",
                      "refresh_token": "RT2", "id_token": jwt,
                      "expiry": "2026-07-01T16:15:44+05:30"],
            "auth_method": "consumer",
        ])
        let wrapped = Gemini.encodeGoKeyring(inner)
        XCTAssertTrue(wrapped.hasPrefix("go-keyring-base64:"))
        let back = Gemini.decodeGoKeyring(wrapped)
        XCTAssertNotNil(back)
        let c = Gemini.antigravityCreds(from: Data(wrapped.utf8))
        XCTAssertEqual(c?.accessToken, "AT2")
        XCTAssertEqual(c?.refreshToken, "RT2")
        XCTAssertEqual(c?.email, "a@x.com")
    }

    func testShortModelName() {
        XCTAssertEqual(Gemini.shortModelName("gemini-3.1-pro-preview"), "3.1-pro")
        XCTAssertEqual(Gemini.shortModelName("gemini-2.5-flash"), "2.5-flash")
        XCTAssertEqual(Gemini.shortModelName("gemini-3-pro-preview"), "3-pro")
        XCTAssertEqual(Gemini.shortModelName("gemini-2.5-flash-lite"), "2.5-flash-lite")
    }
}
