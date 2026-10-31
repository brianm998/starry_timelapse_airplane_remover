# Stage: DEVELOP

Implement the plan below on the current branch. Commit as you go with real messages.

- Write the tests the plan names (names must appear in the diff). For a bug, write the failing test first and see it fail.
- Call `run_checks` until everything is green at HEAD. It builds and tests only what your diff touches.
- When green, clean tree, call `submit_change`. Deviations from the plan need evidence. If gui/ and star-desktop/ changed
  one-sided, give `parity_reason`.
- If the plan is wrong, say so in `deviations` with evidence; do not silently drift from it.
