import Foundation

/// OpenCode Go's local API credential and subscription quota endpoint.
/// OpenCode stores provider credentials in its XDG data directory
/// (`$XDG_DATA_HOME/opencode/auth.json`, `~/.local/share/opencode/auth.json`
/// by default); the official Go endpoint reports rolling, weekly, and monthly
/// percentages.
enum OpenCode {
    /// OpenCode's auth store is provider-scoped rather than account-scoped, so
    /// there is no account identity to key on — this fixed name stands in for
    /// the subscription. Every site that names the row (menu row, storage key,
    /// prune list, `--check`) goes through these two constants so they can't
    /// drift apart; `accountKey` matches what `MenuAccount.key` derives for a
    /// row built with `accountName`.
    static let accountName = "OpenCode Go"
    static let accountKey = "opencode:\(accountName)"

    struct Usage: Codable, Equatable {
        struct Window: Codable, Equatable {
            var label: String
            var usedPercent: Double
            var resetsAt: Date?
        }

        var windows: [Window]
        var useBalance = false
        var fetchedAt = Date()

        var maxUtilization: Double { windows.map(\.usedPercent).max() ?? 0 }
    }

    enum OpenCodeError: LocalizedError {
        case unauthorized
        case noSubscription
        case malformed
        case notSignedIn
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "OpenCode Go token rejected — reconnect OpenCode Go"
            case .noSubscription: return "OpenCode Go subscription required"
            case .malformed: return "Unexpected OpenCode Go usage response"
            case .notSignedIn: return "Not connected to OpenCode Go"
            case .http(let code): return "HTTP \(code) from OpenCode Go"
            }
        }
    }

    /// Resolved once: `ProcessInfo.environment` rebuilds a dictionary on every
    /// access, and the variable can't change under a running process anyway.
    static let authURL: URL = authURL(
        xdgDataHome: ProcessInfo.processInfo.environment["XDG_DATA_HOME"],
        home: FileManager.default.homeDirectoryForCurrentUser)

    /// OpenCode resolves its data directory the XDG way, so honor the same
    /// override instead of assuming the default location. Per the XDG spec a
    /// relative `XDG_DATA_HOME` is invalid and ignored, which also means a GUI
    /// launch that never inherited the variable lands on the default path.
    static func authURL(xdgDataHome: String?, home: URL) -> URL {
        let base: URL
        if let xdgDataHome, xdgDataHome.hasPrefix("/") {
            base = URL(fileURLWithPath: xdgDataHome, isDirectory: true)
        } else {
            base = home.appendingPathComponent(".local/share")
        }
        return base.appendingPathComponent("opencode/auth.json")
    }

    static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    /// True when OpenCode has been used on this machine at all — its auth
    /// store exists, whether or not it holds a Go subscription key. Only
    /// `--check` distinguishes this from `isPresent`, so it can say "installed
    /// but not signed in" rather than staying silent.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: authURL.path)
    }

    /// True when a Go subscription key is configured — OpenCode may well be
    /// installed with only bring-your-own-key providers, and those users have
    /// no Go quota to show.
    ///
    /// The menu asks this several times per refresh, so the parse is memoized
    /// against the auth file's identity and redone only when the file actually
    /// changes (a login, a logout, a token rotation).
    static var isPresent: Bool {
        cachedAPIKey() != nil
    }

    private static let cacheLock = NSLock()
    private static var cachedStamp: FileStamp?
    private static var cachedKey: String?

    /// Cheap identity for the auth file — enough to notice any rewrite without
    /// reading the contents.
    private struct FileStamp: Equatable {
        var modified: Date
        var size: Int

        init?(_ url: URL) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attrs[.modificationDate] as? Date,
                  let size = attrs[.size] as? Int else { return nil }
            self.modified = modified
            self.size = size
        }
    }

    /// The Go API key, re-read only when `auth.json` has changed since the
    /// last read. Returns nil when the file is absent or holds no Go key.
    static func cachedAPIKey() -> String? {
        let url = authURL
        let stamp = FileStamp(url)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if stamp == cachedStamp { return cachedKey }
        cachedStamp = stamp
        cachedKey = stamp == nil ? nil : apiKey(from: try? Data(contentsOf: url))
        return cachedKey
    }

    /// The OpenCode auth file contains one object per provider ID. Only the
    /// OpenCode Go API key is relevant to this provider integration.
    static func apiKey(from data: Data?) -> String? {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = root["opencode-go"] as? [String: Any],
              auth["type"] as? String == "api",
              let key = auth["key"] as? String,
              !key.isEmpty else { return nil }
        return key
    }

    static func liveUsage() async throws -> Usage {
        guard let key = cachedAPIKey() else { throw OpenCodeError.notSignedIn }
        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("PitStop", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenCodeError.malformed }
        if http.statusCode == 401 { throw OpenCodeError.unauthorized }
        if http.statusCode == 403 { throw OpenCodeError.noSubscription }
        // Share the rate-limit type with the other providers so recordFetchError
        // applies the usual Retry-After / exponential backoff instead of
        // re-hitting a limited endpoint every refresh.
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw UsageAPI.APIError.rateLimited(retryAfter: retryAfter)
        }
        guard http.statusCode == 200 else { throw OpenCodeError.http(http.statusCode) }
        return try parseUsage(data)
    }

    /// Resets more than this far out are nonsense for 5h/7d/30d windows. The
    /// clamp keeps a bad payload from producing a `Date` so extreme that
    /// downstream arithmetic misbehaves.
    private static let maxReset: TimeInterval = 400 * 86400

    /// Parse the endpoint's usage objects. The endpoint has returned both the
    /// original rollingUsage/usagePercent/resetInSec shape and the current
    /// usage/percent/resetsAt shape, so accept both during the API transition.
    static func parseUsage(_ data: Data, now: Date = Date()) throws -> Usage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenCodeError.malformed
        }
        let windows: [(String, String, String)] = [
            ("5h", "rollingUsage", "rolling"),
            ("7d", "weeklyUsage", "weekly"),
            ("30d", "monthlyUsage", "monthly"),
        ]
        let current = root["usage"] as? [String: Any]
        let parsed = windows.compactMap { label, legacyKey, currentKey -> Usage.Window? in
            let value = (current?[currentKey] as? [String: Any]) ??
                (root[legacyKey] as? [String: Any])
            guard let value,
                  let percent = (value["percent"] as? NSNumber)?.doubleValue
                    ?? (value["usagePercent"] as? NSNumber)?.doubleValue,
                  percent.isFinite else { return nil }
            let reset: Date?
            if let resetString = value["resetsAt"] as? String {
                reset = parseISO8601(resetString)
            } else if let seconds = (value["resetInSec"] as? NSNumber)?.doubleValue,
                      seconds.isFinite {
                reset = now.addingTimeInterval(min(max(0, seconds), maxReset))
            } else {
                reset = nil
            }
            return Usage.Window(label: label,
                                usedPercent: max(0, min(100, percent)),
                                resetsAt: reset)
        }
        let useBalance = (root["useBalance"] as? Bool)
            ?? (current?["useBalance"] as? Bool)
            ?? false
        // A balance-funded account legitimately reports no quota windows, so
        // only treat "no windows at all" as malformed when quotas were the
        // thing we expected to find.
        guard !parsed.isEmpty || useBalance else { throw OpenCodeError.malformed }
        return Usage(windows: parsed, useBalance: useBalance, fetchedAt: now)
    }

    /// RFC3339 with or without a fractional part. `ISO8601DateFormatter`
    /// accepts exactly-millisecond fractions and nothing else, while the Go
    /// backend emits RFC3339Nano — which *omits* the fraction when it is zero
    /// and can run to nine digits when it isn't. Try both formatters, then
    /// strip the fraction and reparse.
    static func parseISO8601(_ s: String) -> Date? {
        if let d = iso8601Frac.date(from: s) { return d }
        if let d = iso8601.date(from: s) { return d }
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let rest = s[s.index(after: dot)...]
        guard let tz = rest.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) else { return nil }
        return iso8601.date(from: String(s[..<dot]) + String(rest[tz...]))
    }

    private static let iso8601Frac: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

extension OpenCode.Usage {
    /// Synthesized decoding ignores the property defaults above and throws on
    /// a missing key — and one such throw makes `UsageCache.load` discard the
    /// whole shared snapshot, taking every other provider's cached state with
    /// it. Decode the defaulted fields leniently so a cache written by another
    /// build stays readable. Declaring this in an extension keeps both the
    /// memberwise initializer and the synthesized `encode(to:)`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windows = try container.decodeIfPresent([Window].self, forKey: .windows) ?? []
        useBalance = try container.decodeIfPresent(Bool.self, forKey: .useBalance) ?? false
        // An entry with no stamp can't be aged, so treat it as already stale
        // rather than passing it off as a fresh reading.
        fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? .distantPast
    }
}
