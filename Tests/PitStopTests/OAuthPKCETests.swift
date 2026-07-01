import XCTest
@testable import PitStop

final class OAuthPKCETests: XCTestCase {
    // RFC 7636 Appendix B known-answer vector.
    func testChallengeMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(OAuthPKCE.challenge(for: verifier),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testVerifierIsBase64URLAndRandom() {
        let a = OAuthPKCE.randomVerifier()
        let b = OAuthPKCE.randomVerifier()
        XCTAssertNotEqual(a, b)
        XCTAssertNil(a.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertGreaterThanOrEqual(a.count, 43)   // RFC 7636 minimum
    }

    func testGenerateIsConsistent() {
        let g = OAuthPKCE.generate()
        XCTAssertEqual(OAuthPKCE.challenge(for: g.verifier), g.challenge)
        XCTAssertFalse(g.state.isEmpty)
    }
}
