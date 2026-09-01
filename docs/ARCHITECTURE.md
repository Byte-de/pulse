# Byte Pulse — Architecture

Native macOS 26 (Tahoe) menu bar app. Swift 6 / SPM, zero third-party
dependencies. Tracks AI usage for Claude, Codex, Cursor, and Gemini from the
user's own local CLI credentials and the providers' own endpoints — read-only,
nothing leaves the machine except calls to those APIs.

## Layers

```
App/        lifecycle, status item, floating panel, settings + breakdown windows (AppKit shell)
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
`secondary`/`tertiary` gauges, `extraWindows`, `tokens`, `dailyUsage`) and hides
what's nil, so providers with different data (Gemini: quotas, no costs) share one
shape. `tertiary` is a featured model-scoped gauge (Claude's Fable weekly cap)
that gets full-card treatment — trend, pace, countdown — like the first two.
`ProviderRecord` keeps the last good snapshot alongside the last error so
failures degrade to a stale badge instead of blanking the panel.

## Provider engines (one actor each)

| Provider | Limits source | Tokens/cost source | Auth |
|---|---|---|---|
| Claude | `api.anthropic.com/api/oauth/usage` (flat windows + structured `limits` array; Fable only in the latter) | `~/.claude/projects/**/*.jsonl`, plus the harnesses billing the same account — `~/.jcode/sessions/session_*.json` and `~/.pi/agent/sessions/**/*.jsonl` — + pricing table | Keychain "Claude Code-credentials" via `/usr/bin/security` (stable ACL grant), file fallback |
| Codex | `chatgpt.com/backend-api/wham/usage` (fallback: newest session JSONL `rate_limits`) | `~/.codex/sessions/**` cumulative `token_count` deltas | `~/.codex/auth.json` |
| Cursor | `cursor.com` usage + dashboard APIs | `get-aggregated-usage-events` / `get-filtered-usage-events` | JWT from `state.vscdb` (read-only, immutable mode) → `WorkosCursorSessionToken` cookie |
| Gemini | `cloudcode-pa.googleapis.com` `loadCodeAssist` + `retrieveUserQuota` | n/a (quota-only tab) | `~/.gemini/oauth_creds.json`, in-memory refresh only |

Ground truth for every endpoint/schema: `docs/RESEARCH/*.md` (local
engineering notes, not committed — they contain machine-specific details;
verified against
this machine and the gemini-cli/CodexBar/ccusage sources).

**Harnesses are not providers.** jcode and pi run against the *same* Anthropic
accounts Claude Code uses, so their tokens are folded into that account's tab
rather than given one of their own. **Attribution is by account identity, never
by a name that can be renamed or reordered** — twice now a naming assumption has
silently moved real money to the wrong tab. jcode's accounts are matched by
*email* (`~/.jcode/auth.json`) against `<configDir>/.claude.json`, and each
account answers to a **set** of labels: its current one *and* the legacy
`claude-N`, because jcode renamed its accounts to `claude-otter`/`claude-fox`
while its session writer kept stamping `claude-1`/`claude-2` (2026-09-01, files
written in the same hour). Matching one label zeroed the Claude tab with no
error anywhere. Both harnesses name accounts positionally (jcode
`claude-1`, `claude-2`; pi `anthropic`, `anthropic-2` in `~/.pi/agent/auth.json`)
but pi records no identity at all: only the key on each message. Ordinal
mapping (`anthropic-N` → the Nth account) was tried and was **backwards** on the
first machine it met — 153.4M tokens on the wrong tab, with nothing about the
numbers looking wrong. `PiAccountResolver` therefore resolves each pi key
against `api.anthropic.com/api/oauth/profile`, whose `account.uuid` is the same
id Claude Code writes into `<configDir>/.claude.json`; the answer is cached
per token fingerprint, so it costs one request per key per sign-in. A key that
cannot be resolved (offline, expired token, signed out) contributes to **no**
tab: dropped usage is visible and recoverable, misattributed usage is neither.
Two config dirs holding the same account (this machine has `~/.claude` and
`~/.claude-joeld`, both joel@) would otherwise both claim the same harness
sessions, so only the first keeps the claim. pi has no sub-agents (no session-level parent;
a record's `parentId` is the conversation DAG), so the token card's sub-agent
rows are gated per window and stay hidden for a pi-only account.

Each of the three writers is separately switchable (Settings > Count Tokens
From). The switches are held in `UsageSourceGate`, a small Sendable holder
`SettingsStore` pushes to and the provider actors read once per refresh —
providers are created at launch, so a constructor parameter (as `captureTitles`
is) would need a restart, and a switch whose point is to watch the total move
cannot need one. Token card, daily chart and breakdown are gated together;
limits and quotas never are, so Codex still takes its fallback rate-limit
window from the newest session file with "provider sessions" off.

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

## On-demand breakdown (by project / session)

The breakdown window (per-project / per-session usage) is a deliberate sibling to
the live dashboard, not part of it. Providers whose local data carries a project
dimension — Claude (`cwd` + one JSONL per session) and Codex
(`session_meta.cwd`) — conform to `ProjectBreakdownProviding`; `ProjectUsageService`
(a Core actor) answers `breakdown(for:timeframe:)` on demand, holding the *same*
provider instances the scheduler drives, so it reuses their **warm**
`FileAggregationCache` — a breakdown query never re-parses the log tree, and the
refresh hot path is untouched. Each parser gained a `breakdown(timeframe:)` that
rolls the cached per-session aggregates up by project over the *same* enumeration
window as `report()` (so the shared cache never thrashes); `report()` itself is
unchanged (it just flattens the richer per-session aggregate's entries). The
window (`BreakdownWindowController`, modeled on Settings; cached, resizable)
auto-refreshes only while focused (`controlActiveState`). Session titles come from
the CLI's own `ai-title` records and are gated by `SettingsStore.useSessionTitles`
(off ⇒ the parser never decodes them — strictly content-blind). Only Claude/Codex
have a local project dimension; the API-quota providers don't implement the
capability.

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
