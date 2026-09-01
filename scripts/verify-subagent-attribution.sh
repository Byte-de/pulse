#!/usr/bin/env bash
# Standalone verifier for jcode sub-agent attribution.
#
# WHY THIS EXISTS: `swift test` cannot run on a machine without Xcode (the
# `Testing` module is unavailable, so *every* test file fails to compile — not
# just new ones). CI runs the real suite; this harness is how the same logic is
# verified locally, by compiling the real source files with `swiftc` and
# asserting against them. It is not a substitute for Tests/PulseTests, it is a
# second, independent check that also plants known defects and requires each to
# be caught.
#
# Usage: bash scripts/verify-subagent-attribution.sh
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pulse-subagent-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The real sources under test, plus their dependencies. Deliberately a narrow
# list: pulling the whole app in would drag SwiftUI and defeat the point.
SOURCES=(
  "Sources/Pulse/Core/Models/TokenUsage.swift"
  "Sources/Pulse/Core/Models/ProjectUsage.swift"
  "Sources/Pulse/Core/Models/ProviderID.swift"
  "Sources/Pulse/Core/Models/UsageSnapshot.swift"
  "Sources/Pulse/Core/Models/LimitWindow.swift"
  "Sources/Pulse/Core/Models/Pace.swift"
  "Sources/Pulse/Core/Models/ProviderFetchError.swift"
  "Sources/Pulse/Core/Pricing/ModelPricing.swift"
  "Sources/Pulse/Core/Services/AppPaths.swift"
  "Sources/Pulse/Core/Services/FileAggregationCache.swift"
  "Sources/Pulse/Core/Services/JSONLines.swift"
  "Sources/Pulse/Core/Services/UsageMath.swift"
  "Sources/Pulse/Core/Services/HistoryStore.swift"
  "Sources/Pulse/Providers/Claude/ClaudeLogParser.swift"
  "Sources/Pulse/Providers/Claude/ClaudeUsageAPI.swift"
  "Sources/Pulse/Core/Services/HTTPClient.swift"
  "Sources/Pulse/Providers/Jcode/JcodeLogParser.swift"
  "Sources/Pulse/Core/Services/Formatters.swift"
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
  cp "$REPO/scripts/subagent-harness.swift" "$dir/src/main.swift"

  case "$defect" in
    "") ;;
    treat-children-as-main)
      # Defect: parent_id ignored, every session reads as main.
      /usr/bin/sed -i '' 's/isSubAgent: file.parentID != nil/isSubAgent: false/' "$dir/src/JcodeLogParser.swift"
      /usr/bin/sed -i '' 's/slice.isSubAgent = true/slice.isSubAgent = false/' "$dir/src/JcodeLogParser.swift"
      ;;
    no-ancestor-walk)
      # Defect: never walk up at all, so a child keeps its own working_dir and
      # its tokens land on the project it RAN in rather than the one that
      # spawned it. This is the naive implementation the walk exists to avoid.
      swap "$dir/src/JcodeLogParser.swift" \
        "seen.count < 64 {" \
        "seen.count < 1 {"
      ;;
    attribute-one-level-up)
      # Defect: stop at the IMMEDIATE parent instead of the root ancestor.
      # Correct for a depth-1 child and wrong only for a nested one, which is
      # why the grandchild fixture exists (5 of 21 real children nest).
      swap "$dir/src/JcodeLogParser.swift" \
        "seen.count < 64 {" \
        "seen.count < 2 {"
      ;;
    drop-cache-bump)
      /usr/bin/sed -i '' 's/"jcode-files-v3"/"jcode-files-v2"/' "$dir/src/JcodeLogParser.swift"
      ;;
    subagent-added-not-subset)
      # Defect: sub-agent totals double-counted into the headline row.
      swap "$dir/src/ClaudeLogParser.swift" \
        "if isSubAgent { todaySub.add(totals) }" \
        "if isSubAgent { todaySub.add(totals); today.add(totals) }"
      ;;
    main-totals-wrong-direction)
      # Defect: sub-agent usage added to the main figure instead of subtracted.
      swap "$dir/src/ProjectUsage.swift" \
        "input: totals.input - subAgentTotals.input," \
        "input: totals.input + subAgentTotals.input,"
      ;;
    *)
      echo "unknown defect: $defect"; exit 1 ;;
  esac

  if ! swiftc -O -swift-version 6 -o "$dir/harness" "$dir"/src/*.swift 2>"$dir/build.log"; then
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
  treat-children-as-main
  no-ancestor-walk
  attribute-one-level-up
  drop-cache-bump
  subagent-added-not-subset
  main-totals-wrong-direction
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
