# Security Policy

PitStop reads and moves the credentials your Claude Code, Claude Desktop, and
OpenAI Codex logins use, so its security genuinely matters. Reports about
anything that could expose or misuse those credentials are very welcome.

## Reporting a vulnerability

**Please report privately — do not open a public issue.**

Use GitHub's [private vulnerability reporting][report] (the repository's
**Security** tab → **Report a vulnerability**). That opens a confidential
thread with the maintainer. This is a hobby-maintained project, so please
allow a few days for a first response.

[report]: https://github.com/Livin21/pitstop/security/advisories/new

Helpful to include:

- macOS version and the PitStop commit you're on.
- What's exposed — which credential, keychain item, or file — and how.
- Steps to reproduce.

## What PitStop touches (its threat surface)

By design, PitStop:

- reads the Claude Code OAuth credential and `~/.codex/auth.json`, decrypts
  Claude Desktop's `sessionKey` cookie, and stores per-account snapshots in
  the macOS keychain (services `PitStop-profile` and `PitStop-codex`);
- writes the live credential back into place when you switch accounts;
- calls the same unofficial Anthropic / ChatGPT OAuth and usage endpoints the
  official apps use.

Known, **accepted** trade-offs (documented in the README):

- keychain writes pass the secret blob via `argv` to `/usr/bin/security`, so
  it's briefly visible in the process list — the same exposure Claude Code has;
- it relies on unofficial endpoints that can change without notice.

A report that PitStop *uses* these mechanisms isn't a vulnerability. A report
that it **leaks a secret somewhere it shouldn't** — a log, a file on disk, the
network, or the wrong account — is.

## Scope

**In scope:** credential exposure, writing a secret to the wrong place,
switching to the wrong account, keychain ACL mistakes, or sending data anywhere
other than the documented endpoints.

**Out of scope:** the inherent `argv` / unofficial-endpoint trade-offs above,
bugs in Claude Code / Codex / macOS themselves, and anything that requires a
local attacker who already controls your user session.
