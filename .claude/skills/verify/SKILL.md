---
name: verify
description: How to build, run, and E2E-verify PitStop changes — headless --check mode, menu-bar app driving, and the poisoned-profile simulation recipe.
---

# Verifying PitStop changes

## Build & run

- `swift build -c release` → binary at `.build/release/PitStop`.
- `.build/release/PitStop --check` — headless diagnostic: runs
  `captureCurrent()` + per-profile usage fetches and prints to stdout.
  Exits before the single-instance lock, so it can run while the
  installed app is running. Exercises ProfileStore + UsageAPI end-to-end
  against the real keychain/`~/.claude.json`/API.
- The full GUI (refresh loop, audit, menu) only runs as the menu bar app.
  The installed `/Applications/PitStop.app` must be quit first (flock in
  `~/.config/pitstop/pitstop.lock`); `osascript -e 'quit app "PitStop"'`
  quits the installed app but NOT a bare `.build/release/PitStop` process —
  use `kill <pid>` for that. Relaunch the installed app when done.
- First refresh cycle runs on launch; ~30s is enough to observe its effects.

## Poisoned-profile simulation (identity audit / duplicate-usage bug)

Replicates the "two accounts show the same usage" corruption safely:

1. Back up `~/.config/pitstop/profiles.json`.
2. Copy a real profile's blob:
   `security find-generic-password -s "PitStop-profile" -a <real-email> -w`
3. File it under a fake email:
   `security add-generic-password -s "PitStop-profile" -a poisoned-test@example.com -w "<blob>"`
   and append a matching row to profiles.json (copy the real row, change
   `email` + `oauthAccount.emailAddress`).
4. Quit installed app, launch dev binary, wait one cycle.
5. Expect: fake keychain item deleted by the audit (`security find… -a
   poisoned-test@example.com` exits 44), row gated in the menu with
   "Was showing <owner>'s usage — sign in again" + Login badge.
6. Cleanup: restore profiles.json, delete any leftover fake items (incl.
   `#staging` sibling), kill dev instance, `open -a /Applications/PitStop.app`.

## Gotchas

- Never modify the live item (`Claude Code-credentials`) or real profiles'
  blobs; verify it stayed untouched via its `mdat` attribute
  (`security find-generic-password -s "Claude Code-credentials" | grep mdat`).
- Burst-testing (repeated launches + `--check`) trips Anthropic's rate
  limiter (429) on the usage endpoint for a few minutes; rows show
  "Rate limited" with backoff. Environmental, clears on its own.
- Don't drive a live account *switch* during tests — it flips the user's
  active Claude Code account mid-session.
