import Foundation

/// Google Gemini provider: the Gemini CLI (~/.gemini/oauth_creds.json) and
/// Antigravity (keychain gemini/antigravity) surfaces, both authenticating one
/// Google account against the Code Assist backend (cloudcode-pa.googleapis.com).
enum Gemini {
    /// Which surface a credential blob came from — they use different OAuth
    /// clients and different on-disk formats.
    enum Surface { case cli, antigravity }

    struct Creds {
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
        var expiryMs: Double        // ms epoch; 0 = unknown
        var email: String
    }

    enum GeminiError: LocalizedError {
        case sessionExpired, malformed, notSignedIn
        var errorDescription: String? {
            switch self {
            case .sessionExpired: return "Gemini session expired — sign in again"
            case .malformed: return "Unexpected Gemini response"
            case .notSignedIn: return "Not signed in to Gemini"
            }
        }
    }

    private static let goKeyringPrefix = "go-keyring-base64:"

    /// The Antigravity keychain value is `"go-keyring-base64:" + base64(JSON)`.
    static func decodeGoKeyring(_ raw: String) -> Data? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix(goKeyringPrefix) else { return nil }
        return Data(base64Encoded: String(s.dropFirst(goKeyringPrefix.count)))
    }

    static func encodeGoKeyring(_ json: Data) -> String {
        goKeyringPrefix + json.base64EncodedString()
    }

    /// Parse the Gemini CLI `oauth_creds.json` blob.
    static func cliCreds(from blob: Data) -> Creds? {
        guard let root = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
              let access = root["access_token"] as? String, !access.isEmpty else { return nil }
        let idToken = root["id_token"] as? String
        return Creds(accessToken: access,
                     refreshToken: root["refresh_token"] as? String,
                     idToken: idToken,
                     expiryMs: (root["expiry_date"] as? NSNumber)?.doubleValue ?? 0,
                     email: idToken.flatMap(decodeJWTEmail) ?? "Gemini account")
    }

    /// Parse the Antigravity keychain blob (the whole `go-keyring-base64:` string).
    static func antigravityCreds(from blob: Data) -> Creds? {
        guard let raw = String(data: blob, encoding: .utf8),
              let json = decodeGoKeyring(raw),
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let tok = root["token"] as? [String: Any],
              let access = tok["access_token"] as? String, !access.isEmpty else { return nil }
        let idToken = tok["id_token"] as? String
        // expiry is ISO8601 with tz offset; convert to ms (0 if unparseable).
        var expiryMs: Double = 0
        if let e = tok["expiry"] as? String, let d = iso8601.date(from: e) {
            expiryMs = d.timeIntervalSince1970 * 1000
        }
        return Creds(accessToken: access,
                     refreshToken: tok["refresh_token"] as? String,
                     idToken: idToken,
                     expiryMs: expiryMs,
                     email: idToken.flatMap(decodeJWTEmail) ?? "Gemini account")
    }

    /// Email from an id_token JWT payload (email or profile.email). No verify.
    static func decodeJWTEmail(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var s = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let e = claims["email"] as? String { return e }
        if let p = claims["https://api.openai.com/profile"] as? [String: Any],
           let e = p["email"] as? String { return e }
        return nil
    }

    /// "gemini-3.1-pro-preview" -> "3.1-pro" (drop gemini- prefix and -preview suffix).
    static func shortModelName(_ modelId: String) -> String {
        var s = modelId
        if s.hasPrefix("gemini-") { s.removeFirst("gemini-".count) }
        if s.hasSuffix("-preview") { s.removeLast("-preview".count) }
        return s
    }

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withTimeZone]
        return f
    }()
}
