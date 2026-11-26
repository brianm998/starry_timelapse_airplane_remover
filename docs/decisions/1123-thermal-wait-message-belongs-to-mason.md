# 1123 — The thermal wait message is fixed in MASON, not star

## Context
Task #1172 reports waits reading "the CPU is held to 100% of its speed for heat (work starts at 101%
or more)" while the die temperature (`thermal_max_c`) is what holds the work. star has no code that
builds this message; it belongs to MASON (brianm998/mason).

## Decision
The owner chose to file the fix in the mason project and close the star task. It is MASON task #1176.
star is not changed.

## Consequences
star #1174 describes the same fix under the star project and should not be worked separately.
