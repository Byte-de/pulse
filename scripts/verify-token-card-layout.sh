#!/usr/bin/env bash
# Measures the real TokenUsageCard in an offscreen NSHostingView and fails if a
# sub-agent row is tall enough to mean its label wrapped.
#
# WHY THIS EXISTS: shipped 2026-09-01, the "↳ sub-agents" label wrapped mid-word
# ("↳ sub-" / "agents") in a 72pt label column. The card still rendered, the
# numbers were right, and nothing failed — the row was simply 33pt instead of
# 19pt, which knocked the table out of alignment with the neighbouring provider
# column. A layout defect that only shows up as a wrong *height* is exactly what
# a screenshot review misses and a measurement catches.
#
# Usage: bash scripts/verify-token-card-layout.sh
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pulse-token-card.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

SOURCES=(
  "Sources/Pulse/UI/DesignSystem/DesignSystem.swift"
  "Sources/Pulse/UI/DesignSystem/PulseIcons.swift"
  "Sources/Pulse/UI/Components/CardView.swift"
  "Sources/Pulse/UI/Panel/TokenUsageCard.swift"
  "Sources/Pulse/Core/Models/TokenUsage.swift"
  "Sources/Pulse/Core/Models/ProviderID.swift"
  "Sources/Pulse/Core/Models/Pace.swift"
  "Sources/Pulse/Core/Models/LimitWindow.swift"
  "Sources/Pulse/Core/Models/UsageSnapshot.swift"
  "Sources/Pulse/Core/Models/ProviderFetchError.swift"
  "Sources/Pulse/Core/Services/Formatters.swift"
  "Sources/Pulse/Core/Services/UsageMath.swift"
  "Sources/Pulse/Core/Services/HistoryStore.swift"
  "Sources/Pulse/Core/Services/JSONLines.swift"
  "Sources/Pulse/Core/Services/AppPaths.swift"
)

for source in "${SOURCES[@]}"; do
  [ -f "$REPO/$source" ] || { echo "FAIL: source list is stale, missing $source"; exit 1; }
done

run_case() {
  local label="$1" defect="${2:-}"
  local dir="$WORK/$label"
  mkdir -p "$dir/src"
  for source in "${SOURCES[@]}"; do
    cp "$REPO/$source" "$dir/src/$(basename "$source")"
  done
  cp "$REPO/scripts/token-card-harness.swift" "$dir/src/main.swift"

  case "$defect" in
    "") ;;
    narrow-label-column)
      # Defect: the label column exactly as it shipped — 72pt and no line
      # limit. Note both halves are needed to reproduce: at 72pt WITH
      # `.lineLimit(1)` the label truncates instead of wrapping, so the height
      # stays right and this harness (which measures height) cannot see it.
      # That is the honest limit of this check, and the reason the width, not
      # the line limit, is the actual fix.
      /usr/bin/python3 - "$dir/src/TokenUsageCard.swift" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
anchor = "labelWidth: CGFloat = 88"
if anchor not in text:
    sys.exit("defect anchor not found: %r" % anchor)
text = text.replace(anchor, "labelWidth: CGFloat = 72", 1)
text = text.replace("                .fixedSize(horizontal: true, vertical: false)\n", "", 1)
sub = '''            Text("\u21b3 sub-agents")
                .font(Typo.footer)
                .foregroundStyle(.secondary)
                .lineLimit(1)
'''
if sub not in text:
    sys.exit("defect anchor not found: sub-agent label styling")
text = text.replace(sub, sub.replace("                .lineLimit(1)\n", ""), 1)
open(path, "w").write(text)
PY
      ;;
    *) echo "unknown defect: $defect"; exit 1 ;;
  esac

  if ! swiftc -o "$dir/harness" "$dir"/src/*.swift 2>"$dir/build.log"; then
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
echo "=== planted defect ==="
DEFECT_OUTPUT="$(run_case narrow-label-column narrow-label-column)"
echo "$DEFECT_OUTPUT"
if grep -q "^ALL PASS" <<<"$DEFECT_OUTPUT"; then
  echo "FAIL: the 72pt label column went undetected"
  exit 1
fi

echo
echo "OK: card measures clean, and the wrapping label column is caught"
