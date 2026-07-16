# Claude Session Warming — Design

**Date:** 2026-07-16
**Status:** Approved

## Problem

Claude's 5-hour session window starts at the first request and resets 5 hours
later. Starting a workday cold at 9 AM means the reset lands at 2 PM — hit the
limit at 11:30 and you wait 2½ hours. If a session had already been started at
6 AM, the reset lands at 11 AM and the workday spans more (and better-placed)
reset boundaries. This choice of *when the clock starts* is the user's to
make, but nothing makes it automatically.

Warming does not raise or evade any cap: session and weekly quotas apply
unchanged, and the warm request itself consumes (a trivial slice of) the same
quota. It only phase-aligns the session clock with the user's day —
equivalent to sending "hi" from the app at 6 AM by hand.

## Decisions (user-approved)

1. **Rolling window, not a fixed daily time:** during the configured hours,
   whenever no session is running on an account, start one. Window 6 AM–6 PM
   ⇒ sessions start ~6:00, ~11:00, ~16:00.
2. **All saved Claude accounts**, not just the active one — pairs with
   auto-switch: fallback accounts arrive pre-aligned.
3. **Custom hours, every day:** two time pickers (default 6:00 AM–6:00 PM),
   no weekday filter.
4. **Opt-in:** default off — the feature sends requests on the user's behalf.
5. **Silent failures:** a failed warm retries after a cooldown and never
   touches the row's error/display state.

## Warm mechanism

`POST https://api.anthropic.com/v1/messages` authenticated with the saved
account's OAuth bearer token (same `freshCredentials` path the usage fetch
uses):

- Headers: `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`,
  `anthropic-version: 2023-06-01`, `Content-Type: application/json`.
- Body: cheapest Haiku model [verify exact current id], `max_tokens: 1`,
  one user message `"hi"`, and the Claude Code system-prompt prefix
  [verify — OAuth-authenticated messages calls reportedly require
  `"You are Claude Code, Anthropic's official CLI for Claude."` as the
  system prompt].
- Any 2xx counts as warmed. Response body is discarded.

Both [verify] items are resolved during implementation E2E against a real
idle account before the feature is considered working.

## Session-active detection

From the usage report PitStop already fetches every 2 minutes:
a session is running iff `fiveHour.resetsAt` is in the future. `nil` or past
⇒ no active session ⇒ warmable. [verify on an idle account: hypothesis is
that an idle account reports `resets_at` absent or in the past.]

## Components

### `SessionWarmer.swift` (new)

- `static func shouldWarm(now: Date, windowStartMinutes: Int,
  windowEndMinutes: Int, resetsAt: Date?, lastAttempt: Date?) -> Bool`
  — pure. True iff:
  - `now`'s local time-of-day `t` (minutes since midnight) is inside the
    window: start-inclusive, end-exclusive — `t >= start && t < end` when
    `start <= end`; wrap-around windows (start > end, e.g. 22:00–04:00) use
    `t >= start || t < end`. An empty window (`start == end`) never warms.
  - `resetsAt` is nil or ≤ now (no running session).
  - `lastAttempt` is nil or ≥ 10 minutes ago (cooldown — a failure or a
    not-yet-refreshed report can't cause hammering).
- `static func warmRequest(accessToken: String) -> URLRequest` — pure
  builder for the request above.
- `static func warm(accessToken: String) async -> Bool` — sends, returns
  success. No thrown detail needed; failures are silent by design.

### AppDelegate integration

At the end of `refreshAll` (fresh reports and tokens in hand), for each
saved Claude profile:

- Skip unless `Settings.sessionWarmingEnabled`.
- Skip if the account has a `fetchError`, is in `needsAction`, or has an
  active backoff (`nextFetchAllowed` in the future) — never poke a broken or
  rate-limited account.
- Skip unless `SessionWarmer.shouldWarm(...)` with the account's
  `usage[email]?.fiveHour?.resetsAt` and `lastWarmAttempt[email]`.
- Record `lastWarmAttempt[email] = now` (in-memory only — deliberately NOT
  in UsageCache: after a relaunch the report re-fetch answers the question
  authoritatively, and a duplicate warm during an active session is a
  harmless no-op that doesn't restart the clock).
- `freshCredentials(for:)` → `SessionWarmer.warm(accessToken:)`,
  fire-and-forget. Success is visible on the next tick as the running
  window; failure retries after the cooldown.

Warming issues at most ~3 requests/account/day with the default window.

### Settings

New UserDefaults keys (all appended to `Settings.observedKeys`):

- `sessionWarmingEnabled` — Bool, default **false**.
- `warmWindowStartMinutes` — Int minutes-since-midnight, default 360 (6:00).
- `warmWindowEndMinutes` — Int, default 1080 (18:00). (0 is a valid stored
  value = midnight; "unset" is detected via `object(forKey:) == nil`, the
  same absent-key pattern the auto-switch keys use.)

### UI (SettingsWindow)

New "Session warming" section between Auto-switch and Usage:

```
Section("Session warming")
  Toggle("Keep Claude sessions started", isOn: $warming)
  if warming {
    DatePicker("From", …hourAndMinute…)   // bound to warmWindowStartMinutes
    DatePicker("To", …hourAndMinute…)     // bound to warmWindowEndMinutes
  }
  Text(caption).font(.caption).foregroundStyle(.secondary)
```

Caption: "Starts a 5-hour session on every saved Claude account whenever
none is running during these hours, so limit resets land inside your day
instead of at its end. Costs about one token per account per session."

The pickers bind minutes-since-midnight Ints to `Date` values via a small
computed Binding (today's midnight + minutes); only the hour/minute
components matter.

## Testing

- `shouldWarm`: inside/outside window, boundary times (exactly start,
  exactly end), wrap-around window (22:00–04:00 spans midnight), running
  session (future resetsAt) → false, nil/past resetsAt → true, cooldown
  (9 min ago → false, 11 min ago → true).
- `warmRequest`: URL, method, bearer + beta + version headers, body decodes
  to the expected model / max_tokens / system / message shape.
- Settings: defaults when keys absent (false / 360 / 1080), stored values
  honored including 0.
- E2E (installed app, verify skill): enable warming with a window covering
  now; the idle saved account (no running session) gets warmed on the next
  cycle; the following fetch shows its 5-hour window running with
  `resets_at ≈ now + 5h`; the active account (session already running) is
  left alone. Resolves both [verify] items.

## Out of scope

- Codex/Gemini warming (different auth and session semantics)
- Per-account warm toggles; weekday filters; fixed-time mode
- Desktop-only accounts (no OAuth token to warm with)
- Persisting `lastWarmAttempt` across launches
- Any notification/menu UI for warm activity (the row's reset stamp shows it)
