# Claude Session Warming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** During configured hours, start a 5-hour Claude session on every saved account that has none running, so limit resets land inside the user's workday.

**Architecture:** A new `SessionWarmer` enum holds two pure, testable pieces — `shouldWarm` (window/session/cooldown decision) and `warmRequest` (the 1-token OAuth messages call) — plus a thin `warm` sender. AppDelegate runs `evaluateSessionWarming()` at the end of each `refreshAll` cycle, inside the serialized credential op (credential reads/refreshes must never race `captureCurrent` — that class of bug was fixed in 0.4.2). Three UserDefaults keys drive it; the settings window gets a "Session warming" section with two time pickers.

**Tech Stack:** Swift 6 toolchain / language mode v5, SwiftUI, XCTest, no dependencies.

**Spec:** `docs/superpowers/specs/2026-07-16-session-warming-design.md`

## Global Constraints

- UserDefaults keys, exactly: `sessionWarmingEnabled` (Bool, default **false** — plain `bool(forKey:)`), `warmWindowStartMinutes` (Int, default 360), `warmWindowEndMinutes` (Int, default 1080). 0 is a valid stored value for the window keys, so absence is detected via `object(forKey:) == nil` (the auto-switch absent-key pattern).
- Window semantics: start-inclusive, end-exclusive on local minutes-since-midnight; wrap-around (`start > end`) = `t >= start || t < end`; empty (`start == end`) never warms.
- Cooldown between warm attempts per account: 600 seconds.
- Warm request, exactly: `POST https://api.anthropic.com/v1/messages`, headers `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, `anthropic-version: 2023-06-01`, `Content-Type: application/json`; body `{"model": <SessionWarmer.model>, "max_tokens": 1, "system": <SessionWarmer.systemPrompt>, "messages": [{"role": "user", "content": "hi"}]}`. Any 2xx = warmed.
- `[verify]` values (resolved in Task 7's step 1, updated in code if wrong): `SessionWarmer.model = "claude-haiku-4-5-20251001"`, `SessionWarmer.systemPrompt = "You are Claude Code, Anthropic's official CLI for Claude."`, and idle accounts report `five_hour.resets_at` absent or past.
- Warm failures are silent: they never write `fetchError`/`needsAction`, never notify.
- Accounts with a `fetchError`, in `needsAction`, or with a future `nextFetchAllowed` are never warmed.
- Credential access for warming stays inside `refreshAll`'s serialized op — no detached `Task {}` around `freshCredentials`.
- Scope: saved Claude profiles only (no Codex/Gemini/Desktop-only).
- Test command: `swift test --filter <ClassName>`; full suite `swift test`.
- Commit after every task; do NOT push — the user E2E-tests the installed app first.

---

### Task 1: `SessionWarmer.shouldWarm`

**Files:**
- Create: `Sources/PitStop/SessionWarmer.swift`
- Test: `Tests/PitStopTests/SessionWarmerTests.swift` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces: `SessionWarmer.shouldWarm(now: Date, windowStartMinutes: Int, windowEndMinutes: Int, resetsAt: Date?, lastAttempt: Date?, calendar: Calendar = .current) -> Bool` and `SessionWarmer.attemptCooldown: TimeInterval` (= 600). Task 4 calls `shouldWarm`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PitStopTests/SessionWarmerTests.swift`:

```swift
import XCTest
@testable import PitStop

final class SessionWarmerTests: XCTestCase {
    /// A fixed, deterministic date — 2026-07-16 at h:m local time.
    private func at(_ h: Int, _ m: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 16,
                                                   hour: h, minute: m))!
    }

    /// shouldWarm with only the argument under test varying.
    private func warm(now: Date, start: Int = 360, end: Int = 1080,
                      resetsAt: Date? = nil, lastAttempt: Date? = nil) -> Bool {
        SessionWarmer.shouldWarm(now: now, windowStartMinutes: start,
                                 windowEndMinutes: end, resetsAt: resetsAt,
                                 lastAttempt: lastAttempt)
    }

    func testWindowBounds() {
        XCTAssertTrue(warm(now: at(7, 0)))              // inside 6:00–18:00
        XCTAssertFalse(warm(now: at(5, 59)))            // before start
        XCTAssertTrue(warm(now: at(6, 0)))              // start is inclusive
        XCTAssertFalse(warm(now: at(18, 0)))            // end is exclusive
        XCTAssertFalse(warm(now: at(23, 30)))           // after end
    }

    func testWrapAroundWindow() {
        // 22:00–04:00 spans midnight.
        XCTAssertTrue(warm(now: at(23, 0), start: 1320, end: 240))
        XCTAssertTrue(warm(now: at(3, 0), start: 1320, end: 240))
        XCTAssertFalse(warm(now: at(12, 0), start: 1320, end: 240))
    }

    func testEmptyWindowNeverWarms() {
        XCTAssertFalse(warm(now: at(7, 0), start: 420, end: 420))
    }

    func testRunningSessionBlocksWarm() {
        let now = at(9, 0)
        XCTAssertFalse(warm(now: now, resetsAt: now.addingTimeInterval(3600)))
        XCTAssertTrue(warm(now: now, resetsAt: now.addingTimeInterval(-60)))  // window ended
        XCTAssertTrue(warm(now: now, resetsAt: nil))                          // never started
    }

    func testCooldownBlocksRetry() {
        let now = at(9, 0)
        XCTAssertFalse(warm(now: now, lastAttempt: now.addingTimeInterval(-9 * 60)))
        XCTAssertTrue(warm(now: now, lastAttempt: now.addingTimeInterval(-11 * 60)))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionWarmerTests`
Expected: build FAILS with `cannot find 'SessionWarmer' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/PitStop/SessionWarmer.swift`:

```swift
import Foundation

/// Proactively starts ("warms") a Claude 5-hour session so its reset lands
/// inside the user's day instead of at its end (spec:
/// docs/superpowers/specs/2026-07-16-session-warming-design.md). Warming
/// never raises or evades a cap — it only chooses when the session clock
/// starts, and the 1-token request spends from the same quota.
enum SessionWarmer {
    /// Cooldown between warm attempts per account, so a failed request or a
    /// not-yet-refreshed usage report can't cause hammering.
    static let attemptCooldown: TimeInterval = 600

    /// True when a warm should be attempted: local time-of-day inside the
    /// start-inclusive, end-exclusive window (wrap-around supported; an
    /// empty window never warms), no running session (resetsAt nil or
    /// past), and the per-account cooldown has passed.
    static func shouldWarm(now: Date, windowStartMinutes: Int, windowEndMinutes: Int,
                           resetsAt: Date?, lastAttempt: Date?,
                           calendar: Calendar = .current) -> Bool {
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        let t = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let inWindow = windowStartMinutes <= windowEndMinutes
            ? t >= windowStartMinutes && t < windowEndMinutes
            : t >= windowStartMinutes || t < windowEndMinutes
        guard inWindow else { return false }
        if let resetsAt, resetsAt > now { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < attemptCooldown {
            return false
        }
        return true
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SessionWarmerTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PitStop/SessionWarmer.swift Tests/PitStopTests/SessionWarmerTests.swift
git commit -m "Add SessionWarmer.shouldWarm window/session/cooldown decision"
```

---

### Task 2: `SessionWarmer.warmRequest` + `warm`

**Files:**
- Modify: `Sources/PitStop/SessionWarmer.swift` (extend the enum from Task 1)
- Test: `Tests/PitStopTests/SessionWarmerTests.swift` (extend the class from Task 1)

**Interfaces:**
- Consumes: the `SessionWarmer` enum from Task 1.
- Produces: `SessionWarmer.warmRequest(accessToken: String) -> URLRequest`, `SessionWarmer.warm(accessToken: String) async -> Bool`, `SessionWarmer.model: String`, `SessionWarmer.systemPrompt: String`. Task 4 calls `warm`.

- [ ] **Step 1: Write the failing test**

Append inside `final class SessionWarmerTests`:

```swift
    func testWarmRequestShape() throws {
        let req = SessionWarmer.warmRequest(accessToken: "tok-123")
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(req.httpBody)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, SessionWarmer.model)
        XCTAssertEqual(root["max_tokens"] as? Int, 1)
        XCTAssertEqual(root["system"] as? String, SessionWarmer.systemPrompt)
        let messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.first?["content"] as? String, "hi")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionWarmerTests`
Expected: build FAILS with `type 'SessionWarmer' has no member 'warmRequest'`.

- [ ] **Step 3: Write minimal implementation**

Add inside `enum SessionWarmer` (after `shouldWarm`):

```swift
    static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    /// [verify] Cheapest model the OAuth messages path accepts.
    static let model = "claude-haiku-4-5-20251001"
    /// [verify] OAuth-authenticated messages calls require Claude Code's
    /// system prompt.
    static let systemPrompt = "You are Claude Code, Anthropic's official CLI for Claude."

    /// The 1-token session-starting request. Any 2xx counts as warmed;
    /// the response body is discarded.
    static func warmRequest(accessToken: String) -> URLRequest {
        var req = URLRequest(url: messagesURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1,
            "system": systemPrompt,
            "messages": [["role": "user", "content": "hi"]],
        ])
        return req
    }

    /// Send the warm request. Silent by design — failures just retry after
    /// the cooldown; nothing is surfaced to the row display.
    static func warm(accessToken: String) async -> Bool {
        guard let (_, resp) = try? await URLSession.shared.data(
            for: warmRequest(accessToken: accessToken)),
            let http = resp as? HTTPURLResponse else { return false }
        return (200 ..< 300).contains(http.statusCode)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SessionWarmerTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PitStop/SessionWarmer.swift Tests/PitStopTests/SessionWarmerTests.swift
git commit -m "Add SessionWarmer warm request builder and sender"
```

---

### Task 3: Settings keys

**Files:**
- Modify: `Sources/PitStop/Settings.swift` (inside `enum Settings`, after `autoSwitchKinds`; and the `observedKeys` array)
- Test: `Tests/PitStopTests/SessionWarmingSettingsTests.swift` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces: `Settings.sessionWarmingEnabled: Bool`, `Settings.warmWindowStartMinutes: Int`, `Settings.warmWindowEndMinutes: Int`; keys `sessionWarmingEnabled`, `warmWindowStartMinutes`, `warmWindowEndMinutes` appended to `Settings.observedKeys`. Task 4 reads all three; Task 5 binds the same key strings via `@AppStorage`.

- [ ] **Step 1: Write the failing test**

Create `Tests/PitStopTests/SessionWarmingSettingsTests.swift`:

```swift
import XCTest
@testable import PitStop

final class SessionWarmingSettingsTests: XCTestCase {
    private let keys = ["sessionWarmingEnabled", "warmWindowStartMinutes",
                        "warmWindowEndMinutes"]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    func testDefaults() {
        XCTAssertFalse(Settings.sessionWarmingEnabled)      // opt-in
        XCTAssertEqual(Settings.warmWindowStartMinutes, 360)  // 6:00 AM
        XCTAssertEqual(Settings.warmWindowEndMinutes, 1080)   // 6:00 PM
    }

    func testStoredValuesHonoredIncludingMidnight() {
        UserDefaults.standard.set(true, forKey: "sessionWarmingEnabled")
        UserDefaults.standard.set(0, forKey: "warmWindowStartMinutes")
        UserDefaults.standard.set(720, forKey: "warmWindowEndMinutes")
        XCTAssertTrue(Settings.sessionWarmingEnabled)
        XCTAssertEqual(Settings.warmWindowStartMinutes, 0)   // midnight ≠ "unset"
        XCTAssertEqual(Settings.warmWindowEndMinutes, 720)
    }

    func testObservedKeysIncludeWarmingKeys() {
        keys.forEach { XCTAssertTrue(Settings.observedKeys.contains($0)) }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionWarmingSettingsTests`
Expected: build FAILS with `type 'Settings' has no member 'sessionWarmingEnabled'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/PitStop/Settings.swift`, inside `enum Settings` after the `autoSwitchKinds` property:

```swift
    /// Proactively start a 5-hour session on each saved Claude account when
    /// none is running (see SessionWarmer). Off by default — it sends
    /// requests on the user's behalf.
    static var sessionWarmingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "sessionWarmingEnabled")
    }

    /// Warming window bounds, minutes since local midnight (default
    /// 6:00 AM – 6:00 PM). 0 (midnight) is a valid stored value, so absence
    /// is detected via object(forKey:) — the auto-switch absent-key pattern.
    static var warmWindowStartMinutes: Int {
        UserDefaults.standard.object(forKey: "warmWindowStartMinutes") == nil
            ? 360 : UserDefaults.standard.integer(forKey: "warmWindowStartMinutes")
    }

    static var warmWindowEndMinutes: Int {
        UserDefaults.standard.object(forKey: "warmWindowEndMinutes") == nil
            ? 1080 : UserDefaults.standard.integer(forKey: "warmWindowEndMinutes")
    }
```

Replace the `observedKeys` array:

```swift
    /// Keys AppDelegate watches to refresh the UI when settings change.
    static let observedKeys = [
        "indicatorStyle", "indicatorMetric", "menuBarSource",
        "autoSwitchEnabled", "autoSwitchThreshold", "showProjection",
        "autoSwitchOnSession", "autoSwitchOnWeekly", "autoSwitchOnPerModel",
        "sessionWarmingEnabled", "warmWindowStartMinutes", "warmWindowEndMinutes",
    ]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SessionWarmingSettingsTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PitStop/Settings.swift Tests/PitStopTests/SessionWarmingSettingsTests.swift
git commit -m "Add session warming settings keys"
```

---

### Task 4: AppDelegate executor

**Files:**
- Modify: `Sources/PitStop/AppDelegate.swift` — new `lastWarmAttempt` var near the other per-account dicts (~line 168, after `private var usage`), new `evaluateSessionWarming()` method after `evaluateAutoSwitch` (~line 1230), one call added in `refreshAll`.

**Interfaces:**
- Consumes: `Settings.sessionWarmingEnabled` / `warmWindowStartMinutes` / `warmWindowEndMinutes` (Task 3); `SessionWarmer.shouldWarm` (Task 1); `SessionWarmer.warm` (Task 2); existing `freshCredentials(for:isActive:) async throws -> OAuthCredentials`, `store.profiles`, `activeEmail`, `usage`, `fetchError`, `needsAction`, `nextFetchAllowed`.
- Produces: behavior only.

- [ ] **Step 1: Add the state var**

After the `usage` declaration (`private var usage: [String: UsageReport] = [:]`):

```swift
    /// Last session-warm attempt per account, successful or not — the
    /// cooldown that keeps a failure (or a not-yet-refreshed report) from
    /// hammering. In-memory only, deliberately NOT in UsageCache: the next
    /// fetch answers "is a session running" authoritatively, and a duplicate
    /// warm during an active session is a harmless no-op.
    private var lastWarmAttempt: [String: Date] = [:]
```

- [ ] **Step 2: Add the executor**

After the closing brace of `evaluateAutoSwitch()`:

```swift
    /// Start a 5-hour session on each saved Claude account that has none
    /// running (see SessionWarmer). Runs inside refreshAll's serialized
    /// credential op — freshCredentials may rotate tokens, and those writes
    /// must never race captureCurrent. Failures are silent by design: no
    /// fetchError, no notification — just another attempt after the
    /// cooldown. Broken, gated, or backed-off accounts are never poked.
    private func evaluateSessionWarming() async {
        guard Settings.sessionWarmingEnabled else { return }
        let now = Date()
        for profile in store.profiles {
            let email = profile.email
            guard fetchError[email] == nil, !needsAction.contains(email),
                  nextFetchAllowed[email].map({ $0 <= now }) ?? true,
                  SessionWarmer.shouldWarm(
                      now: now,
                      windowStartMinutes: Settings.warmWindowStartMinutes,
                      windowEndMinutes: Settings.warmWindowEndMinutes,
                      resetsAt: usage[email]?.fiveHour?.resetsAt,
                      lastAttempt: lastWarmAttempt[email]) else { continue }
            lastWarmAttempt[email] = now
            guard let creds = try? await freshCredentials(for: email,
                                                          isActive: email == activeEmail)
            else { continue }
            _ = await SessionWarmer.warm(accessToken: creds.accessToken)
        }
    }
```

- [ ] **Step 3: Call it from refreshAll**

In `refreshAll`, the tail currently reads:

```swift
            checkThresholds()
            evaluateAutoSwitch()
            scheduleBackoffRetry()
            checkForUpdatesIfDue()
```

Insert the warming call after `evaluateAutoSwitch()`:

```swift
            checkThresholds()
            evaluateAutoSwitch()
            await evaluateSessionWarming()
            scheduleBackoffRetry()
            checkForUpdatesIfDue()
```

- [ ] **Step 4: Build and run the full suite**

Run: `swift build && swift test`
Expected: build succeeds; all tests PASS (feature is off by default — no behavior change until the toggle is enabled).

- [ ] **Step 5: Commit**

```bash
git add Sources/PitStop/AppDelegate.swift
git commit -m "Warm idle Claude sessions at the end of each refresh cycle"
```

---

### Task 5: Settings window section

**Files:**
- Modify: `Sources/PitStop/SettingsWindow.swift` — three `@AppStorage` properties after `triggerPerModel` (line 17), a `timeBinding` helper inside `SettingsView`, and a new Section between "Auto-switch" and "Usage".

**Interfaces:**
- Consumes: the UserDefaults keys from Task 3 via `@AppStorage` (same-key binding is how this window shares state with `Settings`).
- Produces: UI only.

- [ ] **Step 1: Add the properties**

After the `triggerPerModel` property:

```swift
    @AppStorage("sessionWarmingEnabled") private var warming = false
    @AppStorage("warmWindowStartMinutes") private var warmStart = 360
    @AppStorage("warmWindowEndMinutes") private var warmEnd = 1080
```

- [ ] **Step 2: Add the binding helper**

Inside `SettingsView`, after the `body` property's closing brace (still inside the struct):

```swift
    /// An hourAndMinute DatePicker over a minutes-since-midnight Int.
    /// Only the time-of-day components of the Date are meaningful.
    private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(byAdding: .minute, value: minutes.wrappedValue,
                                      to: Calendar.current.startOfDay(for: Date())) ?? Date()
            },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }
```

- [ ] **Step 3: Add the section**

Between the "Auto-switch" and "Usage" sections:

```swift
            Section("Session warming") {
                Toggle("Keep Claude sessions started", isOn: $warming)
                if warming {
                    DatePicker("From", selection: timeBinding($warmStart),
                               displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: timeBinding($warmEnd),
                               displayedComponents: .hourAndMinute)
                }
                Text("Starts a 5-hour session on every saved Claude account whenever none is running during these hours, so limit resets land inside your day instead of at its end. Costs about one token per account per session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
```

- [ ] **Step 4: Build and run the full suite**

Run: `swift build && swift test`
Expected: build succeeds; all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PitStop/SettingsWindow.swift
git commit -m "Add session warming section to Settings"
```

---

### Task 6: README + CHANGELOG

**Files:**
- Modify: `README.md` — new bullet directly after the Auto-switch bullet (which ends "…Desktop is read-only and left alone.")
- Modify: `CHANGELOG.md` — append to the `### Added` list under `## [Unreleased]`

**Interfaces:**
- Consumes: nothing — prose only.
- Produces: nothing later tasks rely on.

- [ ] **Step 1: Add the README bullet**

Insert after the Auto-switch bullet:

```markdown
- **Session warming** (off by default) starts a 5-hour session on every
  saved Claude account whenever none is running during your configured
  hours (default 6 AM–6 PM), so limit resets land inside your day instead
  of at its end. Costs about one token per account per session; caps are
  unaffected — it only chooses when the session clock starts.
```

- [ ] **Step 2: Add the CHANGELOG entry**

Under `## [Unreleased]` → `### Added`, after the auto-switch entry:

```markdown
- **Session warming.** Opt-in: during configured hours (default 6 AM–6 PM),
  PitStop starts a 5-hour session on every saved Claude account whenever
  none is running, so limit resets land inside your day instead of at its
  end. One ~1-token request per account per session; caps are unaffected —
  it only chooses when the session clock starts.
```

- [ ] **Step 3: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "Document session warming"
```

---

### Task 7: E2E verification + [verify] resolution

**Files:** possibly `Sources/PitStop/SessionWarmer.swift` (if a [verify] value is wrong). Follow `.claude/skills/verify/SKILL.md`; per its gotchas, never touch the live `Claude Code-credentials` item, and expect 429 backoffs if bursting.

- [ ] **Step 1: Resolve the [verify] items with one manual warm call**

Extract the idle saved account's access token and send the exact request once (this is the feature's own action, done by hand — it burns ~1 token on that account):

```bash
TOK=$(security find-generic-password -s "PitStop-profile" -a livin2021@gmail.com -w \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])")
curl -sS -o /tmp/warm-resp.json -w "%{http_code}\n" \
  https://api.anthropic.com/v1/messages \
  -H "Authorization: Bearer $TOK" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"system":"You are Claude Code, Anthropic'\''s official CLI for Claude.","messages":[{"role":"user","content":"hi"}]}'
cat /tmp/warm-resp.json
```

Expected: `200` and a message response. If 4xx, read the error body and adjust `SessionWarmer.model` / `SessionWarmer.systemPrompt` accordingly (commit the correction with message "Correct warm request per live API"), re-run until 200. If the token is expired (401), first refresh via the app (`.build/release/PitStop --check` refreshes saved profiles) and re-extract.

Also confirm idle-session detection: before the curl, `.build/release/PitStop --check` — the idle account's 5-hour line should show no active window (0% / stale reset); after the curl, re-run `--check` and its 5-hour `resets ≈ now + 5h`. This resolves all three [verify] items.

- [ ] **Step 2: Install and launch**

Run: `osascript -e 'quit app "PitStop"'; ./scripts/make-app.sh && open -a /Applications/PitStop.app`
Expected: installed and running.

- [ ] **Step 3: Enable warming in the UI and watch it fire**

Open Settings (⌘,), enable "Keep Claude sessions started", confirm the From/To pickers show 6:00 AM / 6:00 PM and the current time is inside the window (adjust "To" later if running this after 6 PM). Wait one refresh cycle (≤2 min), then run `.build/release/PitStop --check`.
Expected: every saved Claude account shows a running 5-hour window (`resets` ≈ 5 h from its warm moment). The account that already had a session (the active one, if in use) keeps its original reset — warming skipped it.

- [ ] **Step 4: Restore user state**

Turn "Keep Claude sessions started" back OFF in Settings (it's opt-in; the user decides when to adopt it). Verify: `defaults read dev.livin.pitstop sessionWarmingEnabled` → `0`.

- [ ] **Step 5: Hand off for user E2E**

Do NOT push. Report completion — the lasting behavioral check (warms at ~6 AM, three aligned resets across the day) plays out over a real workday on the user's machine.
