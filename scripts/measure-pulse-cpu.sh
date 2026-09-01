#!/usr/bin/env bash
#
# Pulse CPU measurement, in buckets.
#
# Reads cumulative CPU time (`ps -o time`), which cannot lie about what was
# consumed. `sample` attributes this app's cost to SwiftUI layout, which is
# where redraws land and not where they originate, so it pointed at the wrong
# thing for two sessions.
#
# Buckets, not one average: with the panel closed Pulse reads 4.3% averaged over
# a minute, which looks like a small constant leak. In 5-second buckets it is
# 0.0% idle plus one 2.6-second burst per minute - a different bug entirely.
# Always sample in buckets shorter than the period you suspect.
#
# Usage:
#   bash scripts/measure-pulse-cpu.sh [bucket_seconds] [bucket_count]
#
# To measure with the panel OPEN, launch it with BOTH flags:
#   open -a /Applications/Pulse.app --args --show-panel --pin-panel
# `--pin-panel` alone only blocks dismissal, it does NOT open the panel, and
# measuring "panel open" without `--show-panel` silently measures a closed one.
# Confirm the window is on screen before recording any number.
set -uo pipefail

BUCKET="${1:-5}"
COUNT="${2:-12}"

PID=$(pgrep -x Pulse | head -1)
if [ -z "$PID" ]; then
    echo "Pulse is not running"
    exit 1
fi

# ps prints [[dd-]hh:]mm:ss.
to_seconds() {
    echo "$1" | awk -F: '{n=NF; s=0; m=1; for (i=n; i>=1; i--) { s += $i * m; m *= 60 } print s}'
}

read_cpu() {
    to_seconds "$(ps -o time= -p "$PID" | sed 's/ //g')"
}

echo "pid $PID, ${COUNT} buckets of ${BUCKET}s"
prev=$(read_cpu)
total_start="$prev"
i=0
while [ "$i" -lt "$COUNT" ]; do
    sleep "$BUCKET"
    now=$(read_cpu)
    awk -v a="$prev" -v b="$now" -v s="$BUCKET" -v t="$(( (i + 1) * BUCKET ))" \
        'BEGIN {printf "t+%4ds  %5.2fs cpu  %5.1f%% of one core\n", t, b - a, (b - a) / s * 100}'
    prev="$now"
    i=$((i + 1))
done

awk -v a="$total_start" -v b="$prev" -v s="$(( BUCKET * COUNT ))" \
    'BEGIN {printf "\naverage over %ds: %.1f%% of one core\n", s, (b - a) / s * 100}'
