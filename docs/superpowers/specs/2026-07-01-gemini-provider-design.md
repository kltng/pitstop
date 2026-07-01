# Gemini Provider (Gemini CLI + Antigravity) — Design

**Date:** 2026-07-01
**Status:** Approved design, ready for implementation planning
**Component:** PitStop (macOS menu-bar app, Swift/AppKit)

## Problem

PitStop tracks usage and switches accounts for Claude Code, Claude Desktop, and
OpenAI Codex. The user also runs Google's **Gemini CLI**, **Antigravity CLI**,
and the **Antigravity IDE** — all authenticated to one Google account against
the Gemini **Code Assist** backend. Add a **Gemini provider** so PitStop shows
that account's live usage and can switch it, exactly the way it does for Codex.

## Goals

- A merged **"Gemini"** section/row per Google account showing live usage
  (per-model quota) with a plan chip and surface tag.
- **Switch** the Gemini account (both CLI and Antigravity surfaces together).
- **Auto-switch** participation (same opt-in loop as Claude/Codex).
- In-app **Login** (re-login) for a rejected surface, reusing the existing
  `OAuthLoginCoordinator` + `LoopbackServer`.

## Non-Goals

- The **Gemini desktop app** (`com.google.GeminiMacOS`) — no known pollable
  usage endpoint; skip it (like it's not worth an observe-only row).
- Antigravity's separate "compute-credit" model (the `fetchAvailableModels`
  quotaInfo). v1 uses the account-level `retrieveUserQuota` request quotas,
  which both surfaces share.
- Changing the default menu-bar metric away from Claude.

## Requirements (decisions made during brainstorming)

1. **One merged "Gemini" row per Google account.** Surfaces merge by email
   (like Claude Code · Desktop). Different emails on CLI vs Antigravity → two
   rows.
2. **Switch both surfaces together** — swap the CLI file store *and* the
   Antigravity keychain blob to the target account.
3. **Usage layout:** binding model (highest used%) as the row's main bar +
   the menu-bar %, plus a compact extras line of the next 1–2 most-used models.
4. **Include re-login** (Login pill) and **auto-switch** in v1.
5. **Re-login shape:** re-authenticate only the surface(s) in a rejected state;
   one Google sign-in per broken surface (normally just one).

## Verified facts (on-device probe, 2026-07-01)

Grounding for the implementation (confirmed by refreshing the local token
in-memory and calling the live endpoints):

- **CLI store:** `~/.gemini/oauth_creds.json` (mode 600), JSON
  `{access_token, refresh_token, id_token, scope, token_type:"Bearer", expiry_date(ms)}`.
  Active email in `~/.gemini/google_accounts.json` `{"active":"<email>","old":[]}`.
- **Antigravity store:** macOS keychain generic-password `svce=gemini, acct=antigravity`,
  value = `"go-keyring-base64:" + base64(JSON)`, JSON =
  `{"token":{access_token, token_type:"Bearer", refresh_token, expiry(ISO8601)}, "auth_method":"consumer"}`.
- **OAuth clients** (public installed-app credentials):
  - CLI: `681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com` / `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`
  - Antigravity: `1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com` / `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` (**[verify]** reverse-engineered; the probe confirmed it refreshes)
  - Token endpoint: `https://oauth2.googleapis.com/token` (form-urlencoded refresh_token grant).
- **Usage endpoints** (both surfaces, prod host):
  - `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
    body `{"metadata":{"ideType":"IDE_UNSPECIFIED","platform":"DARWIN_ARM64","pluginType":"GEMINI"}}`
    → `{currentTier{id,name}, paidTier{name}, cloudaicompanionProject:"<id>"}`.
  - `POST …:retrieveUserQuota` body `{"project":"<cloudaicompanionProject>"}`
    → `{buckets:[{remainingFraction, resetTime(RFC3339), tokenType:"REQUESTS", modelId}]}`.
    Header: `Authorization: Bearer <access_token>` + `Content-Type: application/json`.
  - Both surfaces resolved the **same** `cloudaicompanionProject` and identical
    buckets → one shared account-level usage signal.
- Google refresh tokens are long-lived and reusable, so an in-memory refresh for
  polling does not invalidate the stored token.

## Architecture

Mirrors the Codex provider; reuses the re-login infrastructure.

**New files:**
- `Sources/PitStop/Gemini.swift` — the provider's network + parsing layer:
  credential parsing for both blob formats, Google token refresh (per client),
  `loadCodeAssist` + `retrieveUserQuota`, `Usage` mapping, model-name shortening.
- `Sources/PitStop/GeminiStore.swift` — the two live stores, per-account
  snapshots, capture-current, switch-both. Analogous to `CodexStore`.
- `Sources/PitStop/GeminiLoginAdapter.swift` — CLI + Antigravity login adapters
  conforming to the existing `LoginAdapter`.

**Modified:**
- `AppDelegate.swift` — `refreshGeminiAccount`, Gemini row model, switch,
  auto-switch wiring, menu-bar `mostUrgent` pool, Login-pill routing.
- `AppDelegate.swift` `Provider` and `MenuAccount` — add `.gemini` + sources.
- `Package.swift` / `Tests/PitStopTests/` — new tests.

## Data model (`Provider` / `MenuAccount`)

- `Provider` gains `.gemini` → title `"Gemini"`.
- `MenuAccount.Source` gains `.geminiCli`, `.geminiAntigravity`, `.geminiBoth`.
  - `provider` → `.gemini` for all three.
  - `canSwitch` → true for all three.
  - `surfaceTag` → `"CLI"`, `"Antigravity"`, `"CLI · Antigravity"`.
  - `key` → `"gemini:<email>"`.
- Surfaces merge by email in `accountsForMenu()`: same email present on both live
  stores (or snapshots) → one `.geminiBoth` row; only one surface → `.geminiCli`
  or `.geminiAntigravity`; different emails → separate rows.
- **Active marker:** a Gemini row `isActive` if its email equals the CLI live
  email or the Antigravity live email. Normally both match → one active row.
  If they diverge (rare), each live account is its own active row (documented
  edge case; switching re-converges them).

## Usage (`Gemini` module)

Per merged account, once per refresh:
1. Pick a credential to poll with — prefer the CLI blob (has refresh_token +
   known client); else the Antigravity blob. Refresh the access token in memory
   with the matching client if `expiry_date`/`expiry` is past.
2. `loadCodeAssist` → cache `cloudaicompanionProject` per account (in-memory);
   derive the **plan chip** from `paidTier.name` ("Google One AI Pro" → "AI Pro")
   or `currentTier.name` ("Gemini Code Assist" → "Code Assist").
3. `retrieveUserQuota {project}` → `buckets`.
4. Map each bucket → a generic usage window:
   `label` = shortened `modelId` (`gemini-3.1-pro-preview` → `3.1-pro`;
   drop the `gemini-` prefix and a trailing `-preview`),
   `utilization = (1 − remainingFraction) × 100`, `resetsAt = resetTime`.
5. **Binding** = the bucket with the highest utilization → the row's main bar and
   the menu-bar %. **Extras line** = the next up-to-2 most-used models
   (`3-pro 22% · 2.5-flash 5%`), omitting 0% models.
6. If `loadCodeAssist` returns no `cloudaicompanionProject`, or `buckets` is empty
   → identity/presence row, no bar (status: neutral).

Errors reuse `UsageAPI.APIError`: 401/403 → `.unauthorized` (needsAction →
Login pill on the broken surface), 429 → `.rateLimited` (backoff). This plugs
into the existing status-line, backoff, and `needsAction` machinery unchanged.

## Switching (`GeminiStore`)

- **Per-account snapshot** (on every refresh, like `CodexStore.captureCurrent`):
  - Snapshot the live CLI blob → keychain `PitStop-gemini-cli` (acct=email),
    stored via `Keychain.upsert`. Skip write if byte-identical to the saved copy.
  - Snapshot the live Antigravity blob → keychain `PitStop-gemini-antigravity`
    (acct=email), preserving the exact `go-keyring-base64:` string opaquely.
  - Persist non-secret metadata (email, planLabel, surfaces present, savedAt) to
    `~/.config/pitstop/gemini-profiles.json`.
- **Switch to email X** (`switchTo`): snapshot current first (never strand an
  outgoing refresh token), then for each surface PitStop has a snapshot of X:
  - CLI: write the blob to `~/.gemini/oauth_creds.json` (atomic, mode 600) and
    set `~/.gemini/google_accounts.json` `"active"` = X.
  - Antigravity: write the blob back to keychain `svce=gemini, acct=antigravity`
    (in-place `-U`, preserving the `go-keyring-base64:` prefix).
- **Blob to poll / restore** helpers mirror `CodexStore.blob(for:isActive:)`.
- **Notification** after switch: "Switched Gemini to <email> — quit & reopen
  Gemini CLI / Antigravity to pick it up." (Running apps hold the token in
  memory and rewrite on refresh, so a hot swap only affects a fresh process.)

## Auto-switch + menu bar

- Gemini joins `evaluateAutoSwitch` as a third provider (same threshold +
  cooldown; only when the user enables auto-switch in Settings, off by default).
  `performGeminiSwitch` swaps both surfaces.
- Gemini usage joins the `mostUrgent` menu-bar pool (`menuBarReading`). The
  default `activeClaudeCode` source is unchanged (stays Claude-only).

## Re-login (Login pill)

Reuses `OAuthLoginCoordinator` + `LoopbackServer`. Google installed-app clients
accept an arbitrary loopback port, so re-login is fully automatic (no paste
fallback). Two adapters conforming to `LoginAdapter`:
- `GeminiCliLoginAdapter` — client `681255809395-…`; scopes
  `cloud-platform userinfo.email userinfo.profile`; authorize
  `https://accounts.google.com/o/oauth2/v2/auth`; loopback redirect
  `http://127.0.0.1:<port>/oauth2callback`; token exchange (form-urlencoded)
  `https://oauth2.googleapis.com/token`; PKCE S256; identity from the id_token
  JWT (`email`); persist to `PitStop-gemini-cli` + write the CLI live store.
- `GeminiAntigravityLoginAdapter` — client `1071006060591-…`; adds scopes
  `cclog experimentsandconfigs`; persist to `PitStop-gemini-antigravity` + the
  keychain live store (re-wrap as `go-keyring-base64:`).

**Which adapter runs:** PitStop polls the account with one surface's credential
(CLI if present, else Antigravity), so it knows *that* surface's health. The
Login pill re-auths the polled (rejected) surface — normally one Google sign-in.
A rarely-broken second surface heals on a later Login once it becomes the polled
surface (Google tokens seldom die, so this is an edge case, not the common path).
`LoginError` handling (identity mismatch, cancel) is inherited from the
coordinator. Deliberately NOT built: simultaneous dual-surface re-auth — it
would need a second sign-in and isn't worth the complexity for a rare case.

Note: unlike Claude/Codex, Google refresh tokens rarely die, so the Login pill
is a safety net rather than a common path.

## Errors, edge cases

- **Diverged surfaces** (CLI on email A, Antigravity on email B): merge-by-email
  yields two rows; each active for its surface; switching re-converges.
- **Surface present but never snapshotted:** shown, but not switchable-to until
  captured once while live.
- **Expired token:** in-memory refresh to poll; persist rotated tokens only for
  inactive accounts (Codex model) — never rewrite the live store just to poll.
- **`FORCE_ENCRYPTED_FILE` env set** (not set here): `oauth_creds.json` isn't the
  source of truth; detect (creds file absent/stale) and show a neutral note
  rather than mis-swap.
- **`go-keyring-base64:` round-trip:** treat the whole keychain value opaquely
  for snapshot/restore; only decode when reading tokens to poll/refresh.
- **Antigravity ToS:** rotation reportedly discouraged; surface the caveat in the
  switch notification and README (same risk class PitStop already carries).

## Testing (TDD)

Pure units (no network):
- CLI blob parse + Antigravity `go-keyring-base64` decode/encode round-trip.
- Model-name shortening (`gemini-3.1-pro-preview` → `3.1-pro`, etc.).
- `retrieveUserQuota` response parse → windows; binding selection; extras line
  (top-2 non-zero); empty/partial `buckets` → no bar.
- `loadCodeAssist` parse → project id + plan-chip derivation.
- Switch blob-building for both stores (patch/round-trip; Antigravity prefix
  preserved; CLI stays valid JSON mode-600 content).
- Google token-refresh request builder (form body, client per surface) and the
  re-login authorize-URL builders (params, scopes, loopback redirect, PKCE).
- Identity match from id_token JWT.

Manual E2E (documented in the plan): the live `loadCodeAssist` /
`retrieveUserQuota` / refresh / switch round-trips (already proven on-device);
confirm switching both surfaces and that the live stores of the *other* account
are restored correctly.

## Global constraints

- macOS 26+, `swift-tools-version: 6.0`, `swiftLanguageMode(.v5)`, no new
  third-party dependencies (Foundation / AppKit / Darwin / CommonCrypto).
- Reuse existing infra: `Keychain`, `LoopbackServer`, `OAuthLoginCoordinator`,
  `LoginAdapter`, `AccountRowView`, the generic usage-window rendering, and the
  Codex store/usage patterns.
- Usage host `cloudcode-pa.googleapis.com/v1internal`; token host
  `oauth2.googleapis.com/token`. `[verify]` the Antigravity client_secret and
  the shipping host (prod vs daily) at build time (both confirmed working in the
  probe).
- Snapshot-before-swap; never strand an outgoing refresh token; profile-slot
  writes via `Keychain.upsert`.

## Risks / to-verify during implementation

1. **[Antigravity client]** reverse-engineered client_id/secret — probe-confirmed
   it refreshes; re-confirm during the build and handle refresh failure gracefully
   (fall back to observe/identity for that surface).
2. **Quota shape variance** — every `retrieveUserQuota` field is optional; handle
   partial/empty responses (missing `remainingFraction` → skip that bucket).
3. **`cloudaicompanionProject` resolution** — required for `retrieveUserQuota`;
   if `loadCodeAssist` returns none, degrade to presence-only.
4. **Diverged-surface UX** — confirm the two-active-rows edge case reads sensibly.
5. **ToS rotation** — surface the Antigravity caveat; keep auto-switch opt-in.
