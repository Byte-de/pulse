# Changelog

## 2026-06-10 v1.0.1

- New app icon: the Byte "B" mark on the brand acid-orange plate, matching the
  pulse.byte.de site icon (replaces the bar-chart motif). Rendered by
  `scripts/make-icon.swift` onto the standard macOS squircle plate with the
  baked drop shadow; no other changes.

## 2026-06-10 v1.0.0

Initial release of **Byte Pulse** — AI usage for your menu bar.

### Providers (real data only, read-only on your credentials)
- **Claude** — live 5-hour-session & weekly rate-limit gauges (the same endpoint
  Claude Code's `/usage` calls, via the Keychain credentials), per-model weekly
  caps (Opus/Sonnet) when active, plus exact token counts & cost computed from
  the local `~/.claude/projects` logs (streamed-duplicate dedup, 5m/1h cache-write
  pricing split, plan detection "Max 5×" etc.)
- **Codex** — live ChatGPT-account 5h/weekly limits (`wham/usage`) with an
  automatic fallback to the freshest session-log snapshot (expired windows
  dropped, staleness labeled), token history aggregated from `~/.codex/sessions`
  cumulative counters with per-model attribution, plan & credits surfaced
- **Cursor** — plan-usage gauge (modern summary with legacy request-count
  fallback), on-demand spend vs. hard limit, per-model month tokens & cost, and
  paginated 30-day event history; session token read from Cursor's local store
  in immutable mode (a running Cursor is never touched)
- **Copilot** — premium-requests quota, plan, and reset date via the GitHub
  Copilot token from `~/.config/github-copilot`
- **Gemini** — per-model daily quotas + tier via the Code Assist API (Google
  sign-in), token refresh kept strictly in memory

### Menu bar
- Per-provider compact stat blocks (2+1 letter code, threshold-colored dot,
  session % with live numeric ticks, 1-hour trend arrow)
- Only providers active in the last 7 days occupy the bar; dormant/unconnected
  ones keep their tab
- Icon-only mode with the Byte "B" mark (Settings toggle)

### Panel
- Native Tahoe popover chrome (vibrancy material, continuous 20pt corners,
  adaptive hairline), opening on whichever display you click
- Provider tabs with matched-geometry pill; arrow keys / ⌘1–5 switch (reduced
  motion for keyboard, per the motion system)
- Cards: limit gauges with reset countdown ("2h 41m at 15:20") and pace
  (safe/elevated/critical), usage-rate chart (±30%, red = consuming, green =
  rolling off), usage histogram with a clickable timeframe badge
  (1d hourly / 7d / 30d / 1y monthly — per data-source support), token table
  (Today / This Month × Input / Output / Cache / Cost) with model breakdown
- Footer with live "Updated Xs ago", staleness tinting, manual refresh
  (spinner → checkmark); bottom bar: Open <Provider> · Settings · minimize · quit
- Empty/error states per provider; failures degrade to stale data, never a
  blank panel; ESC / click-outside / focus-loss dismissal

### App
- Settings: launch at login, refresh cadence (30s–5m), menu bar style &
  per-provider visibility, provider enable/disable with connection status
- Motion & design system per Emil Kowalski / Jakub Krehel principles
  (docs/DESIGN.md): ≤300ms, exits faster than enters, zero bounce on data,
  Reduce Motion respected throughout
- Swift 6 strict concurrency, zero third-party dependencies, 157 unit tests
- `scripts/build-app.sh --install` builds, signs, and installs `/Applications/Pulse.app`
