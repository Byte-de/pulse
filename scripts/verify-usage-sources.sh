#!/usr/bin/env bash
# Standalone verifier for the "Count Tokens From" switches, end to end:
# Settings writes UsageSourceGate, ClaudeProvider reads it, and the breakdown
# it returns actually loses (only) that source's sessions.
#
# WHY THIS EXISTS: the switch, the gate and the reader sit in three different
# layers. Each can be correct in isolation while the wire between them is cut,
# and the symptom is a toggle that silently does nothing. `swift test` cannot
# run here (no `Testing` module without Xcode), so the real sources are compiled
# with `swiftc` and asserted against, with known defects planted afterwards.
#
# Reads the live ~/.claude, ~/.jcode and ~/.pi trees read-only.
#
# Usage: bash scripts/verify-usage-sources.sh
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pulse-usage-sources.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

SOURCES=(
  "Sources/Pulse/Core/Models/TokenUsage.swift"
  "Sources/Pulse/Core/Models/ProjectUsage.swift"
  "Sources/Pulse/Core/Models/ProviderID.swift"
  "Sources/Pulse/Core/Models/UsageSnapshot.swift"
  "Sources/Pulse/Core/Models/LimitWindow.swift"
  "Sources/Pulse/Core/Models/Pace.swift"
  "Sources/Pulse/Core/Models/ProviderFetchError.swift"
  "Sources/Pulse/Core/Pricing/ModelPricing.swift"
  "Sources/Pulse/Core/Providers/UsageProvider.swift"
  "Sources/Pulse/Core/Providers/ProjectBreakdownProviding.swift"
  "Sources/Pulse/Core/Services/AppPaths.swift"
  "Sources/Pulse/Core/Services/FileAggregationCache.swift"
  "Sources/Pulse/Core/Services/Formatters.swift"
  "Sources/Pulse/Core/Services/HistoryStore.swift"
  "Sources/Pulse/Core/Services/HTTPClient.swift"
  "Sources/Pulse/Core/Services/JSONLines.swift"
  "Sources/Pulse/Core/Services/JWT.swift"
  "Sources/Pulse/Core/Services/KeychainReader.swift"
  "Sources/Pulse/Core/Services/UsageMath.swift"
  "Sources/Pulse/Core/Services/UsageSources.swift"
  "Sources/Pulse/Providers/Claude/ClaudeAccount.swift"
  "Sources/Pulse/Providers/Claude/ClaudeCredentials.swift"
  "Sources/Pulse/Providers/Claude/ClaudeLogParser.swift"
  "Sources/Pulse/Providers/Claude/ClaudeProvider.swift"
  "Sources/Pulse/Providers/Claude/ClaudeUsageAPI.swift"
  "Sources/Pulse/Providers/Claude/JcodeCredentialsStore.swift"
  "Sources/Pulse/Providers/Codex/CodexAuth.swift"
  "Sources/Pulse/Providers/Codex/CodexProvider.swift"
  "Sources/Pulse/Providers/Codex/CodexSessionParser.swift"
  "Sources/Pulse/Providers/Codex/CodexUsageAPI.swift"
  "Sources/Pulse/Providers/Jcode/JcodeLogParser.swift"
  "Sources/Pulse/Providers/Pi/PiLogParser.swift"
  "Sources/Pulse/Providers/Pi/PiAccountResolver.swift"
)

for source in "${SOURCES[@]}"; do
  [ -f "$REPO/$source" ] || { echo "FAIL: source list is stale, missing $source"; exit 1; }
done

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
  cp "$REPO/scripts/usage-source-harness.swift" "$dir/src/main.swift"

  case "$defect" in
    "") ;;
    ignore-pi-switch)
      swap "$dir/src/ClaudeProvider.swift" \
        'async let piTask = sources.pi ?' \
        'async let piTask = true ?'
      ;;
    ignore-jcode-switch)
      swap "$dir/src/ClaudeProvider.swift" \
        'async let jcodeTask = sources.jcode ?' \
        'async let jcodeTask = true ?'
      ;;
    ignore-provider-logs-switch)
      swap "$dir/src/ClaudeProvider.swift" \
        'async let claudeTask = sources.providerLogs ? parser.sessions(now: now) : []' \
        'async let claudeTask = parser.sessions(now: now)'
      ;;
    pi-switch-drops-jcode-too)
      # Defect: one switch that silently takes a neighbour with it. Totals still
      # go down when you flip it, which is exactly why "the number moved" is not
      # evidence that a switch works.
      swap "$dir/src/ClaudeProvider.swift" \
        'async let jcodeTask = sources.jcode ?' \
        'async let jcodeTask = (sources.jcode && sources.pi) ?'
      ;;
    jcode-current-label-only)
      # Defect: match only jcode's *current* label. jcode's session writer still
      # stamps the original `claude-N`, so this drops every jcode session the
      # moment an account is renamed - silently, with plausible zeros.
      swap "$dir/src/ClaudeAccount.swift" \
        'for match in matches { labels.insert("claude-\(match.index + 1)") }' \
        '_ = matches'
      ;;
    jcode-label-never-matches)
      # Defect: the email match never succeeds, so no account claims any jcode
      # session. Stands in for every "the link between the two stores broke"
      # failure, which is what a rename actually is.
      swap "$dir/src/ClaudeAccount.swift" \
        'return refEmail.caseInsensitiveCompare(email) == .orderedSame' \
        'return false'
      ;;
    pi-key-matches-any-account)
      # Defect: the resolver stops matching on the account uuid, so every
      # account claims every pi key and the same session is counted on two tabs.
      swap "$dir/src/PiAccountResolver.swift" \
        'return Set(resolved.filter { $0.value.accountUUID == accountUUID }.keys)' \
        'return Set(resolved.keys)'
      ;;
    breakdown-reads-the-gate)
      # Defect: the breakdown ignores its argument and reads the panel's gate,
      # so the window's own filter silently becomes a second copy of Settings.
      swap "$dir/src/ClaudeProvider.swift" \
        'let sessions = await allSessions(now: now, sources: sources)' \
        'let sessions = await allSessions(now: now, sources: UsageSourceGate.shared.current)'
      ;;
    empty-filter-means-everything)
      # Defect: a stored-but-empty filter decodes as "all". Reads as a harmless
      # default and quietly ignores a filter the user set.
      swap "$dir/src/UsageSources.swift" \
        'guard let stored else { self = .all; return }' \
        'guard let stored, !stored.isEmpty else { self = .all; return }'
      ;;
    codex-ignores-provider-logs-switch)
      swap "$dir/src/CodexProvider.swift" \
        'guard sources.providerLogs else { return nil }' \
        'guard true else { return nil }'
      ;;
    gate-never-updates)
      # Defect: the gate ignores writes, so Settings changes nothing.
      swap "$dir/src/UsageSources.swift" \
        '            storage = newValue' \
        '            storage = .all'
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
CLEAN="$(run_case clean "")"
echo "$CLEAN"
grep -q "^ALL PASS" <<<"$CLEAN" || { echo "FAIL: clean run did not pass"; exit 1; }

echo
echo "=== planted defects (each MUST be caught) ==="
DEFECTS=(
  ignore-pi-switch
  ignore-jcode-switch
  ignore-provider-logs-switch
  pi-switch-drops-jcode-too
  jcode-current-label-only
  jcode-label-never-matches
  pi-key-matches-any-account
  breakdown-reads-the-gate
  empty-filter-means-everything
  codex-ignores-provider-logs-switch
  gate-never-updates
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
