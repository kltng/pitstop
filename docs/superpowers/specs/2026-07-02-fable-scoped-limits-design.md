# Scoped Weekly Limits (Fable) — Design

**Date:** 2026-07-02
**Status:** Approved

## Problem

Claude now tracks per-model weekly limits separately — the usage dashboard shows
"All models" plus a "Fable" weekly bar. The `api.anthropic.com/api/oauth/usage`
response (and the identical claude.ai org endpoint Desktop rows use) gained a
generic `limits` array; Fable arrives as:

```json
{ "kind": "weekly_scoped", "group": "weekly", "percent": 13,
  "resets_at": "2026-07-05T00:00:00Z",
  "scope": { "model": { "display_name": "Fable" } } }
```

There is **no** `seven_day_fable` top-level field. Meanwhile `seven_day_opus`
and `seven_day_sonnet` are now permanently `null` — PitStop's "Opus wk X% ·
Sonnet wk Y%" extras line is dead plumbing.

## Decisions (user-approved)

1. **Own bar row:** each scoped limit renders as its own labelled bar under the
   5h/7d bars (like the dashboard, and like Codex windows) — not an extras line.
2. **Counts fully toward binding:** `maxUtilization` includes scoped limits, so
   the menu bar %, most-urgent pick, auto-switch, and 80%/95% notifications all
   react when Fable runs hot.

## Data model

- New `struct ScopedWindow { let label: String; let window: UsageWindow }`.
- `UsageReport` gains `scoped: [ScopedWindow]`; `sevenDayOpus` /
  `sevenDaySonnet` and their extras-line rendering are **removed** (scoped
  limits are their replacement).
- `maxUtilization` = max(fiveHour, sevenDay, all scoped).
- `bindingWindow` returns whichever window holds that max (drives the reset
  stamp in threshold notifications).

## Parsing (`UsageAPI.parse`)

- 5h/7d keep coming from the legacy `five_hour`/`seven_day` fields (still
  served, more precision); if a legacy field is absent, fall back to the
  `limits` entry with `kind == "session"` / `"weekly_all"`.
- Scoped limits come only from `limits[]` entries with
  `kind == "weekly_scoped"`: label = `scope.model.display_name` (fallback
  `"Scoped"`), utilization = `percent`, reset = `resets_at`.
- Unknown `kind` values are ignored (future limit types must not break parsing).
- One parser serves both Claude Code and Claude Desktop rows
  (`ClaudeDesktop.poll` reuses `UsageAPI.parse`).

## Display

- Claude row bars: `[5h, 7d] + one bar per scoped limit`, labelled with the
  display name ("Fable"), same colors/reset stamp as other bars. Row height
  already adapts to bar count (Codex rows rely on the same mechanism).
- Extras line keeps only "Extra X%" (extra usage credits).
- Projections: scoped windows feed `projectableWindows` keyed by their label,
  so "↗ on pace to hit Fable limit ~4:10 PM" works; `windowName()` passes
  unknown labels through unchanged.

## Testing

New `UsageAPIParseTests`:
- scoped limit parsed from a real-shaped `limits` payload (label, percent, reset)
- label fallback when `display_name` is missing
- legacy 5h/7d fallback to `limits` session/weekly_all entries
- `maxUtilization`/`bindingWindow` include scoped windows
- unknown `kind` tolerated

`--preview` gains a sample row with a Fable bar for visual sanity.

## Out of scope

- `severity` field (colors already derive from percentage)
- A dedicated IndicatorMetric settings option for Fable ("Highest Limit"
  already covers it once binding includes scoped limits)
- `spend` / usage-credits parsing changes
