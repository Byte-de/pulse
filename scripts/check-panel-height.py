#!/usr/bin/env python3
"""Guards the panel's self-sizing against the Spacer defect.

WHAT BROKE (observed 2026-09-01, screenshot from the running app): the panel
opened at full screen height with ~700pt of dead space between the last card and
the footer, and never shrank back.

WHY: PanelController resizes the window to the height SwiftUI reports for the
panel's content tree. A *vertical* Spacer in a measured (non-scrolled) VStack
expands to the height it is proposed - which is the current window height - so
the reported height equals the window height and the window keeps whatever size
it once grew to. Measured with an offscreen NSHostingView: 338pt of real content
reported as 560 in a 560pt window and 1200 in a 1200pt window; with the Spacer
removed, 338 in both.

Two kinds of Spacer are deliberately NOT flagged, because neither can do this:
  - a Spacer inside an HStack pushes horizontally;
  - a Spacer anywhere inside a ScrollView is proposed an unbounded height and
    collapses to its minimum (verified the same way), which is why
    `columnArea`'s per-column Spacers are fine.

Usage: python3 scripts/check-panel-height.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Files whose view tree is measured rather than scrolled.
MEASURED_VIEWS = [
    ("Sources/Pulse/UI/System/SystemColumn.swift", "machine-stats sidebar"),
    ("Sources/Pulse/UI/Panel/PanelRootView.swift", "panel content tree"),
]

CONTAINER = re.compile(r"\b(VStack|HStack|ZStack|ScrollView|LazyVStack|LazyHStack)\b[^\n{]*\{")


def containers(text: str) -> list[tuple[str, int, int]]:
    """(kind, start, end) for every container body, brace-matched."""
    found = []
    for match in CONTAINER.finditer(text):
        brace = text.index("{", match.end() - 1)
        depth = 0
        index = brace
        while index < len(text):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    found.append((match.group(1), brace, index))
                    break
            index += 1
    return found


failures: list[str] = []

for relative, description in MEASURED_VIEWS:
    path = ROOT / relative
    if not path.exists():
        failures.append(f"{relative}: missing (check script is stale)")
        continue

    text = path.read_text()
    blocks = containers(text)
    for match in re.finditer(r"\bSpacer\(", text):
        position = match.start()
        enclosing = [block for block in blocks if block[1] < position < block[2]]
        if not enclosing:
            continue
        if any(kind == "ScrollView" for kind, _, _ in enclosing):
            continue  # unbounded proposal: collapses to its minimum
        # Innermost container decides the axis the Spacer grows along.
        kind, _, _ = max(enclosing, key=lambda block: block[1])
        if kind not in {"VStack", "LazyVStack"}:
            continue
        line = text[:position].count("\n") + 1
        failures.append(
            f"{relative}:{line}: vertical Spacer in the {description}, outside any ScrollView. "
            "It expands to the window height, so the panel stops shrinking. "
            "Rely on HStack(alignment: .top) instead."
        )

if failures:
    print("FAIL: panel height guard")
    for failure in failures:
        print(f"  {failure}")
    sys.exit(1)

print(f"OK: no measured panel column carries a stretching Spacer ({len(MEASURED_VIEWS)} files checked)")
