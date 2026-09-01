#!/usr/bin/env python3
"""No `.animation(_:value:)` on a value that changes on every TimelineView tick.

The bug this guards cost 34% of a core with the panel open, and three sessions
blamed the wrong thing first (the `ps` spawn, the disk call, SwiftUI layout, the
machine sidebar). The actual cause was ONE modifier:

    TimelineView(.periodic(from: .now, by: 1)) { context in
        Text(statusText(now: context.date))
            .contentTransition(.numericText())
            .animation(Motion.numberTick, value: statusText(now: context.date))

`.animation(_:value:)` starts an animation whenever `value` changes. Here the
value is a string derived from `context.date`, so it changes on EVERY tick: the
animation never finishes before the next one starts, and a permanently in-flight
animation makes SwiftUI redraw that layer tree at DISPLAY rate (60-120 Hz)
instead of once per tick.

The distinction is the whole rule, and it is why this check looks at `value:`
rather than at `.animation` alone. Six lines above the offending one, the same
file animates `value: staleness.level` inside the same TimelineView and costs
nothing measurable - that enum stays constant for minutes, so no animation
starts. Verified by measurement, not by reading: removing only the string
animation took the panel from 34% to 0.4%.

`contentTransition(.numericText())` still animates the digit change on its own,
driven by the text actually changing, so dropping `.animation` costs nothing
visually.

Measured on an M4, panel open, machine sidebar off:
  with the modifier     34.0% of one core, steady
  without it             0.3% of one core, steady
And the same bug at 3-second cadence in SystemColumn: 10% -> 3%.

Why a source check and not a test: the cost is invisible to any unit test and
appears only as CPU time in a running, rendering app. A source rule is the only
form of this that can run in CI.

Escape hatch: `// timeline-animation-ok: <reason>` on the `.animation` line.
"""
import pathlib
import re
import sys

UI = pathlib.Path("Sources/Pulse/UI")

TIMELINE = re.compile(r"TimelineView\s*\(\s*\.periodic")
# `.animation(<anim>, value: <expr>)`, capturing the value expression. The
# value may run onto following lines, so the caller joins the body first.
ANIMATION_VALUE = re.compile(r"\.animation\s*\([^,]*,\s*value:\s*([^)]*(?:\([^)]*\))?[^)]*)\)")
OK = "timeline-animation-ok"


def leading_spaces(line: str) -> int:
    return len(line) - len(line.lstrip())


def timeline_bodies(lines: list[str]) -> list[tuple[int, list[str]]]:
    """(start_line_no, body_lines) for each periodic TimelineView.

    Scope is tracked by indentation rather than brace matching: SwiftUI bodies
    are consistently indented, and a brace counter trips over string literals
    and nested closures for no benefit here.
    """
    bodies = []
    current = None
    for index, line in enumerate(lines):
        stripped = line.strip()
        if TIMELINE.search(line):
            if current:
                bodies.append(current)
            current = (index + 1, leading_spaces(line), [])
            continue
        if current is None or not stripped:
            continue
        start, depth, collected = current
        if leading_spaces(line) <= depth and not stripped.startswith((")", "}", "]")):
            bodies.append(current)
            current = None
            continue
        collected.append(line)
    if current:
        bodies.append(current)
    return [(start, collected) for start, _, collected in bodies]


def offends(value_expr: str) -> bool:
    """True when the animated value is derived from the timeline's clock.

    Anything reading `context.date` recomputes every tick by construction, so
    the animation restarts every tick. A value that does not read the clock may
    still change, but only when real data changes, which is the intended case.
    """
    return "context.date" in value_expr


failures = []
scanned = 0
for path in sorted(UI.rglob("*.swift")):
    scanned += 1
    lines = path.read_text().splitlines()
    for start, body in timeline_bodies(lines):
        for offset, line in enumerate(body):
            if line.strip().startswith("//") or OK in line:
                continue
            if ".animation" not in line:
                continue
            # Join a few following lines so a wrapped `value:` is still seen.
            window = " ".join(l.strip() for l in body[offset:offset + 4])
            match = ANIMATION_VALUE.search(window)
            if not match or not offends(match.group(1)):
                continue
            rel = path.relative_to(UI)
            failures.append(
                f"{rel}: `.animation` on a value derived from context.date, "
                f"inside the TimelineView opened at line {start}. It restarts "
                f"every tick and redraws at display rate (34% of a core when "
                f"this shipped) -> {line.strip()}"
            )

for line in failures:
    print(f"FAIL {line}")

if failures:
    print(f"FAIL: {len(failures)} per-tick animation(s) inside a periodic TimelineView")
    sys.exit(1)

print(f"PASS: {scanned} view file(s), no animation restarts on every timeline tick")
