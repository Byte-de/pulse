#!/usr/bin/env bash
# Standalone verifier for 429 / Retry-After handling.
#
# WHY THIS EXISTS: on 2026-09-01 the first Claude account showed no limits at
# all. The cause was a 429 on https://api.anthropic.com/api/oauth/usage - and
# the reason it never cleared was ours: `ClaudeProvider.fetch()` deliberately
# does not throw when only the limits half fails (the token history is still
# worth showing), so `RefreshScheduler` saw a successful fetch, reset its
# backoff to 1 on every tick, and kept calling a rate-limited endpoint every
# 60 seconds - renewing the penalty each time. `Retry-After: 2808` was being
# thrown away with the rest of the headers.
#
# This is a silent failure by construction: the app looks fine, the panel shows
# carried-forward numbers, and nothing anywhere says "we are the reason this is
# not recovering". So it gets a verifier with planted defects rather than a
# comment.
#
# `swift test` cannot run on a machine without Xcode (the `Testing` module is
# unavailable, so every test file fails to compile). CI runs the real suite;
# this compiles the real sources with swiftc and asserts against them.
#
# Usage: bash scripts/verify-rate-limit-backoff.sh
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pulse-ratelimit-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

SOURCES=(
  "Sources/Pulse/Core/Models/ProviderFetchError.swift"
  "Sources/Pulse/Core/Models/ProviderID.swift"
  "Sources/Pulse/Core/Models/UsageSnapshot.swift"
  "Sources/Pulse/Core/Models/LimitWindow.swift"
  "Sources/Pulse/Core/Models/TokenUsage.swift"
  "Sources/Pulse/Core/Models/Pace.swift"
  "Sources/Pulse/Core/Models/ProjectUsage.swift"
  "Sources/Pulse/Core/Providers/UsageProvider.swift"
  "Sources/Pulse/Core/Services/HTTPClient.swift"
  "Sources/Pulse/Core/Services/RefreshScheduler.swift"
  "Sources/Pulse/Core/Services/UsageStore.swift"
  "Sources/Pulse/Core/Services/HistoryStore.swift"
  "Sources/Pulse/Core/Services/SettingsStore.swift"
  "Sources/Pulse/Core/Services/UsageMath.swift"
  "Sources/Pulse/Core/Services/UsageSources.swift"
  "Sources/Pulse/Core/Services/AppPaths.swift"
  "Sources/Pulse/Core/Services/Formatters.swift"
  "Sources/Pulse/Core/Services/FileAggregationCache.swift"
  "Sources/Pulse/Core/Services/JSONLines.swift"
)
HARNESS="scripts/rate-limit-harness.swift"

MISSING=0
for source in "${SOURCES[@]}" "$HARNESS"; do
  if [ ! -f "$REPO/$source" ]; then
    echo "MISSING SOURCE: $source"
    MISSING=1
  fi
done
[ "$MISSING" -eq 0 ] || { echo "FAIL: source list is stale"; exit 1; }

# Exact-string replacement that FAILS LOUDLY when the anchor is gone. A planted
# defect that silently no-ops would leave the clean code running and report a
# false "caught".
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
  local dir="$WORK/${defect:-clean}"
  rm -rf "$dir"; mkdir -p "$dir"

  local files=()
  for source in "${SOURCES[@]}"; do
    local dest="$dir/$(basename "$source")"
    cp "$REPO/$source" "$dest"
    files+=("$dest")
  done
  # The harness is top-level code, which swiftc only accepts in `main.swift`.
  cp "$REPO/$HARNESS" "$dir/main.swift"
  files+=("$dir/main.swift")

  case "$defect" in
    "")
      ;;
    drop-header)
      # The original bug: Retry-After discarded, so the wait is unknowable.
      swap "$dir/HTTPClient.swift" \
        'throw ProviderFetchError.rateLimited(retryAfter: Self.retryAfter(from: http))' \
        'throw ProviderFetchError.rateLimited(retryAfter: nil)'
      ;;
    reset-on-degraded)
      # The original bug: a limits-only failure read as a clean success.
      swap "$dir/RefreshScheduler.swift" \
        'if let limitsError = snapshot.limitsError, limitsError.isTransient {' \
        'if false, let limitsError = snapshot.limitsError, limitsError.isTransient {'
      ;;
    ignore-cooldown)
      # Cooldown armed but never enforced.
      swap "$dir/RefreshScheduler.swift" \
        'guard cooldownRemaining(id) == nil else { return }' \
        'guard true else { return }'
      ;;
    loop-only-guard)
      # The tempting half-fix: guard the loop, forget the panel's own path.
      swap "$dir/RefreshScheduler.swift" \
        'guard cooldownRemaining(id) == nil else { return }' \
        'guard cooldownRemaining(id) == nil || age > 0 else { return }'
      swap "$dir/RefreshScheduler.swift" \
        'private func refresh(_ provider: any UsageProvider) async {' \
        'private func refresh(_ provider: any UsageProvider, age: TimeInterval = 20) async {'
      ;;
    not-transient)
      # A rate limit that does not drive backoff at all.
      swap "$dir/ProviderFetchError.swift" \
        'case .network, .http, .rateLimited: true' \
        'case .network, .http: true'
      swap "$dir/ProviderFetchError.swift" \
        'case .notLoggedIn, .unauthorized, .parsing, .dataUnavailable: false' \
        'case .notLoggedIn, .unauthorized, .parsing, .dataUnavailable, .rateLimited: false'
      ;;
    trust-past-date)
      # A Retry-After in the past accepted as a cooldown.
      swap "$dir/HTTPClient.swift" \
        'return interval > 0 ? min(interval, 24 * 3600) : nil' \
        'return min(interval, 24 * 3600)'
      ;;
    *)
      echo "unknown defect: $defect"; exit 1
      ;;
  esac

  local binary="$dir/harness"
  if ! swiftc -swift-version 6 -o "$binary" "${files[@]}" > "$dir/compile.log" 2>&1; then
    if [ -z "$defect" ]; then
      echo "FAIL: clean build did not compile"
      tail -20 "$dir/compile.log"
      exit 1
    fi
    # A defect that fails to compile is still caught, loudly.
    echo "  caught (did not compile): $label"
    return 0
  fi

  set +e
  local output
  output="$("$binary" 2>&1)"
  local status=$?
  set -e

  if [ -z "$defect" ]; then
    if [ "$status" -ne 0 ] || [ "$output" != "ALL PASS" ]; then
      echo "FAIL: clean run did not pass"
      echo "$output"
      exit 1
    fi
    echo "  clean run: ALL PASS"
    return 0
  fi

  if [ "$status" -eq 0 ]; then
    echo "NOT CAUGHT: $label"
    echo "    the harness passed with this defect planted - it does not test what it claims"
    return 1
  fi
  echo "  caught: $label"
  echo "$output" | sed 's/^/      /' | head -4
  return 0
}

echo "Byte Pulse - 429 / Retry-After verifier"
echo
echo "clean sources:"
run_case "clean" ""
echo
echo "planted defects (each MUST be caught):"

UNCAUGHT=0
run_case "Retry-After header thrown away"                drop-header      || UNCAUGHT=$((UNCAUGHT + 1))
run_case "limits-only failure resets backoff"            reset-on-degraded || UNCAUGHT=$((UNCAUGHT + 1))
run_case "cooldown armed but never enforced"             ignore-cooldown  || UNCAUGHT=$((UNCAUGHT + 1))
run_case "cooldown guards the loop but not the panel"    loop-only-guard  || UNCAUGHT=$((UNCAUGHT + 1))
run_case "rate limit not treated as transient"           not-transient    || UNCAUGHT=$((UNCAUGHT + 1))
run_case "Retry-After date in the past trusted"          trust-past-date  || UNCAUGHT=$((UNCAUGHT + 1))

echo
if [ "$UNCAUGHT" -ne 0 ]; then
  echo "FAIL: $UNCAUGHT planted defect(s) went undetected"
  exit 1
fi
echo "PASS: clean sources pass and every planted defect is caught"
