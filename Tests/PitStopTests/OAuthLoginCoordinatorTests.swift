import XCTest
@testable import PitStop

/// Records what `persist` was called with; returns canned exchange/identity.
final class FakeAdapter: LoginAdapter, @unchecked Sendable {
    var provider: Provider { .claude }
    var loopbackPorts: [UInt16] { [51900] }
    var loopbackPath: String { "/callback" }
    var supportsPaste: Bool { false }
    var pasteRedirectURI: String { "" }
    var identityToReturn = LoginIdentity(email: "match@example.com", accountID: nil)
    var persistedEmails: [String] = []

    func authorizeURL(challenge: String, state: String, redirectURI: String, pasteMode: Bool) -> URL {
        URL(string: "https://example.com/authorize")!
    }
    func exchange(code: String, state: String, verifier: String, redirectURI: String) async throws -> FreshTokens {
        FreshTokens(accessToken: "A", refreshToken: "R", idToken: nil, expiresAtMs: 1)
    }
    func identity(from tokens: FreshTokens) async throws -> LoginIdentity { identityToReturn }
    func buildBlob(old: Data, tokens: FreshTokens) throws -> Data { Data() }
    func persist(_ tokens: FreshTokens, email: String) async throws { persistedEmails.append(email) }
}

final class OAuthLoginCoordinatorTests: XCTestCase {
    func testEmailMatchNormalizes() {
        XCTAssertTrue(OAuthLoginCoordinator.emailMatches(
            expected: "User@Example.com ", LoginIdentity(email: "user@example.com", accountID: nil)))
        XCTAssertFalse(OAuthLoginCoordinator.emailMatches(
            expected: "a@x.com", LoginIdentity(email: "b@x.com", accountID: nil)))
    }

    func testFinishPersistsOnMatch() async throws {
        let a = FakeAdapter()
        try await OAuthLoginCoordinator().finish(
            adapter: a, expectedEmail: "match@example.com",
            code: "C", state: "S", verifier: "V", redirectURI: "http://localhost:51900/callback")
        XCTAssertEqual(a.persistedEmails, ["match@example.com"])
    }

    func testFinishRejectsOnMismatch() async {
        let a = FakeAdapter()
        a.identityToReturn = LoginIdentity(email: "other@example.com", accountID: nil)
        do {
            try await OAuthLoginCoordinator().finish(
                adapter: a, expectedEmail: "match@example.com",
                code: "C", state: "S", verifier: "V", redirectURI: "x")
            XCTFail("expected mismatch")
        } catch {
            guard case LoginError.identityMismatch = error else {
                return XCTFail("expected .identityMismatch, got \(error)")
            }
            XCTAssertTrue(a.persistedEmails.isEmpty)   // nothing written
        }
    }
}
