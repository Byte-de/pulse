# Contributing to Byte Pulse

Thanks for your interest. Pulse is a native macOS menu-bar app — Swift 6 / SwiftPM,
zero third-party dependencies, privacy-first and read-only on your providers' state.
Keep changes small, focused, and faithful to those constraints.

## Prerequisites

- **macOS 26+** (Apple Silicon)
- **Xcode 26** with the **Swift 6.2** toolchain

## Build

```sh
./scripts/build-app.sh            # build dist/Pulse.app (ad-hoc signed)
./scripts/build-app.sh --install  # build + install /Applications/Pulse.app
./scripts/build-app.sh --run      # build + open dist/Pulse.app
./scripts/build-app.sh --package  # build + create dist/Byte-Pulse.dmg (release asset)
```

## Test

```sh
swift test
```

The suite is currently **197 tests** and **must stay green**. Add tests for new logic;
PRs that change behavior without covering it will be asked for tests.

Two costs are invisible to `swift test`, because they only exist in a running,
rendering app, and both have source-level checks with their own meta-tests:

```sh
python3 scripts/check-timeline-animation.py   # per-tick animation restarts
bash scripts/verify-timeline-animation.sh     # meta-test: plants the defect
python3 scripts/check-gauge-direction.py      # a percentage bypassing the direction setting
bash scripts/verify-system-stats.sh           # the machine sampler, ~2 min
```

`check-timeline-animation.py` exists because a single `.animation(_:value:)`
whose value derived from a `TimelineView`'s clock cost **34% of a core** with
the panel open, and was misdiagnosed three times before it was found. If you add
an animation inside a `TimelineView`, read the header of that script first.


## Where to start

Read these before writing code — they are the source of truth:

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — layers, data flow, provider engines.
- [`docs/DESIGN.md`](docs/DESIGN.md) — the visual + motion system, transcribed into
  `UI/DesignSystem`.

## Invariants (non-negotiable)

Every change must respect these:

- **Read-only on provider state.** Never write back or rotate on-disk credentials.
  In-memory token refresh is allowed only where a provider requires it.
- **No third-party packages.** The dependency graph stays empty.
- **Swift 6 strict concurrency.** Providers are `Sendable` (typically actors).
- **All user-facing formatting goes through `Formatters`** (`Core/Services/Formatters.swift`).
- **All colors and motion come from the `UI/DesignSystem` tokens** — never hardcode a
  color or an ad-hoc animation; use the semantic tokens per `docs/DESIGN.md`.

## Adding a provider

At a high level:

1. Conform a new engine to `UsageProvider` (`Core/Providers/UsageProvider.swift`):
   implement `probeConnection()` (cheap, local-only) and `fetch()` returning a
   capability-shaped `UsageSnapshot`.
2. Register it in `ProviderFactory` (`Providers/ProviderFactory.swift`) in canonical
   display order.

Stay read-only on whatever the provider stores locally, and surface only data you can
read from the provider's own API or local logs.

## Commits & PRs

- Keep PRs **small and focused** — one concern per PR.
- Include **tests for new logic**; keep `swift test` green.
- Update `docs/` and `CHANGELOG.md` when behavior or interfaces change.
- Use a concise, conventional-ish commit subject (e.g. `fix: …`, `feat: …`, `docs: …`).
- Don't introduce secrets, PII, or third-party dependencies.
