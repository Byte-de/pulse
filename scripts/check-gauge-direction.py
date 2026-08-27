#!/usr/bin/env python3
"""Every UI surface that prints a limit percentage must route it through
`GaugeDirection.displayValue`.

This is a source-level check because the bug it guards is a *missing call*, not
a wrong result: the menu bar shipped rendering `Formatters.percent(utilization)`
directly, so the panel read 25% while the status item read 75% for the same
window. No amount of testing GaugeDirection in isolation can catch that - the
faulty surface never calls it.
"""
import pathlib
import re
import sys

UI = pathlib.Path("Sources/Pulse/UI")

# Surfaces that render a limit-window percentage to the user.
SURFACES = [
    "Panel/LimitGaugeCard.swift",
    "StatusBar/StatusBarLabelView.swift",
]

failures = []

# A percentage derived from `utilization` without going through the setting.
# Matches both the direct form, `percent(window.utilization)`, and the mapped
# form the menu bar used, `utilization.map(Formatters.percent)`.
RAW_DIRECT = re.compile(r"Formatters\.percent\([^)]*\butilization\b")
RAW_MAPPED = re.compile(r"\butilization\b[^\n]*\.map\(\s*Formatters\.percent")


def offends(line: str) -> bool:
    if "displayValue" in line:
        return False
    return bool(RAW_DIRECT.search(line) or RAW_MAPPED.search(line))


for rel in SURFACES:
    path = UI / rel
    if not path.exists():
        failures.append(f"{rel}: surface not found (renamed? update this check)")
        continue
    source = path.read_text()

    if "GaugeDirection" not in source:
        failures.append(f"{rel}: never mentions GaugeDirection")
        continue

    for line_no, line in enumerate(source.splitlines(), 1):
        if offends(line):
            failures.append(
                f"{rel}:{line_no}: renders raw utilization, bypassing the "
                f"direction setting -> {line.strip()}"
            )

    # And it must actually consult the setting for its displayed number.
    if "displayValue" not in source:
        failures.append(f"{rel}: never calls displayValue")

# The conversion must live in exactly one place.
store = pathlib.Path("Sources/Pulse/Core/Services/SettingsStore.swift").read_text()
if store.count("func displayValue") != 1:
    failures.append("SettingsStore: displayValue must be defined exactly once")

# The pace tick is user-controllable, so no card may hard-code it on: a gauge
# that always passes `window.elapsedFraction()` ignores the setting entirely,
# which is the same class of bug as rendering a raw utilization.
card = (UI / "Panel/LimitGaugeCard.swift").read_text()
if "showPaceMarker" not in card:
    failures.append("LimitGaugeCard: never consults showPaceMarker")
for line_no, line in enumerate(card.splitlines(), 1):
    if "paceMarker:" not in line:
        continue
    if "elapsedFraction()" in line and "showPaceMarker" not in line:
        failures.append(
            f"Panel/LimitGaugeCard.swift:{line_no}: passes elapsedFraction() "
            f"unconditionally, ignoring the pace-marker setting -> {line.strip()}"
        )

for line in failures:
    print(f"FAIL {line}")

if failures:
    print(f"FAIL: {len(failures)} surface(s) bypass the gauge direction setting")
    sys.exit(1)

print(f"PASS: all {len(SURFACES)} percentage surfaces honour the direction setting")
