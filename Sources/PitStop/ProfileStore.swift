import Foundation

/// A saved Claude Code account. The secret credential blob lives in the
/// keychain (service "PitStop-profile", account = email); this struct holds
/// only non-secret metadata, persisted to ~/.config/pitstop/profiles.json.
struct Profile {
    var email: String
    var savedAt: Date
    var subscriptionType: String?
    var rateLimitTier: String?
    /// The `oauthAccount` object from ~/.claude.json, kept verbatim so it can
    /// be restored exactly on switch.
    var oauthAccount: [String: Any]

    var displayName: String? { oauthAccount["displayName"] as? String }
    var organizationName: String? { oauthAccount["organizationName"] as? String }

    /// e.g. "Acme AI · Team · 5x" — drops auto-generated "<email>'s
    /// Organization" names and the noisy default_claude_ tier prefix.
    var planLabel: String {
        var parts: [String] = []
        if let org = organizationName, !org.isEmpty,
           org != "\(email)'s Organization" {
            parts.append(org)
        }
        if let sub = subscriptionType, !sub.isEmpty {
            parts.append(sub.capitalized)
        }
        if let tier = rateLimitTier, let r = tier.range(of: "max_") {
            parts.append(String(tier[r.upperBound...]))   // "5x" / "20x"
        }
        return parts.joined(separator: " · ")
    }

    fileprivate var asDict: [String: Any] {
        var d: [String: Any] = [
            "email": email,
            "savedAt": savedAt.timeIntervalSince1970,
            "oauthAccount": oauthAccount,
        ]
        if let subscriptionType { d["subscriptionType"] = subscriptionType }
        if let rateLimitTier { d["rateLimitTier"] = rateLimitTier }
        return d
    }

    fileprivate init?(dict: [String: Any]) {
        guard let email = dict["email"] as? String else { return nil }
        self.email = email
        self.savedAt = Date(timeIntervalSince1970: (dict["savedAt"] as? NSNumber)?.doubleValue ?? 0)
        self.subscriptionType = dict["subscriptionType"] as? String
        self.rateLimitTier = dict["rateLimitTier"] as? String
        self.oauthAccount = dict["oauthAccount"] as? [String: Any] ?? [:]
    }

    init(email: String, savedAt: Date, subscriptionType: String?,
         rateLimitTier: String?, oauthAccount: [String: Any]) {
        self.email = email
        self.savedAt = savedAt
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
        self.oauthAccount = oauthAccount
    }
}

final class ProfileStore {
    struct StoreError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// captureCurrent pairs credentials from the keychain with an identity
    /// from ~/.claude.json — two stores written by another program at
    /// different moments. These are the ways that pairing can be refused.
    enum CaptureError: LocalizedError {
        /// The token provably belongs to a different account than the one
        /// ~/.claude.json names (a mid-switch read of crossed stores).
        case mismatch(tokenOwner: String, configEmail: String)
        /// The token's owner couldn't be confirmed (network, expiry) — the
        /// pair might be fine, but filing it unverified risks poisoning.
        case unverifiable(String)

        var errorDescription: String? {
            switch self {
            case .mismatch(let owner, let email):
                return "Skipped saving \(email) — the logged-in credentials belong to \(owner)"
            case .unverifiable(let why):
                return "Couldn't confirm the logged-in account's identity: \(why)"
            }
        }
    }

    /// Everything captureCurrent touches outside its own state, injectable so
    /// its filing decisions are testable without a real keychain. Defaults
    /// are the production stores.
    struct Deps {
        var file: URL = ProfileStore.file
        var readLive: () async throws -> Data? = {
            try await Keychain.read(service: CredentialBlob.liveService)
        }
        var readProfileBlob: (String) async throws -> Data? = {
            try await Keychain.read(service: CredentialBlob.profileService, account: $0)
        }
        var writeProfileBlob: (String, Data) async throws -> Void = {
            try await Keychain.upsert(service: CredentialBlob.profileService, account: $0, data: $1)
        }
        var deleteProfileBlob: (String) async throws -> Void = {
            try await Keychain.delete(service: CredentialBlob.profileService, account: $0)
            try? await Keychain.delete(service: CredentialBlob.profileService,
                                       account: Keychain.stagingAccount(for: $0))
        }
        var writeLive: (Data) async throws -> Void = {
            try await Keychain.upsertLive(service: CredentialBlob.liveService, data: $0)
        }
        var oauthAccount: () -> [String: Any]? = { ClaudeConfig.oauthAccount() }
        var verifyOwner: (String) async throws -> String = {
            try await UsageAPI.fetchAccountEmail(accessToken: $0)
        }
        var refreshToken: (String) async throws
            -> (accessToken: String, refreshToken: String?, expiresAtMs: Double) = {
            try await UsageAPI.refresh(refreshToken: $0)
        }
    }

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/pitstop", isDirectory: true)
    static let file = directory.appendingPathComponent("profiles.json")

    /// The row-level error for a profile the identity audit gated: its saved
    /// credentials belonged to a different account and were deleted.
    struct ForeignCredentialsError: LocalizedError {
        let owner: String
        var errorDescription: String? {
            "Was showing \(owner)'s usage — sign in again"
        }
    }

    /// Create (or tighten) the config directory as user-only. The profile
    /// metadata inside enumerates every saved account's email/org/plan — not
    /// secrets, but nothing other local users need either. setAttributes runs
    /// even when the directory already exists so pre-existing 755 installs
    /// get tightened too.
    static func ensureDirectory(_ directory: URL = ProfileStore.directory) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: directory.path)
    }

    /// What the once-per-launch identity audit found for a profile.
    enum AuditOutcome: Equatable {
        case verified
        /// The stored credentials belong to `owner`, not the profile's email;
        /// the poisoned copy has been deleted.
        case poisoned(owner: String)
        /// Couldn't reach the identity endpoint — audit again next cycle.
        case unverifiable
    }

    private(set) var profiles: [Profile] = []
    private let deps: Deps
    /// Emails whose stored credentials passed this launch's identity audit.
    private var auditedEmails: Set<String> = []

    init(deps: Deps = Deps()) {
        self.deps = deps
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: deps.file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["profiles"] as? [[String: Any]] else {
            profiles = []
            return
        }
        profiles = list.compactMap(Profile.init(dict:)).sorted { $0.email < $1.email }
    }

    private func save() throws {
        try Self.ensureDirectory(deps.file.deletingLastPathComponent())
        let root: [String: Any] = ["profiles": profiles.map(\.asDict)]
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys])
        try AtomicFile.write(data, to: deps.file, mode: 0o600)
    }

    /// Snapshot the live Claude Code credentials + identity into a profile.
    /// Called on every refresh so the saved copy of the active account always
    /// holds the newest tokens. `profile` is nil when nobody is logged in;
    /// `changed` reports whether new credentials were actually stored (so the
    /// caller can notice an external re-login).
    @discardableResult
    func captureCurrent() async throws -> (profile: Profile?, changed: Bool) {
        guard let blob = try await deps.readLive() else { return (nil, false) }
        guard let account = deps.oauthAccount(),
              let email = account["emailAddress"] as? String else { return (nil, false) }

        // Called on every refresh — skip the keychain/file writes when
        // nothing changed since the last capture.
        if let existing = profiles.first(where: { $0.email == email }),
           let storedBlob = try? await deps.readProfileBlob(email),
           storedBlob == blob,
           (existing.oauthAccount as NSDictionary) == (account as NSDictionary) {
            return (existing, false)
        }

        // The blob (keychain) and identity (~/.claude.json) are separate
        // stores that Claude Code writes at different moments — reading them
        // mid-switch pairs one account's tokens with another's email, and
        // filing that pair makes both rows report the same usage forever.
        // Confirm the token's owner before filing; this only runs when the
        // credentials actually changed, so it's not a per-cycle HTTP call.
        var blobToStore = blob
        var creds = try CredentialBlob.parse(blob)
        if creds.isExpired {
            // Can't verify an expired token (e.g. first launch after days
            // away). Refresh it, and write the rotation back to the live item
            // so Claude Code's session survives it.
            guard let refreshToken = creds.refreshToken else {
                throw CaptureError.unverifiable("credentials are expired")
            }
            let fresh: (accessToken: String, refreshToken: String?, expiresAtMs: Double)
            do {
                fresh = try await deps.refreshToken(refreshToken)
            } catch {
                throw CaptureError.unverifiable(error.localizedDescription)
            }
            blobToStore = try CredentialBlob.patching(blob,
                                                      accessToken: fresh.accessToken,
                                                      refreshToken: fresh.refreshToken,
                                                      expiresAtMs: fresh.expiresAtMs)
            try await deps.writeLive(blobToStore)
            creds = try CredentialBlob.parse(blobToStore)
        }
        let owner: String
        do {
            owner = try await deps.verifyOwner(creds.accessToken)
        } catch {
            throw CaptureError.unverifiable(error.localizedDescription)
        }
        guard owner.caseInsensitiveCompare(email) == .orderedSame else {
            throw CaptureError.mismatch(tokenOwner: owner, configEmail: email)
        }

        try await deps.writeProfileBlob(email, blobToStore)
        let profile = Profile(email: email, savedAt: Date(),
                              subscriptionType: creds.subscriptionType,
                              rateLimitTier: creds.rateLimitTier,
                              oauthAccount: account)
        profiles.removeAll { $0.email == email }
        profiles.append(profile)
        profiles.sort { $0.email < $1.email }
        try save()
        return (profile, true)
    }

    /// Make `email` the live Claude Code account: snapshot whatever is
    /// currently live, then write the profile's blob into the live keychain
    /// item and its identity into ~/.claude.json.
    func switchTo(email: String) async throws {
        // A failed snapshot aborts the switch: overwriting the live item
        // without a fresh copy of the outgoing account could lose its only
        // valid refresh token. (A nil return — nobody logged in — is fine.)
        _ = try await captureCurrent()
        guard let profile = profiles.first(where: { $0.email == email }) else {
            throw StoreError(message: "No saved profile for \(email)")
        }
        guard let blob = try await Keychain.read(service: CredentialBlob.profileService, account: email) else {
            throw StoreError(message: "No saved credentials for \(email) — log in once with `claude` and save again")
        }
        let previousLive = try await Keychain.read(service: CredentialBlob.liveService)
        try await Keychain.upsertLive(service: CredentialBlob.liveService, data: blob)
        do {
            try ClaudeConfig.setOauthAccount(profile.oauthAccount)
        } catch {
            // Roll the live item back so the keychain and ~/.claude.json can't
            // disagree — captureCurrent refuses a mismatched pair, so leaving
            // one behind would block every capture until a manual re-login.
            if let previousLive {
                try? await Keychain.upsertLive(service: CredentialBlob.liveService, data: previousLive)
            }
            throw error
        }
    }

    func remove(email: String) async throws {
        try await Keychain.delete(service: CredentialBlob.profileService, account: email)
        // Clean up any staging item a crashed write left behind.
        try? await Keychain.delete(service: CredentialBlob.profileService,
                                   account: Keychain.stagingAccount(for: email))
        profiles.removeAll { $0.email == email }
        try save()
    }

    /// Integrity check for a profile whose credentials are about to be used:
    /// confirm the token's owner is the profile's email. Installs poisoned
    /// before capture-time verification existed hold another account's tokens
    /// under this email — both rows then report the same usage. Each email is
    /// checked once per launch (a passing audit is cached; failures are not).
    func auditIdentity(email: String, accessToken: String) async -> AuditOutcome {
        guard !auditedEmails.contains(email) else { return .verified }
        let owner: String
        do {
            owner = try await deps.verifyOwner(accessToken)
        } catch {
            return .unverifiable
        }
        guard owner.caseInsensitiveCompare(email) == .orderedSame else {
            // Drop the foreign copy — the rightful owner's tokens live under
            // their own profile (or the live item), so nothing real is lost,
            // and the row stops reporting another account's usage. The email
            // is deliberately not marked audited: post-re-login credentials
            // get checked afresh.
            try? await deps.deleteProfileBlob(email)
            return .poisoned(owner: owner)
        }
        auditedEmails.insert(email)
        return .verified
    }

    /// The credential blob to use for a profile — the live item for the
    /// active account (Claude Code keeps that one fresh), the saved copy
    /// otherwise.
    func blob(for email: String, isActive: Bool) async throws -> Data? {
        if isActive, let live = try await Keychain.read(service: CredentialBlob.liveService) {
            return live
        }
        return try await Keychain.read(service: CredentialBlob.profileService, account: email)
    }

    /// Persist a blob whose tokens we refreshed ourselves.
    func storeRefreshedBlob(_ data: Data, email: String, isActive: Bool) async throws {
        try await Keychain.upsert(service: CredentialBlob.profileService, account: email, data: data)
        if isActive {
            try await Keychain.upsertLive(service: CredentialBlob.liveService, data: data)
        }
    }
}
