# Docs Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring README, CONTRIBUTING, SECURITY, the verify skill, and the README screenshot current with the last three releases (Gemini provider, auto-switch triggers, session warming, usage-cache persistence, test suite).

**Architecture:** Prose-only edits with exact old→new text per file, plus one screenshot recapture. Every factual claim traces to the spec's accuracy sources; implementers verify claims against the named source files and correct the prose (reporting the deviation) if a claim doesn't hold.

**Tech Stack:** Markdown; `--screenshot` capture flow (Task 5 is controller-executed — it drives the GUI).

**Spec:** `docs/superpowers/specs/2026-07-16-docs-refresh-design.md`

## Global Constraints

- Accuracy sources are binding (spec section "Accuracy sources"): Gemini CLI creds `~/.gemini/oauth_creds.json` + active email in `google_accounts.json`; Antigravity creds = keychain item `gemini`/`antigravity` (`go-keyring-base64:` blob); snapshots in services `PitStop-gemini-cli` / `PitStop-gemini-antigravity`; usage/plan from `cloudcode-pa.googleapis.com/v1internal` (`retrieveUserQuota` / `loadCodeAssist`); binding = max(5-hour, weekly, per-model); display cache `~/.config/pitstop/usage-cache.json` (non-secret); warming opt-in, 6 AM–6 PM default, ~1-token request; 116 tests via `swift test`.
- If an implementer finds a prose claim contradicted by the source files, they FIX the prose to match the code and report the deviation — the code is the truth, this plan's text is the draft.
- Wrap markdown at the file's existing width (~75-78 chars); match each file's list/emphasis style.
- No code changes anywhere.
- Verification per task: `swift test` still green (sanity) + re-read the edited section in full rendering order.
- Commit after every task; do NOT push.

---

### Task 1: README Gemini + features pass

**Files:**
- Modify: `README.md` (12 edits, exact text below)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing later tasks rely on.

- [ ] **Step 1: Intro sentence (lines 7-10)** — replace:

```markdown
macOS menu bar app that tracks **usage limits** across your AI coding accounts
— **Claude Code**, **Claude Desktop**, and **OpenAI Codex** — and lets you
**switch accounts** with one click, so when one hits its rate limit you flip to
another and your work keeps going.
```

with:

```markdown
macOS menu bar app that tracks **usage limits** across your AI coding accounts
— **Claude Code**, **Claude Desktop**, **OpenAI Codex**, and **Google Gemini**
(CLI + Antigravity) — and lets you **switch accounts** with one click, so when
one hits its rate limit you flip to another and your work keeps going.
```

- [ ] **Step 2: menu.png alt text (line 13)** — replace `alt="PitStop menu grouped into Claude and Codex sections, each with color-coded usage bars"` with `alt="PitStop menu grouped into Claude, Codex, and Gemini sections, each with color-coded usage bars"`.

- [ ] **Step 3: Provider paragraph (line 16-17)** — replace `a section per provider — **Claude**, **Codex**, and
whatever comes next.` with `a section per provider — **Claude**, **Codex**, and
**Gemini**.`

- [ ] **Step 4: "What shows up where" Gemini bullet** — after the OpenAI Codex bullet (ends "…just like Claude's 5-hour and weekly limits."), add:

```markdown
- **Google Gemini** accounts are switchable as well. The `gemini` CLI and the
  Antigravity editor authenticate the same Google account, so they merge into
  one row — tagged **CLI**, **Antigravity**, or **CLI · Antigravity** — with a
  bar for the most-used model's daily quota and a compact line for the
  runners-up.
```

Verify the bar/extras claim against `AppDelegate.swift` `rowModel` (Gemini branch renders the binding window as the row's one bar; `Gemini.extrasLine` lists up to two more).

- [ ] **Step 5: Quickstart prompt** — in the agent prompt code block: replace `switches accounts across Claude
Code, Claude Desktop, and OpenAI Codex, on this Mac.` with `switches accounts across Claude
Code, Claude Desktop, OpenAI Codex, and Google Gemini, on this Mac.` Then replace step 6:

```text
6. If I also use OpenAI Codex or the Claude Desktop app, tell me they're
   detected automatically and show up in their own menu sections — Codex
   accounts are switchable like Claude Code (it reads ~/.codex/auth.json,
   no keychain grant), Claude Desktop is read-only.
```

with:

```text
6. If I also use OpenAI Codex, Google Gemini (CLI or Antigravity), or the
   Claude Desktop app, tell me they're detected automatically and show up
   in their own menu sections — Codex and Gemini accounts are switchable
   like Claude Code (Codex reads ~/.codex/auth.json with no prompt; Gemini
   reads ~/.gemini files, and Antigravity's keychain item is one more
   one-time Always Allow grant), Claude Desktop is read-only.
```

- [ ] **Step 6: Usage bullet persistence** — in "How it works", the first bullet currently ends `the last good numbers
  stay visible (rows note "showing … data"; the menu bar dims) during
  outages.` Replace that ending with:

```markdown
  the last good numbers
  stay visible (rows note "showing … data"; the menu bar dims) during
  outages — and across relaunches: display state (bars, errors, retry
  backoffs) persists to `~/.config/pitstop/usage-cache.json`, so a launch
  that lands mid-rate-limit shows your last-known numbers instead of a
  blank menu.
```

- [ ] **Step 7: Menu-bar binding formula** — in the menu-bar bullet, replace `binding constraint — `max(5-hour, weekly)` utilization` with `binding constraint — `max(5-hour, weekly, per-model)` utilization (per-model weekly limits like Fable render as their own labelled bars)`.

- [ ] **Step 8: Settings bullet** — replace `— 
  the menu-bar options above, auto-switch, the projection toggle, and launch
  at login.` (checking the actual line breaks in the file) with `—
  the menu-bar options above, auto-switch and its per-limit trigger
  checkboxes, session warming and its hours, the projection toggle, and
  launch at login.`

- [ ] **Step 9: "How it works" Gemini bullet** — insert after the OpenAI Codex bullet (the long one ending "…stay distinct rows."):

```markdown
- **Google Gemini** covers two surfaces with one Google login: the `gemini`
  CLI keeps its OAuth credential in `~/.gemini/oauth_creds.json` (active
  account in `google_accounts.json`), Antigravity keeps a go-keyring blob in
  the keychain (item `gemini`/`antigravity`). Identity and plan come from
  Google's Code Assist backend (`cloudcode-pa.googleapis.com` —
  `loadCodeAssist`); usage comes from `retrieveUserQuota`, each model's
  remaining daily quota. Switching mirrors the other providers: snapshots
  live in the keychain (services `PitStop-gemini-cli` /
  `PitStop-gemini-antigravity`, one item per email), and a switch writes the
  chosen account's blobs back into the CLI files and/or the Antigravity
  keychain item — whichever surfaces that account was saved from. Inactive
  snapshots are kept fresh via Google's OAuth refresh grant, like Codex's.
```

Verify the refresh-grant claim against `GeminiStore.swift` / `Gemini.swift` (a refresh path for saved snapshots exists); if it does not hold, drop that final sentence and report the deviation.

- [ ] **Step 10: Adding a second account** — replace `2. Sign in with the **other** account — Claude Code: run `/login`; Codex: run
   `codex` and sign in (the CLI and the Codex app share this login).` with:

```markdown
2. Sign in with the **other** account — Claude Code: run `/login`; Codex: run
   `codex` and sign in (the CLI and the Codex app share this login); Gemini:
   sign in from the `gemini` CLI or Antigravity (both share the Google login).
```

- [ ] **Step 11: "What switching means" Gemini item** — after the Codex-app bullet (ends "…switch Codex with
  the app closed for a clean result).`), add:

```markdown
- **Gemini** surfaces re-read their credential stores on their own cadence —
  new CLI sessions pick the swap up immediately; a running Antigravity may
  need a restart to notice.
```

- [ ] **Step 12: Caveats Gemini bullet** — after the Codex caveat (ends "…Not installed or not
  signed in → nothing changes."), add:

```markdown
- **Gemini** reads the CLI's plain credential files (no prompt) and
  Antigravity's `gemini` keychain item — one more one-time **Always Allow**
  grant, same as the others. It talks to Google's unofficial Code Assist
  endpoints; if those change, update `Gemini.swift`. Not installed or not
  signed in → nothing changes.
```

- [ ] **Step 13: Verify and commit**

Re-read the full README top to bottom for flow and broken markdown. Run: `swift test` (sanity — expect 116 passing).

```bash
git add README.md
git commit -m "README: document Gemini, session warming, usage cache, per-model binding"
```

---

### Task 2: CONTRIBUTING tests + provider template

**Files:**
- Modify: `CONTRIBUTING.md:30-32` and `:45-51`

**Interfaces:** none.

- [ ] **Step 1: Replace the no-tests paragraph** — replace:

```markdown
There are no automated tests; verify changes by building, running `--check`,
and exercising the menu. (An ad-hoc-signed rebuild keeps its keychain grant,
since access rides the Apple-signed `/usr/bin/security`.)
```

with:

```markdown
Run the test suite with `swift test` — XCTest, one file per topic under
`Tests/PitStopTests/`. Logic changes should come with tests (parsing,
filtering, and decision layers are covered that way); UI and data-layer
changes are still verified by building, running `--check`, and exercising
the menu. (An ad-hoc-signed rebuild keeps its keychain grant, since access
rides the Apple-signed `/usr/bin/security`.)
```

- [ ] **Step 2: Second provider template** — in "Adding a provider", replace `` `Codex.swift` and `CodexStore.swift` are the
template to copy.`` with `` `Codex.swift` and `CodexStore.swift` are the
template to copy; `Gemini.swift` / `GeminiStore.swift` show the same pattern
stretched over a two-surface provider (CLI + Antigravity).``

- [ ] **Step 3: Verify and commit**

Run: `swift test` — 116 passing (and the claim in step 1 is thereby self-verified).

```bash
git add CONTRIBUTING.md
git commit -m "CONTRIBUTING: tests exist now; Gemini as second provider template"
```

---

### Task 3: SECURITY threat surface

**Files:**
- Modify: `SECURITY.md:3-4` and `:26-33`

**Interfaces:** none.

- [ ] **Step 1: Intro credential list** — replace `PitStop reads and moves the credentials your Claude Code, Claude Desktop, and
OpenAI Codex logins use` with `PitStop reads and moves the credentials your Claude Code, Claude Desktop,
OpenAI Codex, and Google Gemini logins use`.

- [ ] **Step 2: Threat-surface read/store bullet** — replace:

```markdown
- reads the Claude Code OAuth credential and `~/.codex/auth.json`, decrypts
  Claude Desktop's `sessionKey` cookie, and stores per-account snapshots in
  the macOS keychain (services `PitStop-profile` and `PitStop-codex`);
```

with:

```markdown
- reads the Claude Code OAuth credential, `~/.codex/auth.json`, the Gemini
  CLI's `~/.gemini/oauth_creds.json`, and Antigravity's `gemini` keychain
  item, decrypts Claude Desktop's `sessionKey` cookie, and stores
  per-account snapshots in the macOS keychain (services `PitStop-profile`,
  `PitStop-codex`, `PitStop-gemini-cli`, and `PitStop-gemini-antigravity`);
```

- [ ] **Step 3: Endpoints bullet + cache bullet** — replace `- calls the same unofficial Anthropic / ChatGPT OAuth and usage endpoints the
  official apps use.` with:

```markdown
- calls the same unofficial Anthropic / ChatGPT / Google Code Assist OAuth
  and usage endpoints the official apps use;
- keeps a non-secret display cache at `~/.config/pitstop/usage-cache.json`
  (usage percentages, reset times, account emails — never tokens), so the
  menu isn't blank after a rate-limited relaunch.
```

- [ ] **Step 4: Verify and commit**

Re-read SECURITY.md fully (list punctuation now: `;` `;` `.` across the three bullets — adjust the semicolon/period endings so the list reads correctly).

```bash
git add SECURITY.md
git commit -m "SECURITY: add Gemini credentials and usage cache to threat surface"
```

---

### Task 4: verify skill recipes

**Files:**
- Modify: `.claude/skills/verify/SKILL.md`

**Interfaces:** none.

- [ ] **Step 1: Tests line** — in the "Build & run" section, after the `swift build -c release` bullet, add:

```markdown
- `swift test` — the XCTest suite (one file per topic in Tests/PitStopTests);
  run it before any commit that touches logic.
```

- [ ] **Step 2: Usage-cache simulation section** — after the "Poisoned-profile simulation" section, add:

```markdown
## Usage-cache simulation (rate-limited-launch rendering)

Replicates "app relaunched during a 429" without touching the network:

1. Quit the installed app. `~/.config/pitstop/usage-cache.json` holds the
   display state (dates are seconds since 2001-01-01 — unix minus 978307200).
2. Edit it: set `fetchError["<email>"] = "Rate limited"`,
   `nextFetchAllowed["<email>"] = now + 600`, and age that account's
   `usage[<email>].fetchedAt` back ~15 min.
3. Relaunch. Expect: the row still shows its bars, plus
   "⚠ Rate limited — retrying in 9m · showing <time> data"; the account is
   NOT re-fetched until the backoff passes (persisted backoff honored).
4. Cleanup: Refresh Now (clears backoffs, refetches live data).
```

- [ ] **Step 3: Session-warming E2E section** — after the new usage-cache section, add:

```markdown
## Session warming E2E

- Warm request shape can be tested standalone: extract a saved account's
  access token from its `PitStop-profile` keychain blob and POST the
  1-token request from `SessionWarmer.warmRequest` — expect HTTP 200.
- Live check: enable "Keep Claude sessions started" with the window
  covering now. An account whose 5-hour window has lapsed warms on the next
  2-min cycle — its reset jumps to ≈ now + 5 h; accounts with running
  sessions are skipped. Restore the toggle afterwards (opt-in feature).
- Warms burn ~20 input + 1 output tokens on the target account.
```

- [ ] **Step 4: Commit**

```bash
git add .claude/skills/verify/SKILL.md
git commit -m "verify skill: tests line, usage-cache and session-warming recipes"
```

---

### Task 5: Recapture docs/menu.png (CONTROLLER-EXECUTED — drives the GUI)

**Files:**
- Modify: `docs/menu.png`

This task is executed by the controller inline (it juggles the installed app and the screenshot instance), not dispatched to a subagent.

- [ ] **Step 1: Build and launch the screenshot instance**

```bash
swift build -c release
osascript -e 'quit app "PitStop"'; sleep 1
.build/release/PitStop --screenshot &
sleep 25   # let the first refresh cycle populate real (masked) usage
```

- [ ] **Step 2: Open the menu and capture its window**

Open the status-item menu via System Events (`click menu bar item 1 of menu bar 1 of process "PitStop"`), then find the menu's window bounds via Quartz (`CGWindowListCopyWindowInfo`, owner "PitStop", the window with height > 300) and `screencapture -R<x>,<y>,<w>,<h> -x /tmp/menu-capture.png`. Close the menu (Escape key).

- [ ] **Step 3: Replace, restore, verify**

```bash
cp /tmp/menu-capture.png docs/menu.png
kill %1 2>/dev/null; pkill -f "PitStop --screenshot" 2>/dev/null
open -a /Applications/PitStop.app
```

View the new docs/menu.png: expect Claude, Codex, and Gemini sections, masked emails (asha@work.com etc.), Fable bar on Claude rows. Show it to the user at handoff.

- [ ] **Step 4: Commit**

```bash
git add docs/menu.png
git commit -m "Recapture docs/menu.png with Gemini section and per-model bars"
```
