#!/usr/bin/env bash
# Standalone verifier for the system-stats sidebar.
#
# WHY THIS EXISTS: `swift test` cannot run on a machine without Xcode (the
# `Testing` module is unavailable, so *every* test file fails to compile — not
# just new ones). CI runs the real suite; this harness is how the same logic is
# verified locally, by compiling the real source files with `swiftc` and
# asserting against them, including a live read of this machine's counters. It
# is not a substitute for Tests/PulseTests/SystemMonitorTests.swift, it is a
# second, independent check that also plants known defects and requires each to
# be caught.
#
# Usage: bash scripts/verify-system-stats.sh
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pulse-system-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The real sources under test plus their dependencies. Sparkline and
# DesignSystem pull SwiftUI/AppKit, which is what the sidebar actually renders
# with, so they are compiled rather than reimplemented.
SOURCES=(
  "Sources/Pulse/Core/Services/SystemMonitor.swift"
  "Sources/Pulse/Core/Services/Formatters.swift"
  "Sources/Pulse/Core/Models/ProviderID.swift"
  "Sources/Pulse/Core/Models/Pace.swift"
  "Sources/Pulse/UI/DesignSystem/DesignSystem.swift"
  "Sources/Pulse/UI/Charts/Sparkline.swift"
)

MISSING=0
for source in "${SOURCES[@]}"; do
  if [ ! -f "$REPO/$source" ]; then
    echo "MISSING SOURCE: $source"
    MISSING=1
  fi
done
[ "$MISSING" -eq 0 ] || { echo "FAIL: source list is stale"; exit 1; }

# Exact-string replacement that FAILS LOUDLY when the anchor is gone. A planted
# defect that silently no-ops would leave the clean code running and report a
# false "caught", so a stale anchor must break the harness, not pass it.
swap() {
  local file="$1" from="$2" to="$3"
  FROM="$from" TO="$to" /usr/bin/python3 -c '
import os, sys
path = sys.argv[1]
text = open(path).read()
frm, to = os.environ["FROM"], os.environ["TO"]
if frm not in text:
    sys.exit("defect anchor not found in %s: %r" % (path, frm))
open(path, "w").write(text.replace(frm, to, 1))
' "$file"
}

run_case() {
  # $1 = label, $2 = defect name ("" for the clean run)
  local label="$1" defect="${2:-}"
  local dir="$WORK/$label"
  mkdir -p "$dir/src"
  for source in "${SOURCES[@]}"; do
    cp "$REPO/$source" "$dir/src/$(basename "$source")"
  done
  cp "$REPO/scripts/system-stats-harness.swift" "$dir/src/main.swift"

  case "$defect" in
    "") ;;
    cpu-missing-timebase)
      # Defect: ri_user_time treated as nanoseconds. On Apple Silicon it is mach
      # ticks (41.67 ns each), so every process reads 41.67x too low - herdr at
      # 0.5% instead of 20.4%. A perfectly plausible "quiet machine" reading.
      swap "$dir/src/SystemMonitor.swift" \
        'return Double(timebase.numer) / Double(timebase.denom)' \
        'return 1'
      ;;
    process-table-truncated)
      # Defect: the sysctl buffer sized exactly from the first call, so any
      # process starting in between silently truncates the table. A short table
      # is still a valid-looking table.
      swap "$dir/src/SystemMonitor.swift" \
        'count: size / MemoryLayout<kinfo_proc>.stride + 32' \
        'count: size / MemoryLayout<kinfo_proc>.stride / 4'
      ;;
    approximate-never-flagged)
      # Defect: a denied footprint keeps RSS but is not marked, so two different
      # measurements sit in one ranking with nothing telling them apart.
      swap "$dir/src/SystemMonitor.swift" \
        'row.memoryIsApproximate = true' \
        'row.memoryIsApproximate = false'
      ;;
    memory-total-minus-free)
      # Defect: the classic wrong memory reading — everything not free counted
      # as used, so a healthy Mac shows ~99% and the gauge is permanently red.
      swap "$dir/src/SystemMonitor.swift" \
        "let appPages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)" \
        "let appPages = Int64(stats.active_count) + Int64(stats.inactive_count) + Int64(stats.speculative_count)"
      ;;
    disk-shows-free-not-used)
      # Defect: disk gauge fills with FREE space, so an almost-full disk draws
      # an almost-empty bar.
      swap "$dir/src/SystemMonitor.swift" \
        "return min(100, Double(diskTotal - diskFree) / Double(diskTotal) * 100)" \
        "return min(100, Double(diskFree) / Double(diskTotal) * 100)"
      ;;
    load-not-per-core)
      # Defect: load average used as a raw percentage, ignoring core count. On
      # a 10-core Mac a load of 5 then reads as 5% instead of 50%.
      swap "$dir/src/SystemMonitor.swift" \
        "return min(100, load1 / Double(coreCount) * 100)" \
        "return min(100, load1)"
      ;;
    cpu-no-baseline)
      # Defect: report the since-boot average on the first reading instead of
      # waiting for a delta. A real number that answers the wrong question.
      swap "$dir/src/SystemMonitor.swift" \
        "guard let previous = previousTicks else { return }" \
        "let previous = previousTicks ?? CPUTicks(user: 0, system: 0, idle: 0, nice: 0)"
      ;;
    sparkline-inverted)
      # Defect: y not flipped, so the CPU line reads upside down — a pegged CPU
      # draws a flat bottom line and looks idle.
      swap "$dir/src/Sparkline.swift" \
        "let y = size.height - CGFloat(clamped / maximum) * size.height" \
        "let y = CGFloat(clamped / maximum) * size.height"
      ;;
    sparkline-unclamped)
      # Defect: out-of-range values drawn outside the card bounds.
      swap "$dir/src/Sparkline.swift" \
        "let clamped = min(max(value, 0), maximum)" \
        "let clamped = value"
      ;;
    bytes-base-1024)
      # Defect: base-1024 units labelled GB, so every figure disagrees with
      # Finder and Activity Monitor by ~7%.
      swap "$dir/src/Formatters.swift" \
        "return trimmed(magnitude / 1_000_000_000) + \" GB\"" \
        "return trimmed(magnitude / 1_073_741_824) + \" GB\""
      ;;
    memory-card-resorts-cpu-list)
      # Defect: the memory card re-sorts the CPU top-5 instead of ranking the
      # whole table. Looks right at a glance and silently omits every idle
      # memory hog — the exact processes the card exists to reveal.
      swap "$dir/src/SystemMonitor.swift" \
        'result.topMemoryProcesses = Self.top(all, by: { Double($0.memory) }, limit: processLimit)' \
        'result.topMemoryProcesses = Self.top(result.topProcesses, by: { Double($0.memory) }, limit: processLimit)' 
      ;;
    ranking-ascending)
      # Defect: ranking sorted ascending, so both cards list the quietest
      # processes on the machine.
      swap "$dir/src/SystemMonitor.swift" \
        'processes.sorted { metric($0) > metric($1) }' \
        'processes.sorted { metric($0) < metric($1) }' 
      ;;
    clusters-swapped)
      # Defect: P and E index ranges exchanged. Reports the fast cores idle
      # while a build saturates them, and the slow ones pinned. Every value
      # stays inside 0-100, so only a check that CREATES a known load catches it.
      swap "$dir/src/SystemMonitor.swift" \
        'performanceIndices: efficiencyCount..<total,
                efficiencyIndices: 0..<efficiencyCount,' \
        'performanceIndices: 0..<performanceCount,
                efficiencyIndices: performanceCount..<total,'
      ;;
    cluster-busy-counts-idle)
      # Defect: idle ticks counted as busy, so both clusters read ~100% forever.
      swap "$dir/src/SystemMonitor.swift" \
        'busyTicks += deltaTotal - idle' \
        'busyTicks += deltaTotal'
      ;;
    purgeable-always-zero)
      # Defect: the second capacity key is never read, so "reclaimable cache"
      # reports a constant 0 B. Looks like a Mac with nothing to reclaim, which
      # is indistinguishable from the feature being broken.
      swap "$dir/src/SystemMonitor.swift" \
        'let purgeable = max(0, free - immediatelyFree)' \
        'let purgeable = Int64(0)'
      ;;
    purgeable-subtraction-flipped)
      # Defect: subtraction the wrong way round. max(0,) then clamps it to zero,
      # so the row silently disappears rather than showing a negative.
      swap "$dir/src/SystemMonitor.swift" \
        'let purgeable = max(0, free - immediatelyFree)' \
        'let purgeable = max(0, immediatelyFree - free)'
      ;;
    memory-history-in-bytes)
      # Defect: memory history fed raw bytes instead of utilization, pegging the
      # sparkline at 100% permanently (the fixed 0...100 scale hides the cause).
      swap "$dir/src/SystemMonitor.swift" \
        'Self.append(next.memoryUtilization, to: &memoryHistory)' \
        'Self.append(Double(next.memoryUsed), to: &memoryHistory)'
      ;;
    memory-history-never-trimmed)
      # Defect: the memory series grows without bound while the panel stays
      # open, and drifts out of step with the CPU series it is drawn beside.
      swap "$dir/src/SystemMonitor.swift" \
        'if series.count > historyLimit {' \
        'if series.count > Int.max {'
      ;;
    bundle-id-middle-truncated)
      # Defect: reverse-DNS process names left whole, so the UI middle-truncates
      # them into "com....ntent" — a row that identifies nothing. This is what
      # actually shipped in the first build and was caught on screen.
      swap "$dir/src/SystemMonitor.swift" \
        "return parts.suffix(2).joined(separator: \".\")" \
        "return raw"
      ;;
    compact-bytes-has-space)
      # Defect: compact byte units regain their space, widening the numeric
      # column until the process name truncates again.
      swap "$dir/src/Formatters.swift" \
        "return trimmed(magnitude / 1_000_000_000) + \"G\"" \
        "return trimmed(magnitude / 1_000_000_000) + \" G\""
      ;;
    *)
      echo "unknown defect: $defect"; exit 1 ;;
  esac

  if ! swiftc -swift-version 6 -o "$dir/harness" "$dir"/src/*.swift 2>"$dir/build.log"; then
    echo "BUILD-FAILED"
    grep -m5 "error:" "$dir/build.log" || true
    return 0
  fi
  "$dir/harness" 2>&1 || true
}

echo "=== clean run ==="
CLEAN_OUTPUT="$(run_case clean "")"
echo "$CLEAN_OUTPUT"
if ! grep -q "^ALL PASS" <<<"$CLEAN_OUTPUT"; then
  echo "FAIL: clean run did not pass"
  exit 1
fi

echo
echo "=== planted defects (each MUST be caught) ==="
DEFECTS=(
  cpu-missing-timebase
  process-table-truncated
  approximate-never-flagged
  memory-total-minus-free
  disk-shows-free-not-used
  load-not-per-core
  cpu-no-baseline
  sparkline-inverted
  sparkline-unclamped
  bytes-base-1024
  bundle-id-middle-truncated
  compact-bytes-has-space
  memory-card-resorts-cpu-list
  ranking-ascending
  clusters-swapped
  cluster-busy-counts-idle
  purgeable-always-zero
  purgeable-subtraction-flipped
  memory-history-in-bytes
  memory-history-never-trimmed
)
UNCAUGHT=0
for defect in "${DEFECTS[@]}"; do
  OUTPUT="$(run_case "$defect" "$defect")"
  if grep -q "^ALL PASS" <<<"$OUTPUT"; then
    echo "NOT CAUGHT: $defect"
    UNCAUGHT=$((UNCAUGHT + 1))
  else
    REASON="$(grep -m1 "^FAIL\|^BUILD-FAILED" <<<"$OUTPUT" || echo "no output")"
    echo "caught:     $defect   ($REASON)"
  fi
done

echo
if [ "$UNCAUGHT" -ne 0 ]; then
  echo "FAIL: $UNCAUGHT planted defect(s) went undetected"
  exit 1
fi
echo "OK: clean run passes and all ${#DEFECTS[@]} planted defects are caught"
