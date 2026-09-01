#!/usr/bin/env bash
#
# Meta-test for scripts/check-timeline-animation.py.
#
# A verifier that has never failed proves nothing, so this plants the exact
# defect that cost 34% of a core (plus near-miss variants) and requires the
# checker to catch each one, then to pass again once reverted.
#
# Run: bash scripts/verify-timeline-animation.sh
set -uo pipefail
cd "$(dirname "$0")/.."

CHECK="scripts/check-timeline-animation.py"
TARGET="Sources/Pulse/UI/Panel/PanelFooter.swift"
BACKUP="/tmp/PanelFooter.metatest.$$"
FAILURES=0

cleanup() {
    if [ -f "$BACKUP" ]; then
        cp "$BACKUP" "$TARGET"
        mv "$BACKUP" "$BACKUP.used" 2>/dev/null || true
    fi
}
trap cleanup EXIT

cp "$TARGET" "$BACKUP"

# Baseline: the real tree must pass, or every planted case below is meaningless.
if ! python3 "$CHECK" >/dev/null 2>&1; then
    echo "FAIL baseline: the checker does not pass on the current tree"
    python3 "$CHECK"
    exit 1
fi
echo "ok   baseline passes"

# Each case: a description, and the line inserted into the footer's TimelineView.
# MUST-CATCH cases restart an animation on every tick.
must_catch=(
'the exact shipped bug|.animation(Motion.numberTick, value: statusText(now: context.date))'
'animating context.date itself|.animation(Motion.numberTick, value: context.date)'
'a different animation curve|.animation(.easeInOut(duration: 1), value: statusText(now: context.date))'
'wrapped onto the next line|.animation(Motion.numberTick,
                            value: statusText(now: context.date))'
'derived through another call|.animation(Motion.numberTick, value: Formatters.relativeAge(of: .now, now: context.date))'
)

# MUST-PASS cases: animations inside the same TimelineView that do NOT key off
# the clock, so they start only when real data changes. Flagging these would
# make the rule useless noise.
must_pass=(
'a constant-ish enum value|.animation(Motion.staleTint, value: manualPhase)'
'documented exception|.animation(Motion.numberTick, value: statusText(now: context.date)) // timeline-animation-ok: one-shot, verified'
)

plant() {
    python3 - "$TARGET" "$1" <<'PY'
import sys
path, inserted = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines(keepends=True)
anchor = next(i for i, l in enumerate(lines) if ".contentTransition(.numericText())" in l)
indent = " " * (len(lines[anchor]) - len(lines[anchor].lstrip()))
block = "".join(indent + part + "\n" for part in inserted.split("\n"))
lines.insert(anchor + 1, block)
open(path, "w").write("".join(lines))
PY
}

for case in "${must_catch[@]}"; do
    desc="${case%%|*}"; line="${case#*|}"
    cp "$BACKUP" "$TARGET"
    plant "$line"
    if python3 "$CHECK" >/dev/null 2>&1; then
        echo "FAIL missed:  $desc"
        FAILURES=$((FAILURES + 1))
    else
        echo "ok   caught:  $desc"
    fi
done

for case in "${must_pass[@]}"; do
    desc="${case%%|*}"; line="${case#*|}"
    cp "$BACKUP" "$TARGET"
    plant "$line"
    if python3 "$CHECK" >/dev/null 2>&1; then
        echo "ok   allowed: $desc"
    else
        echo "FAIL false positive on: $desc"
        FAILURES=$((FAILURES + 1))
    fi
done

# And it must pass again once the tree is restored, proving the failures above
# came from the planted line and not from a checker left in a broken state.
cp "$BACKUP" "$TARGET"
if python3 "$CHECK" >/dev/null 2>&1; then
    echo "ok   passes again after revert"
else
    echo "FAIL does not pass after revert"
    FAILURES=$((FAILURES + 1))
fi

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "FAIL: $FAILURES meta-test case(s) failed"
    exit 1
fi
echo "PASS: ${#must_catch[@]} planted defect(s) caught, ${#must_pass[@]} legitimate case(s) allowed"
