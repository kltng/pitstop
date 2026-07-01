# Changelog

All notable changes to PitStop are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); release notes also
appear on [GitHub Releases](https://github.com/Livin21/pitstop/releases).

## [Unreleased]

## [0.3.1] - 2026-07-01
### Added
- External-link icon (↗) on each provider section header (Claude, Codex, Gemini)
  that opens the provider's usage dashboard in the browser.

## [0.3.0] - 2026-07-01
### Added
- **In-app re-login.** Expired accounts show a coral **Login** button that
  re-authenticates in the browser without disturbing a running Claude Code /
  Codex session — fresh credentials are written only to the saved profile, never
  the live account. Claude uses an automatic localhost callback with a
  code-paste fallback; Codex is fully automatic.
- **Google Gemini provider (Gemini CLI + Antigravity).** One "Gemini" row per
  Google account (tagged `CLI · Antigravity`) with live per-model Code Assist
  usage and reset times, one-click switching of both surfaces together,
  auto-switch, and in-app re-login.

## [0.2.1] - 2026-06-17
### Changed
- Per-window usage projection now uses a robust least-squares slope instead of a
  blended max, so the "on pace to hit limit" estimate is steadier.

## [0.2.0] - 2026-06-17
First versioned release.
### Added
- Multi-provider menu grouped by provider: **Claude Code**, **Claude Desktop**
  (observe-only), and **OpenAI Codex**.
- One-click **account switching** and opt-in **auto-switch** when the live
  account crosses a threshold.
- Usage projection ("on pace to hit limit …") and a **Settings** window.
- In-app versioning and a daily GitHub-release update check with one-click
  rebuild-from-source ("Update & Relaunch").
### Fixed
- Fall back to Desktop usage when a merged account's Claude Code fetch fails.

[Unreleased]: https://github.com/Livin21/pitstop/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/Livin21/pitstop/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/Livin21/pitstop/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/Livin21/pitstop/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/Livin21/pitstop/releases/tag/v0.2.0
