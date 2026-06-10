# Byte Pulse — Architecture

Native macOS 26 (Tahoe) menu bar app. Swift 6 / SPM, zero third-party
dependencies. Tracks AI usage for Claude, Codex, Cursor, and Gemini from the
user's own local CLI credentials and the providers' own endpoints — read-only,
nothing leaves the machine except calls to those APIs.

## Layers

```
App/        lifecycle, status item, floating panel, settings window (AppKit shell)
UI/         SwiftUI views: design system, cards, charts, tab bar (per docs/DESIGN.md)
Providers/  one engine per provider (actor), conforming to UsageProvider
Core/       models, contracts, shared services — no AppKit/SwiftUI above Foundation
```

Dependency direction: `App → UI → Core ← Providers`. Providers never import UI;
UI never talks to providers directly — everything flows through `UsageStore`.

## Data flow

```
RefreshScheduler (per-provider loop, jitter, backoff, wake/panel triggers)
    └─ UsageProvider.probeConnection() → fetch() → UsageSnapshot
           └─ UsageStore (@MainActor @Observable — UI's single source of truth)
           └─ HistoryStore (JSONL samples) → trends (vs 1h ago) + rate series
```

`UsageSnapshot` is capability-shaped: the UI renders what's present (`primary`/
`secondary` gauges, `extraWindows`, `tokens`, `dailyUsage`) and hides what's
nil, so providers with different data (Gemini: quotas, no costs) share one shape.
`ProviderRecord` keeps the last good snapshot alongside the last error so
failures degrade to a stale badge instead of blanking the panel.

## Provider engines (one actor each)

| Provider | Limits source | Tokens/cost source | Auth |
|---|---|---|---|
| Claude | `api.anthropic.com/api/oauth/usage` | `~/.claude/projects/**/*.jsonl` + pricing table | Keychain "Claude Code-credentials" via `/usr/bin/security` (stable ACL grant), file fallback |
| Codex | `chatgpt.com/backend-api/wham/usage` (fallback: newest session JSONL `rate_limits`) | `~/.codex/sessions/**` cumulative `token_count` deltas | `~/.codex/auth.json` |
| Cursor | `cursor.com` usage + dashboard APIs | `get-aggregated-usage-events` / `get-filtered-usage-events` | JWT from `state.vscdb` (read-only, immutable mode) → `WorkosCursorSessionToken` cookie |
| Gemini | `cloudcode-pa.googleapis.com` `loadCodeAssist` + `retrieveUserQuota` | n/a (quota-only tab) | `~/.gemini/oauth_creds.json`, in-memory refresh only |

Ground truth for every endpoint/schema: `docs/RESEARCH/*.md` (local
engineering notes, not committed — they contain machine-specific details;
verified against
this machine and the gemini-cli/CodexBar/ccusage sources).

Heavy log parsing is incremental: `FileAggregationCache` persists one aggregate
per file keyed by (size, mtime), so only changed files are re-parsed per tick.
Claude dedups usage lines globally (`message.id` + `requestId`, keeping max
`output_tokens`) at merge time; Codex takes the *last* cumulative `token_count`
per session file and attributes per-turn deltas to the current `turn_context`
model.

## Derived metrics

- **Trend arrows** — gauge delta vs the history sample closest to 1h ago
  (hidden until history reaches back far enough). Up = consuming = red.
- **Usage rate chart** — Δ utilization per 15-min bucket over the last 5h.
- **Pace** — `used / expected(elapsed)` with absolute floors (≥95% critical,
  ≥85% elevated). See `Pace.evaluate` + tests.

## Invariants

- Read-only on provider state: never write back or rotate on-disk credentials
  (Gemini refreshes its short-lived access token in memory only).
- No secrets in logs, no third-party packages, Swift 6 strict concurrency.
- All user-facing formatting goes through `Formatters`; all motion/colors
  through the `UI/DesignSystem` tokens (sourced from `docs/DESIGN.md`).

## Build & ship

`scripts/build-app.sh [--install]` → release build → `dist/Pulse.app`
(LSUIElement, AppIcon from `scripts/make-icon.swift`, ad-hoc codesigned last)
→ optional install into /Applications. Bundle id `de.byte.pulse`.
