import Foundation
import CommonCrypto

/// PKCE (RFC 7636, S256) helpers for the OAuth login flow. Pure and testable.
enum OAuthPKCE {
    /// Base64URL without padding — the encoding PKCE and OAuth `state` use.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// code_challenge = base64url(SHA256(code_verifier)).
    static func challenge(for verifier: String) -> String {
        let bytes = Data(verifier.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        bytes.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(bytes.count), &hash) }
        return base64URL(Data(hash))
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            // Never returns an error; still a CSPRNG on Darwin. An all-zero
            // buffer here would mean a fixed, predictable verifier and state.
            arc4random_buf(&bytes, count)
        }
        return Data(bytes)
    }

    static func randomVerifier(byteCount: Int = 64) -> String { base64URL(randomBytes(byteCount)) }
    static func randomState() -> String { base64URL(randomBytes(32)) }

    static func generate() -> (verifier: String, challenge: String, state: String) {
        let v = randomVerifier()
        return (v, challenge(for: v), randomState())
    }
}
