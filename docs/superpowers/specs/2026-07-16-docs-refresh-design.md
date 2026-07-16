# Docs Refresh — Design

**Date:** 2026-07-16
**Status:** Approved

## Problem

Three releases of features shipped with only one-line doc touches. The README
omits Gemini everywhere except the auto-switch bullet, `docs/menu.png` predates
the Gemini section and Fable bars (captured 2026-06-13), CONTRIBUTING claims
"there are no automated tests" (116 exist), SECURITY.md's threat surface omits
Gemini's credentials and the new on-disk usage cache, and the internal verify
skill lacks the two E2E recipes this cycle proved out.

## Decisions (user-approved)

Scope: all four areas — README full pass, fresh menu.png, CONTRIBUTING +
SECURITY, and the internal verify skill. Executed via the full
spec → plan → subagent pipeline.

## Accuracy sources (binding)

Every factual claim in the new prose must match these, not memory:

- Gemini CLI creds: `~/.gemini/oauth_creds.json` (plain file), active email
  from `~/.gemini/google_accounts.json` (GeminiStore.swift:32).
- Antigravity creds: keychain item service `gemini`, account `antigravity`,
  value `go-keyring-base64:` + base64(JSON) (GeminiStore.swift:33-41,
  Gemini.swift:31-33).
- PitStop snapshots: keychain services `PitStop-gemini-cli` /
  `PitStop-gemini-antigravity`, account = email (GeminiStore.swift:3-4).
- Usage/plan: Code Assist backend `cloudcode-pa.googleapis.com/v1internal` —
  `retrieveUserQuota` (per-model daily windows), `loadCodeAssist` (project +
  plan label) (Gemini.swift:244, 181, 208).
- Both surfaces authenticate one Google account → merged single row tagged
  by surface; per-model daily quota bars (Gemini provider spec 2026-07-01).
- Binding metric now includes per-model scoped limits (UsageAPI.swift
  `bindingWindow`).
- Display state persists to `~/.config/pitstop/usage-cache.json` (usage bars,
  fetch errors, backoffs, Desktop identity; non-secret) and restores on
  launch; restored bars age out after 24 h (UsageCache.swift).
- Session warming: opt-in, default window 6 AM–6 PM, 1-token request per
  account per session via each saved account's own OAuth token
  (SessionWarmer.swift).
- Tests: 116 XCTest tests, file-per-topic under `Tests/PitStopTests`,
  run with `swift test`.

## Requirements per file

### README.md

1. Intro sentence and provider-section paragraph name **Gemini** alongside
   Claude Code, Claude Desktop, and Codex (CLI + Antigravity phrasing).
2. "What shows up where" gains a Gemini bullet: switchable; CLI and
   Antigravity share one Google login → one merged row tagged **CLI**,
   **Antigravity**, or **CLI · Antigravity**; per-model daily quota bars.
3. Quickstart agent prompt: intro line names Gemini; step 6 extends to
   Gemini (auto-detected, switchable, no keychain grant needed for CLI
   creds — they're a plain file; Antigravity's keychain item rides the same
   `security` grant model).
4. "How it works": new **Google Gemini** bullet modeled on the Codex bullet
   (identity + creds sources, snapshot services, Code Assist usage endpoint,
   switch = write snapshot back to CLI file / Antigravity keychain item,
   unofficial endpoints → update `Gemini.swift`). Menu-bar bullet's binding
   formula becomes max(5-hour, weekly, per-model) and mentions scoped bars
   rendering like the others. Usage bullet adds cross-relaunch persistence
   via `usage-cache.json`. Settings bullet adds auto-switch trigger
   checkboxes and session warming.
5. "Adding a second account": Gemini seeding step (sign into the other
   account in the `gemini` CLI or Antigravity while PitStop runs).
6. "What switching means": Gemini item (new sessions immediately; running
   surfaces re-read creds per their own cadence; Antigravity may need a
   restart to notice — mirror the Codex app caveat's tone).
7. Caveats: Gemini caveat (unofficial Code Assist endpoints; CLI creds are
   a plain file — no prompt; Antigravity/`gemini` keychain item is one more
   one-time grant).
8. menu.png alt text mentions Claude, Codex, and Gemini sections.

### docs/menu.png

Re-captured via the documented `--screenshot` flow (masked sample emails):
quit installed app → run bare binary with `--screenshot` → open the menu →
capture the menu window → crop → replace `docs/menu.png`. The user eyeballs
the image at handoff (it ships with the branch; recapture is cheap if it
disappoints).

### CONTRIBUTING.md

1. Replace the "There are no automated tests" paragraph: `swift test` runs
   the XCTest suite (file-per-topic under `Tests/PitStopTests`); logic
   changes should come with tests; UI/data-layer changes still verified by
   building, `--check`, and exercising the menu.
2. "Adding a provider" mentions `Gemini.swift`/`GeminiStore.swift` as a
   second template alongside Codex (a two-surface provider example).

### SECURITY.md

1. Intro credential list includes Gemini.
2. Threat surface gains: Gemini credential snapshots
   (`PitStop-gemini-cli` / `PitStop-gemini-antigravity` keychain services,
   plus reads of `~/.gemini/oauth_creds.json` and the `gemini`/`antigravity`
   keychain item), and `~/.config/pitstop/usage-cache.json` (non-secret:
   usage percentages, reset times, account emails — no tokens).

### .claude/skills/verify/SKILL.md

1. Note that automated tests exist (`swift test`).
2. Add the usage-cache simulation recipe: quit app → edit
   `~/.config/pitstop/usage-cache.json` (inject `fetchError` /
   `nextFetchAllowed` / aged `fetchedAt`) → relaunch → rows show stale bars
   with the rate-limited treatment; cleanup = Refresh Now.
3. Add session-warming E2E notes: enable the toggle with the window covering
   now; an account whose 5-hour window has lapsed warms on the next cycle
   (reset jumps to ≈now+5h); running sessions are skipped; restore the
   toggle afterwards.

## Out of scope

- social-preview.png regeneration (not user-visible in the repo UI).
- New screenshots beyond menu.png (no settings-window shot — not there today).
- Any code changes.

## Testing / verification

- `swift test` still green (docs-only, sanity).
- Markdown renders cleanly (no broken lists/links) — reviewer checks.
- Every Gemini/warming/cache claim traced to the accuracy sources above —
  reviewer checks claims against the cited files.
- menu.png: user visually approves the new capture at handoff.
