#!/usr/bin/env bash
# Standalone verifier for the pi harness parser and the sub-agent row gate.
#
# WHY THIS EXISTS: `swift test` cannot run on a machine without Xcode (the
# `Testing` module is unavailable, so *every* test file fails to compile). This
# harness compiles the real sources with `swiftc`, asserts against them, and
# then plants known defects and requires each to be caught — an eval that never
# failed proves nothing.
#
# Usage: bash scripts/verify-pi-tokens.sh
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pulse-pi-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The sources under test plus their dependencies. Narrow on purpose: pulling
# the whole app in would drag SwiftUI and defeat the point.
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
  "Sources/Pulse/Core/Services/Formatters.swift"
  "Sources/Pulse/Core/Services/HTTPClient.swift"
  "Sources/Pulse/Providers/Claude/ClaudeLogParser.swift"
  "Sources/Pulse/Providers/Claude/ClaudeUsageAPI.swift"
  "Sources/Pulse/Providers/Pi/PiLogParser.swift"
  "Sources/Pulse/Providers/Pi/PiAccountResolver.swift"
)

MISSING=0
for source in "${SOURCES[@]}"; do
  if [ ! -f "$REPO/$source" ]; then
    echo "MISSING SOURCE: $source"
    MISSING=1
  fi
done
[ "$MISSING" -eq 0 ] || { echo "FAIL: source list is stale"; exit 1; }

# Exact-string replacement that FAILS LOUDLY when the anchor is gone: a defect
# that silently no-ops would leave the clean code running and report a false
# "caught".
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
  local label="$1" defect="${2:-}"
  local dir="$WORK/$label"
  mkdir -p "$dir/src"
  for source in "${SOURCES[@]}"; do
    cp "$REPO/$source" "$dir/src/$(basename "$source")"
  done
  cp "$REPO/scripts/pi-harness.swift" "$dir/src/main.swift"

  case "$defect" in
    "") ;;
    fold-openai-into-claude)
      # Defect: treat any provider key as an Anthropic account, so OpenAI- and
      # Vertex-billed turns land on a Claude tab.
      swap "$dir/src/PiAccountResolver.swift" \
        'guard key.hasPrefix("anthropic-") else { return false }' \
        'guard key.hasPrefix("anthropic-") else { return true }'
      ;;
    guess-unresolved-onto-an-account)
      # Defect: with no resolved keys, fall back to pi's first key. This is the
      # shape of the original bug - a plausible guess that silently billed
      # 153.4M tokens to the wrong account.
      swap "$dir/src/PiLogParser.swift" \
        'guard !providerKeys.isEmpty else { return [] }' \
        'let providerKeys = providerKeys.isEmpty ? ["anthropic"] : providerKeys'
      ;;
    double-count-1h-cache-writes)
      # Defect: book the 1h slice in both buckets, inflating cache writes and
      # pricing the 1h tokens twice.
      swap "$dir/src/PiLogParser.swift" \
        'cacheWrite5m: max((usage.cacheWrite ?? 0) - (usage.cacheWrite1h ?? 0), 0),' \
        'cacheWrite5m: usage.cacheWrite ?? 0,'
      ;;
    unnamespaced-dedup-key)
      # Defect: use pi's 8-hex record id as the global dedup key. Unique per
      # file only, so a collision across sessions deletes a turn's tokens.
      swap "$dir/src/PiLogParser.swift" \
        'key: record.id.map { "\(sessionID)|\($0)" },' \
        'key: record.id,'
      ;;
    keep-zero-usage-turns)
      # Defect: keep turns that billed nothing, resurrecting phantom sessions.
      swap "$dir/src/PiLogParser.swift" \
        'guard billed > 0 else { return }' \
        'guard billed >= 0 else { return }'
      ;;
    ignore-session-cwd)
      # Defect: never read the `session` record, so every pi session groups
      # under the encoded directory name and has no display path.
      swap "$dir/src/PiLogParser.swift" \
        'if let dir = record.cwd, !dir.isEmpty { cwd = dir }' \
        'if record.cwd != nil { cwd = nil }'
      ;;
    mark-pi-sessions-as-subagents)
      # Defect: pi sessions flagged as sub-agent work, which resurrects the
      # all-zero row this change exists to hide (and, worse, moves real tokens
      # into a bucket pi cannot populate).
      swap "$dir/src/PiLogParser.swift" \
        'isSubAgent: false' \
        'isSubAgent: true'
      ;;
    show-zero-subagent-row)
      # Defect: the gate goes back to "always show", so an account whose only
      # harness is pi renders a row of zeros.
      swap "$dir/src/TokenUsage.swift" \
        'slice.total > 0 || (slice.costUSD ?? 0) > 0' \
        'true'
      ;;
    decode-conversation-text)
      # Defect: cache the assistant's text alongside the counters. The tokens
      # stay correct, which is exactly why a totals-only check cannot see it.
      swap "$dir/src/PiLogParser.swift" \
        '                title: nil,' \
        '                title: entries.first.map { _ in "PROMPT-TEXT" },'
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
  fold-openai-into-claude
  guess-unresolved-onto-an-account
  double-count-1h-cache-writes
  unnamespaced-dedup-key
  keep-zero-usage-turns
  ignore-session-cwd
  mark-pi-sessions-as-subagents
  show-zero-subagent-row
  decode-conversation-text
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
