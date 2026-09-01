# HANDOFF: Mac RAM + CPU optimization

**Date:** 2026-08-28
**Machine:** Mac16,13 (Apple M4, 4 Performance + 6 Efficiency cores, 16 GB RAM, 460 GB volume)
**Priority order Joel gave:** RAM first, CPU second.
**Status:** omniroute removed. 5.2 GB disk reclaimed. **Pulse's panel-open CPU cost is FOUND AND FIXED** (34% of a core -> 0.3%), committed with a CI gate. One smaller item newly found and still open: a 2.6-second refresh burst every 60 seconds.

---

## 0. Read this first

This file exists because the work spans two things at once: **auditing Joel's machine** (what should not be running) and **fixing Pulse itself** (which turned out to be one of the worst offenders, at ~36% of a core with its panel open).

**The Pulse CPU investigation is now closed.** The cause was one `.animation(_:value:)` modifier in `PanelFooter` whose animated value derived from a `TimelineView`'s clock, so it restarted every second and never completed. A permanently in-flight animation makes SwiftUI redraw at display rate. Details, measurements and the CI gate are in §4.

`--trace-ticks` was **kept deliberately** (it is what found the disk cost after `sample` pointed at the wrong place). Everything is committed; nothing is left uncommitted from this line of work.

Working directory for all Pulse work: `~/MYNE/Projects/pulse`. Commits: `9ca3683` (the animation fix + gate), `8ec2a93` (sampler: sysctl process table, disk cache, trace-ticks).

---

## 1. What is DONE and verified

### 1.1 omniroute removed (RAM: -594 MB)

Joel's instruction was "keep it installed locally with its data, just not running and not using RAM". That is exactly what was done.

| What | State |
|---|---|
| Processes | 0 (was 2: pid 1079 parent + 1294 child, 594 MB combined) |
| Binary | **kept** - `/usr/local/bin/omniroute` -> `../lib/node_modules/omniroute/bin/omniroute.mjs` |
| Data | **kept** - `~/.omniroute`, 82 MB including `storage.sqlite` |
| Launch agent | moved to `~/Library/LaunchAgents/disabled/io.datainnovation.omniroute.plist` |
| jcode provider block | removed from `~/.jcode/config.toml` |

Commands used:
```bash
launchctl bootout gui/$(id -u)/io.datainnovation.omniroute
mkdir -p ~/Library/LaunchAgents/disabled
mv ~/Library/LaunchAgents/io.datainnovation.omniroute.plist ~/Library/LaunchAgents/disabled/
# then removed the [providers.omniroute] block + its 3 [[providers.omniroute.models]] entries
```

**Verification actually performed** (not assumed):
- 0 established connections on ports 20128/20131/20132 before removal, so nothing was using it.
- `default_provider = "claude"`, so the jcode provider block was defined-but-unrouted.
- Config re-parsed with a **real TOML parser** (`tomli`) afterwards: valid, `provider.default_provider = claude` intact, zero `omniroute` strings anywhere in the parsed structure.
- Survived 3+ seconds after bootout without restarting, which proves the `KeepAlive: true` agent is genuinely unloaded.

**Backups:** `~/.jcode/backups-omniroute/omniroute-agent.plist.bak-20260828-132025` (moved out of `/tmp` so a reboot cannot lose it) and `~/.jcode/config.toml.bak-omniroute-20260828-132025`. The build-audit script from §1.2 is saved beside the plist as `~/.jcode/backups-omniroute/jcode-build-audit.py`.

**To restore:**
```bash
mv ~/Library/LaunchAgents/disabled/io.datainnovation.omniroute.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.datainnovation.omniroute.plist
```
To run it manually without autostart: `omniroute serve`.

### 1.2 Disk reclaimed: 5.2 GB total

Joel's volume was at **99% full with 4.4 GB free** and falling. That is more dangerous than any RAM figure: at that level a `cargo build` fails in ways that look like compiler bugs.

| Action | Reclaimed |
|---|---|
| 17 stale `~/.jcode/builds/versions/*` dev builds | 4.5 GB |
| 6967 `~/.jcode/scratch` entries older than 7 days | ~560 MB |
| `~/.jcode/skills-archived-gstack-20260814-220219` | 179 MB |

Now at **11 GB free (98%)**.

The build cleanup used `/tmp/jcode-build-audit.py`, which **protects** anything that is: named by `current-version` / `stable-version` / `shared-server-version`, the manifest canary, one of the 3 most recent builds (rollback window), or **held open by a running process** (checked with `lsof` - a deleted-but-open binary frees nothing until that process exits). 26 versions -> 9 kept. `jcode --version` still works.

**That script is worth keeping.** Copy it into the repo if this needs doing again; `~/.jcode/builds` will regrow at ~320 MB per dev build.

---

## 2. Machine audit: the RAM table

Measured with `phys_footprint` (Activity Monitor's "Memory" column), grouped so an app's helpers count toward the app. Total footprint across 594 processes was **18.87 GB** on 16 GB of RAM, which is why swap sits at 2.8 GB.

| Group | Memory | CPU | Procs | Verdict |
|---|---|---|---|---|
| Safari/WebKit content | 4.50 GB | 8.5% | 11 | **biggest single win available.** Tab hygiene, not a code fix. |
| Spotify | 1.25 GB | 4.2% | 8 | 8 processes for a music player. Quit when not listening. |
| jcode | 1.23 GB | 3.4% | 30 | 30 processes. Worth asking whether all are live sessions. |
| wezterm-gui | 1.12 GB | 2.9% | 1 | scrollback. Reducing it is a config change. |
| Google Chrome | 922 MB | 5.9% | 13 | second browser running alongside Safari. |
| Safari (main) | 774 MB | 5.9% | 1 | |
| ~~omniroute~~ | ~~594 MB~~ | | | **DONE - removed** |
| mysqld | 571 MB | 0.0% | 1 | **KEEP.** 6 established PHP connections, genuinely in use. |
| Lightshot Screenshot | 477 MB | 0.0% | 1 | **best remaining candidate.** 477 MB for a screenshot tool that is idle. macOS Shift-Cmd-4 does most of it. |
| Obsidian helpers | 579 MB | 0.0% | 3 | |
| **Pulse** | 249 MB | see §4 | 1 | our own app |

### Login items still loaded

```
com.jcode.hotkey                              pid 19478
com.kunchenguid.no-mistakes.daemon.eba4be4a   pid 1067
com.samsung.portablessdplus.mon               pid 1089   <- 6 MB, no Samsung drive attached. Not worth removing.
herdr.collie                                  pid 73415
homebrew.mxcl.mysql                           pid 97188  <- in use, keep
com.openai.atlas.update-helper                (not running)
com.stremio.service                           (not running)
io.datainnovation.mcp-reaper                  (not running)
```

### Disk hogs not yet touched (judgment calls, not cleanups)

- `~/.cache/whisper` **4.4 GB** - `large-v3.pt` (2.9 GB) + `medium.pt` (1.4 GB) + `base.pt` (139 MB). FluidVoice is the consumer. **Ask Joel which model FluidVoice actually uses**; the other two are pure waste, and dropping `large-v3` alone frees 2.9 GB.
- `~/.jcode/sessions` 1.6 GB, `~/.jcode/logs` 835 MB (nothing older than 14 days, so it is all recent), `~/.cache/codex-runtimes` 1.5 GB, `~/.cache/opencode` 956 MB, `~/.cache/huggingface` 852 MB.
- `~/MYNE` is **214 GB**. Not investigated. This is where the real disk pressure lives.

---

## 3. TODO, in priority order (RAM first, as instructed)

### RAM
1. **Lightshot Screenshot: 477 MB idle.** Decide whether to keep it. Highest RAM-per-value ratio left after omniroute.
2. **Ask Joel about the two browsers.** Safari 5.27 GB + Chrome 922 GB = 6.2 GB, ~39% of his RAM. Not something to change without asking; it is how he works.
3. **jcode's 30 processes / 1.23 GB.** Determine how many are live sessions vs strays. There is an `io.datainnovation.mcp-reaper` agent that is not running - possibly meant for exactly this.
4. **Spotify's 8 processes / 1.25 GB.** Quitting when unused is a habit change, not a fix.

### CPU
5. ~~**Finish Pulse's panel-open cost.**~~ **DONE.** 34% -> 0.3%, one `.animation` modifier. See §4. Committed as `9ca3683` with a CI gate.
6. ~~**Decide the fate of `--trace-ticks`.**~~ **DONE - kept**, gated behind the launch argument. It is what found the disk cost; committed as `8ec2a93`.
7. **Pulse's 2.6-second refresh burst every 60 s** with the panel closed. Newly found, still open, suspected to be a ~14 MB cache file being reserialized on every refresh. Full detail and the next diagnostic step in §4.1.
8. **WindowServer at 33-46%** was the top CPU consumer all session. **Re-measure this first** - it was measured while the Pulse panel was pinned open, which we now know was redrawing at display rate and would drive WindowServer hard by itself. It may already be gone.

### Disk
9. **Whisper models: 4.4 GB.** One question to Joel unlocks up to 4.2 GB.
10. **~60 MB of stale `pricecheck-*` / `verify-*` files** in `~/Library/Application Support/Pulse/Cache/`, left by verifier runs. Small, but they are Pulse's own mess.
11. `~/MYNE` at 214 GB needs its own pass.

---

## 4. Pulse's own CPU cost: FOUND AND FIXED

This started because Joel said "even Pulse is spending too much". He was right. The cause was not the sidebar, not the sampler, and not SwiftUI layout, all three of which were blamed first.

### The bug

`PanelFooter`:

```swift
TimelineView(.periodic(from: .now, by: 1)) { context in
    Text(statusText(now: context.date))
        .contentTransition(.numericText())
        .animation(Motion.numberTick, value: statusText(now: context.date))  // <- 34% of a core
}
```

`.animation(_:value:)` starts an animation whenever `value` changes. That value is a string derived from the timeline's clock, so it changed on **every tick**: the animation never finished before the next began, and a permanently in-flight animation makes SwiftUI redraw that layer tree at **display rate** (60-120 Hz) instead of once per second.

`SystemColumn` had the identical bug on the CPU and Memory percentages at the 3-second sample cadence, worth ~10% -> ~3%. That is why the sidebar looked guilty: it was guilty of a smaller instance of the same mistake.

Deleting the modifiers loses nothing visually. `contentTransition(.numericText())` still animates the digit change, driven by the value actually changing.

### Measurements (M4, cumulative CPU time over 60s windows, `ps -o time`)

| State | CPU |
|---|---|
| Panel closed, idle | **0.0%** |
| Panel closed, averaged over a refresh cycle | 4.3% (see §4.1 - a 2.6 s burst every 60 s) |
| Panel open, sidebar off, **before** the fix | **34.0%** steady |
| Panel open, sidebar off, **after** the fix | **0.3%** steady |
| Panel open, sidebar on with process cards, after both fixes | **2-5%** |

### Why it took three attempts to find

- `sample` attributes the time to `LayoutEngineBox` and `StackLayout`. That is where the redraws *land*, not where they *originate*, so the profile pointed at layout and a `geometryGroup()` isolation change was made that did nothing.
- The handoff's earlier "panel closed = 0.0%, panel open with sidebar off = 0.2%" figures were wrong. `--pin-panel` does not OPEN the panel, it only blocks dismissal, so an earlier measurement labelled "panel open" was taken with the panel closed. **Use `--show-panel --pin-panel` together, and confirm with a screenshot before trusting any number.**
- What isolated it: toggling ONE modifier at a time on the same build behind a launch flag, and reading cumulative CPU time in 5-second buckets. Per-bucket sampling also separated steady load from a periodic burst, which a single 60-second average hides completely.

### The gate

- `scripts/check-timeline-animation.py` fails when an animated value reads `context.date` inside a periodic `TimelineView`. It deliberately ALLOWS an animation on a value that does not: six lines above the offending one, the same file animates `staleness.level`, which stays constant for minutes and costs nothing measurable. Escape hatch: `// timeline-animation-ok: <reason>`.
- `scripts/verify-timeline-animation.sh` plants five variants of the real defect (including a wrapped-onto-two-lines form), requires each to be caught, requires the two legitimate cases to pass, and requires a clean run after reverting. Currently **5 caught, 2 allowed**.
- Both are documented in `CONTRIBUTING.md` under Test.

### 4.1 STILL OPEN: a 2.6-second burst every 60 seconds

With the panel **closed**, Pulse is genuinely 0.0% while idle, then spends **2.6 seconds of CPU in one burst every 60 seconds** - the provider refresh (`refreshInterval` defaults to 60 s). Averaged, that is the 4.3% a naive one-minute measurement reports.

What is known:
- It is the JSONL log parse, not the network call.
- `FileAggregationCache` already avoids re-parsing unchanged files, so the burst is **not** re-parsing 3554 Claude session files.
- The suspicion is the cache's own persistence. `~/Library/Application Support/Pulse/Cache/jcode-files-v3.json` is **14 MB** and `claude-files-v2.json` is 4.8 MB. Measured standalone: 79 ms to parse and 69 ms to reserialize the 14 MB file. `persist()` rewrites the WHOLE dictionary whenever `changedCount > 0`, and with jcode sessions being written continuously there is always at least one changed file, so a ~14 MB encode-and-write likely happens every refresh, for every account. Six cache files exist.
- Not yet confirmed in-app. **Next step: put the same per-phase timing that found the disk cost around `loadIfNeeded`/`persist`/`aggregates`, run with the panel closed, and read `/tmp/pulse-ticks.log`.** Do not benchmark it standalone - that is exactly the mistake that hid the disk cost for a session (see domain note 4).
- That directory also holds ~60 MB of stale `pricecheck-*` and `verify-*` cache files from earlier verifier runs, which is a separate small cleanup.

## 5. Domain notes worth keeping (things that cost real time this session)

1. **`ri_user_time` is in MACH TICKS on Apple Silicon, not nanoseconds.** `mach_timebase_info` gives numer=125 denom=3, so 1 unit = 41.667 ns. Reading it as ns under-reports every process by 41.67x - `herdr` showed 0.5% against `ps`'s 20.4%. A plausible "quiet machine" reading that is completely wrong.

2. **`host_processor_info` lists EFFICIENCY cores first, the reverse of the perflevel numbering.** `hw.perflevel0` is "Performance" (4 cores), `hw.perflevel1` is "Efficiency" (6), but array indices 0-5 are the E-cores and 6-9 are the P-cores. Verified both ways by pinning spin loops at `.background` (landed 0-3) and `.userInteractive` (landed 6-9) QoS.

3. **`ps` RSS and `phys_footprint` are different measurements, and the ratio varies per process** (0.89x to 11.6x measured here: Safari 68 MB RSS vs 800 MB footprint). So ranking on RSS is not "the same list scaled down", it is the **wrong order** with the multi-gigabyte processes missing entirely. Activity Monitor shows footprint.

4. **Benchmark the phase where it runs, not in isolation.** A standalone loop measured the disk call at 0.7 ms and completely missed the real cost, because the second iteration hits a warm cache. Only in-app per-phase timing revealed 15-26 ms. This is why the instrumentation earned its place.

5. **`sample` (the profiler) pointed at the wrong thing.** It blamed SwiftUI layout; the real cost was a blocking framework call whose time is spent in another process. Threads showing `__workq_kernreturn` are parked, not busy. When `sample` and `ps`/`top` disagree, trust cumulative CPU time (`ps -o time`) - it cannot lie about what was consumed.

6. **`df /` reports 51% while the data volume is at 98%.** On APFS, `/` is a read-only system snapshot. Any disk figure must come from the data volume (`volumeAvailableCapacityForImportantUsage` on a path in `$HOME`, which is what Finder shows). Reading `/` gives a clean, plausible, wrong answer.

7. **macOS has no "purgeable space" API.** It is `...ForImportantUsage` minus `...AvailableCapacity` = 751 MB here.

8. **A tolerance larger than the value it checks tests nothing.** A 1 GB tolerance on a 0.75 GB figure let two planted defects through while looking rigorous.

9. **A per-tick `.animation(_:value:)` in SwiftUI redraws at DISPLAY rate, not at tick rate.** `.animation(_:value:)` starts an animation each time `value` changes; if the value derives from a `TimelineView`'s clock it changes every tick, so the animation restarts before finishing and never leaves the in-flight state. One such line in a 1-second footer cost **34% of a core**; the same mistake at a 3-second cadence cost ~7%. The tell is that CPU scales with the TICK INTERVAL rather than with the work per tick. `contentTransition` alone is safe - it keys off the value actually changing. Recognise it by asking, of every `.animation(_:value:)`: *can this value change on a timer?*

10. **`--show-panel` opens the panel; `--pin-panel` only stops it closing.** Measuring "panel open" with `--pin-panel` alone measures a CLOSED panel and returns a clean, plausible, wrong number - which is how the previous session recorded 0.2% for a state that actually cost 34%. Always confirm the window is on screen with a screenshot before recording a figure.

11. **A 60-second average hides a periodic burst completely.** Pulse with the panel closed reads 4.3% averaged, which looks like a small constant leak worth ignoring. In 5-second buckets it is 0.0% idle plus one 2.6-second burst per minute - a completely different bug with a completely different fix. Sample in buckets shorter than the period you suspect.

12. **`git checkout <file>` in a repo with 30+ uncommitted files is destructive and unrecoverable.** Done twice this session while toggling experiments, wiping another session's uncommitted `GaugeBar.swift` (recovered from a `/tmp` worktree that happened to have it) and the `geometryGroup()` work in `SystemColumn.swift` (not recovered - it turned out to be unnecessary). **Toggle behaviour behind a launch flag, never by editing and reverting.** `git worktree list` is the recovery path worth checking first.

13. **`--pin-panel` disables every dismissal path** (ESC, click-outside, focus loss, status-item toggle). Launching Pulse with it looks exactly like the app hanging. This confused Joel twice; it is documented in `PanelController.swift` now.

---

## 6. State of the Pulse repo

Committed this session:
- `1f095d9` machine-stats sidebar
- `3b0122c` memory sparkline + reclaimable-cache figure
- `c1c71a9` P/E core split
- `bc8767a` phys_footprint for process memory, dropped the secondary metric column
- `9b7eba2` this handoff
- **`9ca3683` the animation fix (34% -> 0.3%) + `check-timeline-animation.py` + its meta-test + CONTRIBUTING**
- **`8ec2a93` sysctl process table, 60 s disk cache, 3 s interval, no-op publish guard, `--trace-ticks` kept**

Nothing from this line of work is left uncommitted.

**The repo still has ~30 dirty files from OTHER sessions** (pace marker, multi-account, pricing, jcode sub-agent attribution). They were deliberately not touched, not staged, and not reverted. `docs/HANDOFF-jcode-subagent-attribution.md` covers that work.

Verifiers, all currently passing:
```sh
python3 scripts/check-timeline-animation.py   # PASS: 24 view files
bash scripts/verify-timeline-animation.sh     # PASS: 5 planted caught, 2 legitimate allowed
python3 scripts/check-gauge-direction.py      # PASS: 2 surfaces
bash scripts/verify-system-stats.sh           # OK: 20 planted defects all caught (~2 min)
```

Two anchors in `verify-system-stats.sh` went stale when the disk cache rewrote those lines. It printed `defect anchor not found` and FAILED rather than silently reporting a pass, which is the property that check exists for. Anchors updated in `8ec2a93`.

`swift test` cannot run on this machine - no Xcode, so the `Testing` module is unavailable and every test file fails to compile. `swift build` works.

### How to measure Pulse's CPU (reproducible)

```sh
# open the panel for real, and keep it open
open -a /Applications/Pulse.app --args --show-panel --pin-panel

# 5-second buckets: separates steady load from a periodic burst
bash scripts/measure-pulse-cpu.sh 5 12
```
`scripts/measure-pulse-cpu.sh` is committed, and its header carries both traps: `--pin-panel` without `--show-panel` measures a closed panel, and a single 60-second average hides a periodic burst. Read cumulative CPU time (`ps -o time`), not `sample`, and confirm the panel is on screen with a screenshot before recording a figure.
