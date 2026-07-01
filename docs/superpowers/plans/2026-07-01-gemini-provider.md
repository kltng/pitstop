# Gemini Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Gemini" provider to PitStop that tracks the Google-account Code Assist usage and switches accounts across the Gemini CLI + Antigravity surfaces, with auto-switch and in-app re-login.

**Architecture:** Mirror the existing Codex provider. `Gemini.swift` = network/parsing (Google token refresh + `loadCodeAssist`/`retrieveUserQuota` + usage mapping); `GeminiStore.swift` = two live stores (CLI file `~/.gemini/oauth_creds.json` + Antigravity keychain `gemini/antigravity`) with per-account snapshots and switch-both; `GeminiLoginAdapter.swift` = re-login via the existing `OAuthLoginCoordinator`. `AppDelegate` grows a third provider the same way it holds Codex.

**Tech Stack:** Swift 6 (language mode v5), AppKit, Foundation, Darwin, CommonCrypto. No new third-party deps. SwiftPM XCTest.

**Spec:** `docs/superpowers/specs/2026-07-01-gemini-provider-design.md`

## Global Constraints

- macOS 26+; `swift-tools-version: 6.0`; `swiftLanguageMode(.v5)` on all targets. No new third-party dependencies.
- Usage host: `https://cloudcode-pa.googleapis.com/v1internal` (`:loadCodeAssist`, `:retrieveUserQuota`). Token host: `https://oauth2.googleapis.com/token`.
- OAuth clients (public installed-app creds): CLI `681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com` / `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`; Antigravity `1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com` / `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` **[verify at build]**.
- CLI store: `~/.gemini/oauth_creds.json` (JSON, mode 600) + `~/.gemini/google_accounts.json` (`{"active":email,"old":[]}`). Antigravity store: keychain `svce=gemini, acct=antigravity`, value `"go-keyring-base64:"+base64(JSON)`, JSON `{"token":{access_token,token_type,refresh_token,expiry(ISO8601)},"auth_method":"consumer"}`.
- `usedPercent = (1 − remainingFraction) × 100`. Binding = highest usedPercent model; extras = next up-to-2 non-zero models.
- Snapshot-before-swap; never strand an outgoing refresh token. Profile snapshots via `Keychain.upsert` (slots `PitStop-gemini-cli`, `PitStop-gemini-antigravity`).
- Re-login is inactive-account-only (matches existing Login-pill invariant): writes the profile slot, never the live store.
- Google refresh grant does NOT return a new refresh_token — preserve the existing one.
- Test runs that touch localhost sockets must be time-guarded (`timeout 200 swift test`). Never spawn background busy-wait shell loops.

---

### Task 1: Gemini credential parsing + go-keyring codec + model names

**Files:**
- Create: `Sources/PitStop/Gemini.swift`
- Test: `Tests/PitStopTests/GeminiCredsTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `enum Gemini` with:
    - `struct Creds { var accessToken: String; var refreshToken: String?; var idToken: String?; var expiryMs: Double; var email: String }`
    - `enum GeminiError: LocalizedError { case sessionExpired, malformed, notSignedIn }`
    - `Gemini.decodeGoKeyring(_ raw: String) -> Data?`
    - `Gemini.encodeGoKeyring(_ json: Data) -> String`
    - `Gemini.cliCreds(from blob: Data) -> Creds?`
    - `Gemini.antigravityCreds(from blob: Data) -> Creds?`
    - `Gemini.decodeJWTEmail(_ jwt: String) -> String?`
    - `Gemini.shortModelName(_ modelId: String) -> String`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PitStopTests/GeminiCredsTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter GeminiCredsTests`
Expected: FAIL — `cannot find 'Gemini' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/PitStop/Gemini.swift`:

```swift
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter GeminiCredsTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PitStop/Gemini.swift Tests/PitStopTests/GeminiCredsTests.swift
git commit -m "Add Gemini credential parsing, go-keyring codec, model-name shortening"
```

---

### Task 2: Gemini usage parsing (loadCodeAssist + retrieveUserQuota)

**Files:**
- Modify: `Sources/PitStop/Gemini.swift`
- Test: `Tests/PitStopTests/GeminiUsageTests.swift`

**Interfaces:**
- Consumes: `Gemini.shortModelName` (Task 1).
- Produces:
  - `struct Gemini.Usage { struct Window { var label: String; var usedPercent: Double; var resetsAt: Date? }; var windows: [Window]; var fetchedAt: Date; var maxUtilization: Double }`
  - `Gemini.parseQuota(_ data: Data) -> Usage`
  - `Gemini.parseLoadCodeAssist(_ data: Data) -> (project: String?, planLabel: String)`
  - `Gemini.extrasLine(_ usage: Usage) -> String?` (top-2 non-zero non-binding models)

- [ ] **Step 1: Write the failing tests**

Create `Tests/PitStopTests/GeminiUsageTests.swift`:

```swift
import XCTest
@testable import PitStop

final class GeminiUsageTests: XCTestCase {
    // Shape captured from the live retrieveUserQuota probe.
    private let quotaJSON = """
    {"buckets":[
      {"modelId":"gemini-3.1-pro-preview","remainingFraction":0.62,"resetTime":"2026-07-02T12:47:13Z","tokenType":"REQUESTS"},
      {"modelId":"gemini-3-pro-preview","remainingFraction":0.78,"resetTime":"2026-07-02T12:47:13Z","tokenType":"REQUESTS"},
      {"modelId":"gemini-2.5-flash","remainingFraction":0.95,"resetTime":"2026-07-02T12:47:13Z","tokenType":"REQUESTS"},
      {"modelId":"gemini-2.5-flash-lite","remainingFraction":1.0,"resetTime":"2026-07-02T12:47:13Z","tokenType":"REQUESTS"}
    ]}
    """

    func testParseQuotaBindingAndExtras() {
        let u = Gemini.parseQuota(Data(quotaJSON.utf8))
        XCTAssertEqual(u.windows.count, 4)
        // Binding = highest used% = 3.1-pro (0.62 remaining -> 38% used).
        XCTAssertEqual(Int(u.maxUtilization.rounded()), 38)
        let binding = u.windows.max { $0.usedPercent < $1.usedPercent }
        XCTAssertEqual(binding?.label, "3.1-pro")
        XCTAssertNotNil(binding?.resetsAt)
        // Extras = next non-zero models (3-pro 22%, 2.5-flash 5%); flash-lite 0% omitted.
        let extras = Gemini.extrasLine(u)
        XCTAssertEqual(extras, "3-pro 22% · 2.5-flash 5%")
    }

    func testParseQuotaEmpty() {
        let u = Gemini.parseQuota(Data("{}".utf8))
        XCTAssertTrue(u.windows.isEmpty)
        XCTAssertEqual(u.maxUtilization, 0)
        XCTAssertNil(Gemini.extrasLine(u))
    }

    func testParseLoadCodeAssist() {
        let json = """
        {"currentTier":{"id":"standard-tier","name":"Gemini Code Assist"},
         "paidTier":{"id":"g1-pro-tier","name":"Gemini Code Assist in Google One AI Pro"},
         "cloudaicompanionProject":"mimetic-moonlight-6khfj"}
        """
        let r = Gemini.parseLoadCodeAssist(Data(json.utf8))
        XCTAssertEqual(r.project, "mimetic-moonlight-6khfj")
        XCTAssertEqual(r.planLabel, "AI Pro")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter GeminiUsageTests`
Expected: FAIL — `type 'Gemini' has no member 'Usage'`.

- [ ] **Step 3: Write the implementation**

Append to `enum Gemini` in `Sources/PitStop/Gemini.swift` (before the closing brace):

```swift
    // MARK: - Usage

    struct Usage {
        struct Window { var label: String; var usedPercent: Double; var resetsAt: Date? }
        var windows: [Window]
        var fetchedAt = Date()
        var maxUtilization: Double { windows.map(\.usedPercent).max() ?? 0 }
    }

    /// Parse a retrieveUserQuota response into per-model windows. Buckets whose
    /// `remainingFraction` is missing are skipped (the field is optional).
    static func parseQuota(_ data: Data) -> Usage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = root["buckets"] as? [[String: Any]] else {
            return Usage(windows: [])
        }
        let windows: [Usage.Window] = buckets.compactMap { b in
            guard let model = b["modelId"] as? String,
                  let frac = (b["remainingFraction"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (b["resetTime"] as? String).flatMap { quotaReset.date(from: $0) }
            return Usage.Window(label: shortModelName(model),
                                usedPercent: max(0, min(100, (1 - frac) * 100)),
                                resetsAt: reset)
        }
        return Usage(windows: windows)
    }

    /// The compact extras line: the up-to-2 most-used models after the binding
    /// one, dropping 0%. nil when there's nothing to add.
    static func extrasLine(_ usage: Usage) -> String? {
        let sorted = usage.windows.sorted { $0.usedPercent > $1.usedPercent }
        let extras = sorted.dropFirst().filter { $0.usedPercent >= 0.5 }.prefix(2)
        guard !extras.isEmpty else { return nil }
        return extras.map { "\($0.label) \(Int($0.usedPercent.rounded()))%" }.joined(separator: " · ")
    }

    /// Parse loadCodeAssist -> (cloudaicompanionProject, short plan label).
    static func parseLoadCodeAssist(_ data: Data) -> (project: String?, planLabel: String) {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let project = root["cloudaicompanionProject"] as? String
        let paid = (root["paidTier"] as? [String: Any])?["name"] as? String
        let current = (root["currentTier"] as? [String: Any])?["name"] as? String
        return (project, planLabel(paid: paid, current: current))
    }

    private static func planLabel(paid: String?, current: String?) -> String {
        if let paid {
            if paid.contains("Ultra") { return "Ultra" }
            if paid.contains("Pro") { return "AI Pro" }
        }
        if let current { return current.replacingOccurrences(of: "Gemini ", with: "") }
        return "Code Assist"
    }

    private static let quotaReset: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter GeminiUsageTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PitStop/Gemini.swift Tests/PitStopTests/GeminiUsageTests.swift
git commit -m "Add Gemini usage parsing (quota buckets, binding, extras, tier)"
```

---

### Task 3: Gemini network — token refresh + Code Assist calls

**Files:**
- Modify: `Sources/PitStop/Gemini.swift`
- Test: `Tests/PitStopTests/GeminiNetworkTests.swift`

**Interfaces:**
- Consumes: `Gemini.Creds`, `Gemini.Usage`, `Gemini.GeminiError` (Tasks 1–2).
- Produces:
  - `struct Gemini.Client { let id: String; let secret: String; let scopes: String }`, `Gemini.cliClient`, `Gemini.antigravityClient`
  - `Gemini.tokenURL`, `Gemini.codeAssistBase`
  - `Gemini.refreshRequest(refreshToken:client:) -> URLRequest`
  - `Gemini.loadCodeAssistRequest(accessToken:) -> URLRequest`
  - `Gemini.quotaRequest(accessToken:project:) -> URLRequest`
  - `Gemini.refresh(refreshToken:client:) async throws -> (accessToken: String, idToken: String?, expiryMs: Double)`
  - `Gemini.loadProject(accessToken:) async throws -> (project: String?, planLabel: String)`
  - `Gemini.fetchUsage(accessToken:project:) async throws -> Usage`

- [ ] **Step 1: Write the failing tests**

Create `Tests/PitStopTests/GeminiNetworkTests.swift`:

```swift
import XCTest
@testable import PitStop

final class GeminiNetworkTests: XCTestCase {
    func testRefreshRequestIsGoogleForm() {
        let req = Gemini.refreshRequest(refreshToken: "R+T", client: Gemini.cliClient)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=R%2BT"))
        XCTAssertTrue(body.contains("client_id=\(Gemini.cliClient.id)"))
        XCTAssertTrue(body.contains("client_secret="))
    }

    func testQuotaRequestShape() {
        let req = Gemini.quotaRequest(accessToken: "AT", project: "proj-1")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString,
                       "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer AT")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try! JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["project"] as? String, "proj-1")
    }

    func testLoadCodeAssistRequestShape() {
        let req = Gemini.loadCodeAssistRequest(accessToken: "AT")
        XCTAssertEqual(req.url?.absoluteString,
                       "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer AT")
        let body = try! JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        XCTAssertNotNil(body?["metadata"])
    }

    func testTwoClientsDiffer() {
        XCTAssertNotEqual(Gemini.cliClient.id, Gemini.antigravityClient.id)
        XCTAssertTrue(Gemini.antigravityClient.scopes.contains("cclog"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter GeminiNetworkTests`
Expected: FAIL — `type 'Gemini' has no member 'refreshRequest'`.

- [ ] **Step 3: Write the implementation**

Append to `enum Gemini` in `Sources/PitStop/Gemini.swift`:

```swift
    // MARK: - Network

    struct Client { let id: String; let secret: String; let scopes: String }

    static let cliClient = Client(
        id: "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com",
        secret: "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",
        scopes: "https://www.googleapis.com/auth/cloud-platform "
            + "https://www.googleapis.com/auth/userinfo.email "
            + "https://www.googleapis.com/auth/userinfo.profile")

    static let antigravityClient = Client(
        id: "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com",
        secret: "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",
        scopes: cliClient.scopes + " https://www.googleapis.com/auth/cclog "
            + "https://www.googleapis.com/auth/experimentsandconfigs")

    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let codeAssistBase = "https://cloudcode-pa.googleapis.com/v1internal"

    static func client(for surface: Surface) -> Client {
        surface == .cli ? cliClient : antigravityClient
    }

    private static func formEncode(_ s: String) -> String {
        var cs = CharacterSet.alphanumerics; cs.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: cs) ?? s
    }

    static func refreshRequest(refreshToken: String, client: Client) -> URLRequest {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        let fields = ["grant_type": "refresh_token", "refresh_token": refreshToken,
                      "client_id": client.id, "client_secret": client.secret]
        req.httpBody = Data(fields.map { "\(formEncode($0.key))=\(formEncode($0.value))" }
            .joined(separator: "&").utf8)
        return req
    }

    private static func codeAssistRequest(method: String, accessToken: String,
                                          body: [String: Any]) -> URLRequest {
        var req = URLRequest(url: URL(string: "\(codeAssistBase):\(method)")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    static func loadCodeAssistRequest(accessToken: String) -> URLRequest {
        codeAssistRequest(method: "loadCodeAssist", accessToken: accessToken,
                          body: ["metadata": ["ideType": "IDE_UNSPECIFIED",
                                              "platform": "DARWIN_ARM64",
                                              "pluginType": "GEMINI"]])
    }

    static func quotaRequest(accessToken: String, project: String) -> URLRequest {
        codeAssistRequest(method: "retrieveUserQuota", accessToken: accessToken,
                          body: ["project": project])
    }

    /// Google refresh_token grant. Returns a fresh access token; Google does NOT
    /// rotate the refresh token, so the caller keeps the existing one.
    static func refresh(refreshToken: String, client: Client) async throws
        -> (accessToken: String, idToken: String?, expiryMs: Double) {
        let (data, resp) = try await URLSession.shared.data(for: refreshRequest(refreshToken: refreshToken, client: client))
        guard let http = resp as? HTTPURLResponse else { throw GeminiError.malformed }
        if http.statusCode == 400 || http.statusCode == 401 || http.statusCode == 403 {
            throw GeminiError.sessionExpired
        }
        guard http.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String else { throw GeminiError.malformed }
        let expiresIn = (root["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return (access, root["id_token"] as? String,
                (Date().timeIntervalSince1970 + expiresIn) * 1000)
    }

    static func loadProject(accessToken: String) async throws -> (project: String?, planLabel: String) {
        let (data, resp) = try await URLSession.shared.data(for: loadCodeAssistRequest(accessToken: accessToken))
        guard let http = resp as? HTTPURLResponse else { throw GeminiError.malformed }
        if http.statusCode == 401 || http.statusCode == 403 { throw GeminiError.sessionExpired }
        guard http.statusCode == 200 else { throw UsageAPI.APIError.http(http.statusCode) }
        return parseLoadCodeAssist(data)
    }

    static func fetchUsage(accessToken: String, project: String) async throws -> Usage {
        let (data, resp) = try await URLSession.shared.data(for: quotaRequest(accessToken: accessToken, project: project))
        guard let http = resp as? HTTPURLResponse else { throw GeminiError.malformed }
        if http.statusCode == 401 || http.statusCode == 403 { throw GeminiError.sessionExpired }
        if http.statusCode == 429 {
            let ra = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw UsageAPI.APIError.rateLimited(retryAfter: ra)
        }
        guard http.statusCode == 200 else { throw UsageAPI.APIError.http(http.statusCode) }
        return parseQuota(data)
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter GeminiNetworkTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PitStop/Gemini.swift Tests/PitStopTests/GeminiNetworkTests.swift
git commit -m "Add Gemini token refresh + Code Assist request/parse layer"
```

---

### Task 4: GeminiStore — live stores, snapshots, switch-both

**Files:**
- Create: `Sources/PitStop/GeminiStore.swift`
- Test: `Tests/PitStopTests/GeminiStoreTests.swift`

**Interfaces:**
- Consumes: `Gemini.*` (Tasks 1–3), `Keychain.*`, `ProfileStore.directory`.
- Produces:
  - `struct GeminiProfile { var email: String; var savedAt: Date; var planLabel: String; var onCli: Bool; var onAntigravity: Bool }`
  - `final class GeminiStore` with: `cliService`, `antigravityService`, `liveKeychainService`("gemini"), `liveKeychainAccount`("antigravity"), `cliCredsURL`, `googleAccountsURL`, `profiles`, `load()`, `liveCliEmail()`, `liveCliBlob()`, `liveAntigravityBlob() async`, `liveAntigravityEmail() async`, `captureCurrent() async throws`, `switchTo(email:) async throws`, `blob(for:surface:isActive:) async throws -> Data?`, `storeRefreshedBlob(_:email:surface:) async throws`, `remove(email:) async throws`
  - Pure helper `GeminiStore.buildCliBlob(access:refresh:idToken:expiryMs:) -> Data` and `GeminiStore.buildAntigravityBlob(access:refresh:idToken:expiryISO:) -> Data` (used by re-login too).

- [ ] **Step 1: Write the failing tests**

Create `Tests/PitStopTests/GeminiStoreTests.swift`:

```swift
import XCTest
@testable import PitStop

final class GeminiStoreTests: XCTestCase {
    func testBuildCliBlobIsValidOauthCreds() {
        let blob = GeminiStore.buildCliBlob(access: "AT", refresh: "RT",
                                            idToken: "ID", expiryMs: 123456)
        let root = try! JSONSerialization.jsonObject(with: blob) as! [String: Any]
        XCTAssertEqual(root["access_token"] as? String, "AT")
        XCTAssertEqual(root["refresh_token"] as? String, "RT")
        XCTAssertEqual(root["token_type"] as? String, "Bearer")
        XCTAssertEqual((root["expiry_date"] as? NSNumber)?.doubleValue, 123456)
        // round-trips through the parser
        XCTAssertEqual(Gemini.cliCreds(from: blob)?.accessToken, "AT")
    }

    func testBuildAntigravityBlobRoundTrips() {
        let blob = GeminiStore.buildAntigravityBlob(access: "AT2", refresh: "RT2",
                                                    idToken: "ID2", expiryISO: "2026-07-01T16:15:44+05:30")
        // stored value is the go-keyring-base64 string
        let raw = String(data: blob, encoding: .utf8)!
        XCTAssertTrue(raw.hasPrefix("go-keyring-base64:"))
        let creds = Gemini.antigravityCreds(from: blob)
        XCTAssertEqual(creds?.accessToken, "AT2")
        XCTAssertEqual(creds?.refreshToken, "RT2")
        // inner JSON carries auth_method
        let inner = try! JSONSerialization.jsonObject(with: Gemini.decodeGoKeyring(raw)!) as! [String: Any]
        XCTAssertEqual(inner["auth_method"] as? String, "consumer")
    }

    func testServicesAndPaths() {
        XCTAssertEqual(GeminiStore.cliService, "PitStop-gemini-cli")
        XCTAssertEqual(GeminiStore.antigravityService, "PitStop-gemini-antigravity")
        XCTAssertEqual(GeminiStore.liveKeychainService, "gemini")
        XCTAssertEqual(GeminiStore.liveKeychainAccount, "antigravity")
        XCTAssertTrue(GeminiStore.cliCredsURL.path.hasSuffix(".gemini/oauth_creds.json"))
        XCTAssertTrue(GeminiStore.googleAccountsURL.path.hasSuffix(".gemini/google_accounts.json"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter GeminiStoreTests`
Expected: FAIL — `cannot find 'GeminiStore' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/PitStop/GeminiStore.swift`:

```swift
import Foundation

/// A saved Gemini account. Secret blobs live in the keychain (services
/// "PitStop-gemini-cli" / "PitStop-gemini-antigravity", account = email); this
/// holds only non-secret metadata, persisted to ~/.config/pitstop/gemini-profiles.json.
struct GeminiProfile {
    var email: String
    var savedAt: Date
    var planLabel: String
    var onCli: Bool
    var onAntigravity: Bool

    fileprivate var asDict: [String: Any] {
        ["email": email, "savedAt": savedAt.timeIntervalSince1970,
         "planLabel": planLabel, "onCli": onCli, "onAntigravity": onAntigravity]
    }
    fileprivate init?(dict: [String: Any]) {
        guard let email = dict["email"] as? String else { return nil }
        self.email = email
        self.savedAt = Date(timeIntervalSince1970: (dict["savedAt"] as? NSNumber)?.doubleValue ?? 0)
        self.planLabel = dict["planLabel"] as? String ?? ""
        self.onCli = dict["onCli"] as? Bool ?? false
        self.onAntigravity = dict["onAntigravity"] as? Bool ?? false
    }
    init(email: String, savedAt: Date, planLabel: String, onCli: Bool, onAntigravity: Bool) {
        self.email = email; self.savedAt = savedAt; self.planLabel = planLabel
        self.onCli = onCli; self.onAntigravity = onAntigravity
    }
}

/// The Gemini equivalent of CodexStore, but with TWO live surfaces:
///  - CLI: the file ~/.gemini/oauth_creds.json (+ google_accounts.json active).
///  - Antigravity: the keychain item svce=gemini, acct=antigravity (go-keyring blob).
/// Saved snapshots are PitStop keychain items so a switch restores both surfaces.
final class GeminiStore {
    struct StoreError: LocalizedError { let message: String; var errorDescription: String? { message } }

    static let cliService = "PitStop-gemini-cli"
    static let antigravityService = "PitStop-gemini-antigravity"
    static let liveKeychainService = "gemini"
    static let liveKeychainAccount = "antigravity"
    static let file = ProfileStore.directory.appendingPathComponent("gemini-profiles.json")

    static var geminiDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
    }
    static var cliCredsURL: URL { geminiDir.appendingPathComponent("oauth_creds.json") }
    static var googleAccountsURL: URL { geminiDir.appendingPathComponent("google_accounts.json") }

    private(set) var profiles: [GeminiProfile] = []

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: Self.file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["profiles"] as? [[String: Any]] else { profiles = []; return }
        profiles = list.compactMap(GeminiProfile.init(dict:)).sorted { $0.email < $1.email }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: ProfileStore.directory, withIntermediateDirectories: true)
        let root: [String: Any] = ["profiles": profiles.map(\.asDict)]
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            .write(to: Self.file, options: .atomic)
    }

    // MARK: - Pure blob builders (also used by re-login)

    static func buildCliBlob(access: String, refresh: String?, idToken: String?, expiryMs: Double) -> Data {
        var obj: [String: Any] = ["access_token": access, "token_type": "Bearer",
                                  "expiry_date": expiryMs,
                                  "scope": Gemini.cliClient.scopes + " openid"]
        if let refresh { obj["refresh_token"] = refresh }
        if let idToken { obj["id_token"] = idToken }
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    static func buildAntigravityBlob(access: String, refresh: String?, idToken: String?, expiryISO: String) -> Data {
        var token: [String: Any] = ["access_token": access, "token_type": "Bearer", "expiry": expiryISO]
        if let refresh { token["refresh_token"] = refresh }
        if let idToken { token["id_token"] = idToken }
        let inner = (try? JSONSerialization.data(withJSONObject: ["token": token, "auth_method": "consumer"],
                                                 options: [.sortedKeys])) ?? Data()
        return Data(Gemini.encodeGoKeyring(inner).utf8)
    }

    // MARK: - Live reads

    func liveCliBlob() -> Data? { try? Data(contentsOf: Self.cliCredsURL) }

    func liveCliEmail() -> String? {
        if let data = try? Data(contentsOf: Self.googleAccountsURL),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let active = root["active"] as? String, !active.isEmpty { return active }
        return liveCliBlob().flatMap(Gemini.cliCreds(from:))?.email
    }

    func liveAntigravityBlob() async -> Data? {
        try? await Keychain.read(service: Self.liveKeychainService, account: Self.liveKeychainAccount)
    }

    func liveAntigravityEmail() async -> String? {
        await liveAntigravityBlob().flatMap(Gemini.antigravityCreds(from:))?.email
    }

    // MARK: - Snapshot / switch

    /// Snapshot both live surfaces into per-account saved profiles.
    @discardableResult
    func captureCurrent() async throws -> Bool {
        var touched = false
        let cliBlob = liveCliBlob()
        let cliEmail = cliBlob.flatMap(Gemini.cliCreds(from:))?.email
        let agBlob = await liveAntigravityBlob()
        let agEmail = agBlob.flatMap(Gemini.antigravityCreds(from:))?.email

        func upsert(_ blob: Data?, email: String?, service: String) async throws -> Bool {
            guard let blob, let email else { return false }
            if let stored = try? await Keychain.read(service: service, account: email), stored == blob {
                return false
            }
            try await Keychain.upsert(service: service, account: email, data: blob)
            return true
        }
        touched = try await upsert(cliBlob, email: cliEmail, service: Self.cliService) || touched
        touched = try await upsert(agBlob, email: agEmail, service: Self.antigravityService) || touched

        // Merge metadata by email.
        for (email, isCli, isAg) in [(cliEmail, true, false), (agEmail, false, true)] {
            guard let email else { continue }
            let plan = profiles.first(where: { $0.email == email })?.planLabel ?? ""
            var p = profiles.first(where: { $0.email == email })
                ?? GeminiProfile(email: email, savedAt: Date(), planLabel: plan, onCli: false, onAntigravity: false)
            p.savedAt = Date()
            if isCli { p.onCli = true }
            if isAg { p.onAntigravity = true }
            profiles.removeAll { $0.email == email }
            profiles.append(p)
        }
        profiles.sort { $0.email < $1.email }
        if touched { try save() }
        return touched
    }

    /// Set the plan label for an account (from a successful loadCodeAssist).
    func setPlanLabel(_ label: String, email: String) {
        guard let i = profiles.firstIndex(where: { $0.email == email }), !label.isEmpty else { return }
        profiles[i].planLabel = label
        try? save()
    }

    /// Switch both surfaces to `email` (whichever snapshots exist). Snapshots the
    /// current live accounts first so their tokens aren't stranded.
    func switchTo(email: String) async throws {
        _ = try await captureCurrent()
        var wrote = false
        if let cli = try await Keychain.read(service: Self.cliService, account: email) {
            try writeCliLive(cli, email: email); wrote = true
        }
        if let ag = try await Keychain.read(service: Self.antigravityService, account: email) {
            try await Keychain.upsertLive(service: Self.liveKeychainService, data: ag); wrote = true
        }
        guard wrote else {
            throw StoreError(message: "No saved Gemini credentials for \(email) — sign in once and save again")
        }
    }

    /// The blob to fetch usage with for a surface — live for the active account,
    /// saved snapshot otherwise.
    func blob(for email: String, surface: Gemini.Surface, isActive: Bool) async throws -> Data? {
        if isActive {
            if surface == .cli, let live = liveCliBlob() { return live }
            if surface == .antigravity, let live = await liveAntigravityBlob() { return live }
        }
        let service = surface == .cli ? Self.cliService : Self.antigravityService
        return try await Keychain.read(service: service, account: email)
    }

    /// Persist a snapshot whose token PitStop refreshed itself (inactive only).
    func storeRefreshedBlob(_ data: Data, email: String, surface: Gemini.Surface) async throws {
        let service = surface == .cli ? Self.cliService : Self.antigravityService
        try await Keychain.upsert(service: service, account: email, data: data)
    }

    func remove(email: String) async throws {
        for service in [Self.cliService, Self.antigravityService] {
            try await Keychain.delete(service: service, account: email)
            try? await Keychain.delete(service: service, account: Keychain.stagingAccount(for: email))
        }
        profiles.removeAll { $0.email == email }
        try save()
    }

    /// Write the CLI blob into ~/.gemini/oauth_creds.json (mode 600) and set the
    /// active email in google_accounts.json.
    private func writeCliLive(_ blob: Data, email: String) throws {
        try blob.write(to: Self.cliCredsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: Self.cliCredsURL.path)
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: Self.googleAccountsURL),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = existing
        }
        var old = (root["old"] as? [String]) ?? []
        if let prev = root["active"] as? String, prev != email, !old.contains(prev) { old.append(prev) }
        root["active"] = email
        root["old"] = old.filter { $0 != email }
        try JSONSerialization.data(withJSONObject: root)
            .write(to: Self.googleAccountsURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter GeminiStoreTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PitStop/GeminiStore.swift Tests/PitStopTests/GeminiStoreTests.swift
git commit -m "Add GeminiStore: two live surfaces, snapshots, switch-both"
```

---

### Task 5: Data model — Provider.gemini + MenuAccount sources

**Files:**
- Modify: `Sources/PitStop/AppDelegate.swift` (`enum Provider`, `struct MenuAccount`)
- Test: `Tests/PitStopTests/GeminiMenuAccountTests.swift`

**Interfaces:**
- Produces: `Provider.gemini`; `MenuAccount.Source` cases `.geminiCli`, `.geminiAntigravity`, `.geminiBoth`; `MenuAccount.isGemini`; updated `provider`, `canSwitch`, `key`, `surfaceTag`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PitStopTests/GeminiMenuAccountTests.swift`:

```swift
import XCTest
@testable import PitStop

final class GeminiMenuAccountTests: XCTestCase {
    func testGeminiSurfaces() {
        let both = MenuAccount(email: "a@x.com", source: .geminiBoth, planLabel: "AI Pro", isActive: true)
        XCTAssertEqual(both.provider, .gemini)
        XCTAssertTrue(both.isGemini)
        XCTAssertTrue(both.canSwitch)
        XCTAssertEqual(both.key, "gemini:a@x.com")
        XCTAssertEqual(both.surfaceTag, "CLI · Antigravity")

        XCTAssertEqual(MenuAccount(email: "a@x.com", source: .geminiCli, planLabel: "", isActive: false).surfaceTag, "CLI")
        XCTAssertEqual(MenuAccount(email: "a@x.com", source: .geminiAntigravity, planLabel: "", isActive: false).surfaceTag, "Antigravity")
        XCTAssertEqual(Provider.gemini.title, "Gemini")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter GeminiMenuAccountTests`
Expected: FAIL — `type 'Provider' has no member 'gemini'`.

- [ ] **Step 3: Implement**

In `Sources/PitStop/AppDelegate.swift`, in `enum Provider`, add the case and title. Change:

```swift
enum Provider: CaseIterable {
    case claude, codex
    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}
```

to:

```swift
enum Provider: CaseIterable {
    case claude, codex, gemini
    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }
}
```

In `struct MenuAccount`, extend `Source` and the computed properties:

```swift
    enum Source { case code, desktop, both, codex, geminiCli, geminiAntigravity, geminiBoth }
```

Add `isGemini` next to `isCodex`:

```swift
    var isGemini: Bool {
        switch source { case .geminiCli, .geminiAntigravity, .geminiBoth: return true; default: return false }
    }
```

Update `provider`:

```swift
    var provider: Provider {
        if isCodex { return .codex }
        if isGemini { return .gemini }
        return .claude
    }
```

Update `canSwitch` to include the gemini cases:

```swift
    var canSwitch: Bool {
        switch source {
        case .code, .both, .codex, .geminiCli, .geminiAntigravity, .geminiBoth: return true
        case .desktop: return false
        }
    }
```

Update `key`:

```swift
    var key: String {
        if isCodex { return "codex:\(email)" }
        if isGemini { return "gemini:\(email)" }
        return email
    }
```

Update `surfaceTag`:

```swift
    var surfaceTag: String? {
        switch source {
        case .code: return "Code"
        case .both: return "Code · Desktop"
        case .desktop: return "Desktop"
        case .codex: return nil
        case .geminiCli: return "CLI"
        case .geminiAntigravity: return "Antigravity"
        case .geminiBoth: return "CLI · Antigravity"
        }
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter GeminiMenuAccountTests`
Expected: PASS. Also run `swift build` — expect NO compile errors (all `switch source` sites now cover the new cases; if the compiler flags a non-exhaustive switch elsewhere, add the gemini cases there mirroring the codex handling).

- [ ] **Step 5: Commit**

```bash
git add Sources/PitStop/AppDelegate.swift Tests/PitStopTests/GeminiMenuAccountTests.swift
git commit -m "Add Gemini provider + MenuAccount surfaces"
```

---

### Task 6: AppDelegate — refresh + row rendering for Gemini

**Files:**
- Modify: `Sources/PitStop/AppDelegate.swift`
- Test: `Tests/PitStopTests/GeminiRowTests.swift`

**Interfaces:**
- Consumes: `GeminiStore`, `Gemini`, `MenuAccount` gemini cases.
- Produces: `AppDelegate.geminiStore`, `geminiUsage`, `geminiProject`, `geminiLiveCliEmail`, `geminiLiveAntigravityEmail`, `refreshGeminiAccount() async`, gemini branches in `accountsForMenu`, `headroom`, `rowModel`, `menuBarReading`. Plus a pure helper `AppDelegate.geminiSource(onCli:onAntigravity:) -> MenuAccount.Source`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PitStopTests/GeminiRowTests.swift`:

```swift
import XCTest
@testable import PitStop

@MainActor
final class GeminiRowTests: XCTestCase {
    func testGeminiSourceMerge() {
        XCTAssertEqual(AppDelegate.geminiSource(onCli: true, onAntigravity: true), .geminiBoth)
        XCTAssertEqual(AppDelegate.geminiSource(onCli: true, onAntigravity: false), .geminiCli)
        XCTAssertEqual(AppDelegate.geminiSource(onCli: false, onAntigravity: true), .geminiAntigravity)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter GeminiRowTests`
Expected: FAIL — `type 'AppDelegate' has no member 'geminiSource'`.

- [ ] **Step 3: Implement**

Add stored state near the Codex state in `AppDelegate` (after `codexUsage`):

```swift
    private let geminiStore = GeminiStore()
    private var geminiLiveCliEmail: String?
    private var geminiLiveAntigravityEmail: String?
    private var geminiUsage: [String: Gemini.Usage] = [:]   // keyed "gemini:<email>"
    private var geminiProject: [String: String] = [:]        // email -> cloudaicompanionProject
```

Add the pure surface-merge helper (near `rowModel`):

```swift
    static func geminiSource(onCli: Bool, onAntigravity: Bool) -> MenuAccount.Source {
        if onCli && onAntigravity { return .geminiBoth }
        return onCli ? .geminiCli : .geminiAntigravity
    }
```

Add `refreshGeminiAccount`, modeled on `refreshCodexAccount`. Call it from `refreshAll` right after `await refreshCodexAccount()`:

```swift
        await refreshGeminiAccount()
```

Implementation (add near `refreshCodexAccount`):

```swift
    /// Snapshot the live Gemini surfaces, then fetch the shared Code Assist usage
    /// for each saved account (refreshing an inactive token if it has aged out).
    private func refreshGeminiAccount() async {
        guard FileManager.default.fileExists(atPath: GeminiStore.cliCredsURL.path)
            || (await geminiStore.liveAntigravityBlob()) != nil else { return }
        do { try await geminiStore.captureCurrent() } catch { lastTopLevelError = error.localizedDescription }
        geminiStore.load()
        geminiLiveCliEmail = geminiStore.liveCliEmail()
        geminiLiveAntigravityEmail = await geminiStore.liveAntigravityEmail()

        for profile in geminiStore.profiles {
            let key = "gemini:\(profile.email)"
            guard passedBackoffGate(key) else { continue }
            let isActive = profile.email == geminiLiveCliEmail || profile.email == geminiLiveAntigravityEmail
            do {
                let usage = try await fetchGeminiUsage(for: profile.email, isActive: isActive)
                geminiUsage[key] = usage
                clearFetchError(for: key)
            } catch {
                recordFetchError(error, for: key)
                if case Gemini.GeminiError.sessionExpired = error, !isActive {
                    fetchError[key] = "Session expired — sign in to Gemini again"
                }
            }
        }
    }

    /// Fetch one Gemini account's usage, refreshing its token in memory and
    /// (for inactive accounts) persisting the rotated access token.
    private func fetchGeminiUsage(for email: String, isActive: Bool) async throws -> Gemini.Usage {
        // Prefer the CLI surface; fall back to Antigravity.
        let surface: Gemini.Surface = geminiStore.profiles.first(where: { $0.email == email })?.onCli == true ? .cli : .antigravity
        guard let blob = try await geminiStore.blob(for: email, surface: surface, isActive: isActive),
              let creds = (surface == .cli ? Gemini.cliCreds(from: blob) : Gemini.antigravityCreds(from: blob)) else {
            throw Gemini.GeminiError.sessionExpired
        }
        var accessToken = creds.accessToken
        // Refresh in memory if expired (Google refresh tokens don't rotate).
        if creds.expiryMs <= Date().timeIntervalSince1970 * 1000, let rt = creds.refreshToken {
            let fresh = try await Gemini.refresh(refreshToken: rt, client: Gemini.client(for: surface))
            accessToken = fresh.accessToken
            if !isActive {
                let rebuilt: Data = surface == .cli
                    ? GeminiStore.buildCliBlob(access: fresh.accessToken, refresh: rt,
                                               idToken: fresh.idToken ?? creds.idToken, expiryMs: fresh.expiryMs)
                    : GeminiStore.buildAntigravityBlob(access: fresh.accessToken, refresh: rt,
                                                       idToken: fresh.idToken ?? creds.idToken,
                                                       expiryISO: Gemini.iso8601.string(from: Date(timeIntervalSince1970: fresh.expiryMs / 1000)))
                try await geminiStore.storeRefreshedBlob(rebuilt, email: email, surface: surface)
            }
        }
        // Resolve + cache the cloudaicompanionProject.
        if geminiProject[email] == nil {
            let r = try await Gemini.loadProject(accessToken: accessToken)
            geminiProject[email] = r.project
            geminiStore.setPlanLabel(r.planLabel, email: email)
        }
        guard let project = geminiProject[email] else { throw Gemini.GeminiError.notSignedIn }
        return try await Gemini.fetchUsage(accessToken: accessToken, project: project)
    }
```

Add gemini rows to `accountsForMenu()` (after the codex loop, before `return rows`). The per-surface merge already happened in `captureCurrent`, so read `onCli`/`onAntigravity` straight from the profile:

```swift
        for p in geminiStore.profiles {
            let source = Self.geminiSource(onCli: p.onCli, onAntigravity: p.onAntigravity)
            let active = p.email == geminiLiveCliEmail || p.email == geminiLiveAntigravityEmail
            rows.append(MenuAccount(email: p.email, source: source, planLabel: p.planLabel, isActive: active))
        }
```

Extend `headroom(_:)` to read gemini usage:

```swift
    private func headroom(_ account: MenuAccount) -> Double {
        if account.isCodex { return codexUsage[account.key]?.maxUtilization ?? 999 }
        if account.isGemini { return geminiUsage[account.key]?.maxUtilization ?? 999 }
        return usage[account.key]?.maxUtilization ?? 999
    }
```

In `rowModel(for:)`, add a gemini branch for the bars/extras. In the `if account.isCodex { … } else { … }` block, change to `if account.isGemini { … } else if account.isCodex { … } else { … }` and add:

```swift
        if account.isGemini {
            let gu = geminiUsage[key]
            let windows = (gu?.windows ?? []).sorted { $0.usedPercent > $1.usedPercent }
            if let binding = windows.first {
                bars = [.init(label: binding.label, utilization: binding.usedPercent,
                              resetText: Format.compactReset(binding.resetsAt))]
            } else {
                bars = []
            }
            if let extras = gu.flatMap(Gemini.extrasLine) { extrasLines.append(extras) }
            dataDate = gu?.fetchedAt
        } else if account.isCodex {
            …existing codex branch…
        } else {
            …existing claude branch…
        }
```

Note: the existing code uses `var extras: [String] = []` then `modelsLine: extras.isEmpty ? nil : extras.joined(...)`. Reuse that `extras` array — append the gemini extras line to it (rename the local above from `extrasLines` to the existing `extras`). Keep `modelsLine` wiring unchanged.

Extend `menuBarReading()` `mostUrgent` to include gemini (after the codex loop):

```swift
            for (key, gu) in geminiUsage {
                let email = String(key.dropFirst("gemini:".count))
                consider(key, "\(displayEmail(email)) (Gemini)", gu.maxUtilization)
            }
```

- [ ] **Step 4: Run tests + build**

Run: `swift test --filter GeminiRowTests` → PASS.
Run: `timeout 250 swift test` → all pass.
Run: `swift build` → clean.
Run: `swift run PitStop --preview` is not needed here (no new preview row required), but `swift build` must be clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/PitStop/AppDelegate.swift Tests/PitStopTests/GeminiRowTests.swift
git commit -m "Wire Gemini refresh + row rendering into the menu"
```

---

### Task 7: AppDelegate — switching, auto-switch, remove

**Files:**
- Modify: `Sources/PitStop/AppDelegate.swift`
- Test: (covered by build + manual E2E; no new pure unit beyond Task 6)

**Interfaces:**
- Consumes: `geminiStore`, `MenuAccount` gemini.
- Produces: `performGeminiSwitch(to:auto:reason:)`, gemini branch in `rowModel`'s `onSwitch`, `evaluateAutoSwitch` gemini call, `removeAccount` gemini branch, gemini entries in the Remove submenu.

- [ ] **Step 1: Add `performGeminiSwitch`** (near `performCodexSwitch`):

```swift
    /// Switch the live Gemini account by swapping BOTH surfaces (CLI file +
    /// Antigravity keychain) to `email`.
    private func performGeminiSwitch(to email: String, auto: Bool = false, reason: String? = nil) {
        Task {
            do {
                try await geminiStore.switchTo(email: email)
                geminiLiveCliEmail = geminiStore.liveCliEmail()
                geminiLiveAntigravityEmail = await geminiStore.liveAntigravityEmail()
                Notifier.shared.post(
                    title: auto ? "Auto-switched Gemini to \(displayEmail(email))"
                                : "Switched Gemini to \(displayEmail(email))",
                    body: reason ?? "Quit & reopen Gemini CLI / Antigravity to pick it up. (Rotating accounts may violate Antigravity's terms.)")
                refreshAll()
            } catch { showError("Couldn't switch Gemini account", error) }
        }
    }
```

- [ ] **Step 2: Route the switch in `rowModel`.** In the `onSwitch` closure (the `if isCodex { … } else { … }`), add a gemini branch:

```swift
            onSwitch: (canSwitch && !offerLogin) ? { [weak self] in
                if isGemini { self?.performGeminiSwitch(to: email) }
                else if isCodex { self?.performCodexSwitch(to: email) }
                else { self?.performSwitch(to: email) }
            } : nil,
```

Add `let isGemini = account.isGemini` next to the existing `let isCodex = account.isCodex` in `rowModel`.

- [ ] **Step 3: Add gemini to `evaluateAutoSwitch`** (after the codex autoSwitch call):

```swift
        autoSwitch(provider: .gemini, live: geminiLiveCliEmail,
                   candidates: geminiStore.profiles.map(\.email),
                   utilization: {
                       let key = "gemini:\($0)"
                       return fetchError[key] == nil ? geminiUsage[key]?.maxUtilization : nil
                   },
                   perform: { performGeminiSwitch(to: $0, auto: true, reason: $1) })
```

- [ ] **Step 4: Add gemini to the Remove submenu + `removeAccount`.** In `buildMenu`, after the codex `removable +=` block:

```swift
        removable += geminiStore.profiles
            .filter { $0.email != geminiLiveCliEmail && $0.email != geminiLiveAntigravityEmail }
            .map { ("\(displayEmail($0.email)) · Gemini", "gemini:\($0.email)") }
```

In `removeAccount(_:)`, add a gemini branch:

```swift
                if key.hasPrefix("gemini:") {
                    let email = String(key.dropFirst("gemini:".count))
                    try await geminiStore.remove(email: email)
                    geminiUsage[key] = nil
                } else if key.hasPrefix("codex:") {
                    …existing…
                } else {
                    …existing…
                }
```

- [ ] **Step 5: Build + commit**

Run: `swift build` → clean. Run: `timeout 250 swift test` → all pass.

```bash
git add Sources/PitStop/AppDelegate.swift
git commit -m "Add Gemini switching, auto-switch, and removal"
```

---

### Task 8: Re-login adapters + Login-pill routing for Gemini

**Files:**
- Create: `Sources/PitStop/GeminiLoginAdapter.swift`
- Modify: `Sources/PitStop/AppDelegate.swift` (`performLogin` adapter selection)
- Test: `Tests/PitStopTests/GeminiLoginAdapterTests.swift`

**Interfaces:**
- Consumes: `LoginAdapter`, `FreshTokens`, `LoginIdentity`, `LoginError` (existing), `Gemini`, `GeminiStore`.
- Produces: `struct GeminiCliLoginAdapter: LoginAdapter`, `struct GeminiAntigravityLoginAdapter: LoginAdapter`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/PitStopTests/GeminiLoginAdapterTests.swift`:

```swift
import XCTest
@testable import PitStop

final class GeminiLoginAdapterTests: XCTestCase {
    func testCliAuthorizeURL() {
        let url = GeminiCliLoginAdapter().authorizeURL(
            challenge: "CH", state: "ST", redirectURI: "http://127.0.0.1:51000/oauth2callback", pasteMode: false)
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(c.host, "accounts.google.com")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["client_id"], Gemini.cliClient.id)
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["access_type"], "offline")           // to get a refresh_token
        XCTAssertEqual(q["prompt"], "consent")
        XCTAssertEqual(q["redirect_uri"], "http://127.0.0.1:51000/oauth2callback")
        XCTAssertTrue((q["scope"] ?? "").contains("cloud-platform"))
    }

    func testCliBuildBlobShape() throws {
        let a = GeminiCliLoginAdapter()
        let tokens = FreshTokens(accessToken: "AT", refreshToken: "RT", idToken: "ID", expiresAtMs: 999)
        let blob = try a.buildBlob(old: Data(), tokens: tokens)
        XCTAssertEqual(Gemini.cliCreds(from: blob)?.accessToken, "AT")
    }

    func testAntigravityUsesOwnClientAndScopes() {
        XCTAssertEqual(GeminiAntigravityLoginAdapter().provider, .gemini)
        let url = GeminiAntigravityLoginAdapter().authorizeURL(
            challenge: "CH", state: "ST", redirectURI: "http://127.0.0.1:51000/oauth2callback", pasteMode: false)
        let q = Dictionary(uniqueKeysWithValues:
            (URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["client_id"], Gemini.antigravityClient.id)
        XCTAssertTrue((q["scope"] ?? "").contains("cclog"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter GeminiLoginAdapterTests`
Expected: FAIL — `cannot find 'GeminiCliLoginAdapter' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/PitStop/GeminiLoginAdapter.swift`:

```swift
import Foundation

/// Shared Google OAuth login behavior for the two Gemini surfaces. Google
/// installed-app clients accept an arbitrary loopback redirect, so re-login is
/// fully automatic (no paste fallback).
protocol GeminiLoginAdapter: LoginAdapter {
    var client: Gemini.Client { get }
    var surface: Gemini.Surface { get }
    var profileService: String { get }
}

extension GeminiLoginAdapter {
    var provider: Provider { .gemini }
    var loopbackPorts: [UInt16] { [51000, 51001, 51002, 51003] }
    var loopbackPath: String { "/oauth2callback" }
    var supportsPaste: Bool { false }
    var pasteRedirectURI: String { "" }

    func authorizeURL(challenge: String, state: String, redirectURI: String, pasteMode: Bool) -> URL {
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: client.id),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: client.scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        return c.url!
    }

    func exchange(code: String, state: String, verifier: String, redirectURI: String) async throws -> FreshTokens {
        var req = URLRequest(url: Gemini.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        func enc(_ s: String) -> String {
            var cs = CharacterSet.alphanumerics; cs.insert(charactersIn: "-._~")
            return s.addingPercentEncoding(withAllowedCharacters: cs) ?? s
        }
        let fields = ["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
                      "client_id": client.id, "client_secret": client.secret, "code_verifier": verifier]
        req.httpBody = Data(fields.map { "\(enc($0.key))=\(enc($0.value))" }.joined(separator: "&").utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String else { throw LoginError.badResponse("Google token exchange failed") }
        let expiresIn = (root["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return FreshTokens(accessToken: access, refreshToken: root["refresh_token"] as? String,
                           idToken: root["id_token"] as? String,
                           expiresAtMs: (Date().timeIntervalSince1970 + expiresIn) * 1000)
    }

    func identity(from tokens: FreshTokens) async throws -> LoginIdentity {
        guard let idt = tokens.idToken, let email = Gemini.decodeJWTEmail(idt) else {
            throw LoginError.badResponse("Google sign-in returned no id_token email")
        }
        return LoginIdentity(email: email, accountID: nil)
    }

    func persist(_ tokens: FreshTokens, email: String) async throws {
        let blob = try buildBlob(old: Data(), tokens: tokens)
        try await Keychain.upsert(service: profileService, account: email, data: blob)
    }
}

struct GeminiCliLoginAdapter: GeminiLoginAdapter {
    var client: Gemini.Client { Gemini.cliClient }
    var surface: Gemini.Surface { .cli }
    var profileService: String { GeminiStore.cliService }
    func buildBlob(old: Data, tokens: FreshTokens) throws -> Data {
        GeminiStore.buildCliBlob(access: tokens.accessToken, refresh: tokens.refreshToken,
                                 idToken: tokens.idToken, expiryMs: tokens.expiresAtMs ?? 0)
    }
}

struct GeminiAntigravityLoginAdapter: GeminiLoginAdapter {
    var client: Gemini.Client { Gemini.antigravityClient }
    var surface: Gemini.Surface { .antigravity }
    var profileService: String { GeminiStore.antigravityService }
    func buildBlob(old: Data, tokens: FreshTokens) throws -> Data {
        let iso = Gemini.iso8601.string(from: Date(timeIntervalSince1970: (tokens.expiresAtMs ?? 0) / 1000))
        return GeminiStore.buildAntigravityBlob(access: tokens.accessToken, refresh: tokens.refreshToken,
                                                idToken: tokens.idToken, expiryISO: iso)
    }
}
```

- [ ] **Step 4: Route the Login pill in `performLogin`.** In `AppDelegate.performLogin`, extend the adapter selection:

```swift
        let adapter: LoginAdapter
        if account.isGemini {
            // Re-auth the surface PitStop polls with (CLI if present, else Antigravity).
            let onCli = geminiStore.profiles.first(where: { $0.email == account.email })?.onCli ?? true
            adapter = onCli ? GeminiCliLoginAdapter() : GeminiAntigravityLoginAdapter()
        } else if account.isCodex {
            adapter = CodexLoginAdapter()
        } else {
            adapter = ClaudeLoginAdapter()
        }
```

(Replace the existing `let adapter: LoginAdapter = account.isCodex ? CodexLoginAdapter() : ClaudeLoginAdapter()` line.)

- [ ] **Step 5: Run tests + build + commit**

Run: `swift test --filter GeminiLoginAdapterTests` → PASS.
Run: `timeout 250 swift test` → all pass. Run: `swift build` → clean.

```bash
git add Sources/PitStop/GeminiLoginAdapter.swift Sources/PitStop/AppDelegate.swift Tests/PitStopTests/GeminiLoginAdapterTests.swift
git commit -m "Add Gemini re-login adapters and Login-pill routing"
```

---

### Task 9: End-to-end verification (manual)

No code. Uses `./scripts/make-app.sh` to run the real app; the endpoints were already probe-verified on-device.

- [ ] **Step 1: Build + install**

Run: `./scripts/make-app.sh` — expect it builds and relaunches in the menu bar.

- [ ] **Step 2: Usage row**

Open the menu. Confirm a **Gemini** section with a row for the Google account, tagged **CLI · Antigravity**, a plan chip (e.g. "AI Pro"), a binding-model bar with a % + reset, and (if any model is used) the extras line. Cross-check the % against `PitStop --check`-style expectation.

- [ ] **Step 3: Switch round-trip**

With a second Google account saved (sign into Gemini CLI as account B once so PitStop snapshots it, then back to A), click the Gemini row to switch to B. Confirm the notification, and verify BOTH stores moved: `~/.gemini/google_accounts.json` `active` = B, `~/.gemini/oauth_creds.json` is B's, and the keychain `gemini/antigravity` blob decodes to B. Switch back to A; confirm A restored.

- [ ] **Step 4: Confirm profile-only for re-login**

If a Gemini row ever shows "Session expired", click **Login**, sign in with Google; confirm the row heals and that the switch of the LIVE account didn't change (re-login writes the profile slot only). Record which surface healed.

- [ ] **Step 5: Auto-switch (optional)**

Enable auto-switch in Settings; when the live Gemini account crosses the threshold, confirm it flips to the emptiest saved Gemini account.

- [ ] **Step 6: Confirm the [verify] items**

Confirm the Antigravity client creds still refresh and the prod host (`cloudcode-pa`) still serves `retrieveUserQuota`. If either drifts, note it and adjust `Gemini.antigravityClient` / `Gemini.codeAssistBase`.

---

## Self-Review

**Spec coverage:** merged row (Task 5–6 `geminiSource` + `accountsForMenu`), switch-both (Task 4 `switchTo` + Task 7 `performGeminiSwitch`), binding+extras (Task 2 + Task 6 `rowModel`), usage endpoint (Tasks 2–3, 6), auto-switch (Task 7), re-login per-surface (Task 8), Gemini-app skipped (not built), errors/backoff via `recordFetchError` + `GeminiError.sessionExpired` (Task 6), tests (Tasks 1–8) + manual E2E (Task 9).

**Placeholder scan:** No "TBD"/"add error handling"; every code step shows complete code.

**Type consistency:** `Gemini.Creds`, `Gemini.Usage.Window`, `GeminiProfile`, `GeminiStore` services, `MenuAccount.Source` gemini cases, and `FreshTokens`/`LoginIdentity`/`LoginError` (reused) are used consistently across tasks. `Gemini.iso8601` (Task 1) is reused in Tasks 6 and 8. `buildCliBlob`/`buildAntigravityBlob` (Task 4) are reused by the adapters (Task 8).
