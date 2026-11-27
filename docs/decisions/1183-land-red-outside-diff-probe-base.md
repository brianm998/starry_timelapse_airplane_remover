# 1183: a land red outside the diff is probed against the base

## Problem
#841 was red in batch test-cli from compile errors in files it never touched (a stale SwiftPM plan,
fixed by #985). Develop rounds answered "No code change" with an unchanged head, and each was tested,
reviewed and landed again. Batches 612, 614 and 627 reused the earlier red and parked within seconds.
It took 7 send-backs and about 9 hours.

## Decision
`.mason/prompts/develop.md` now tells the agent to compare the red's named files with its diff. When
none overlap it probes `origin/develop` and rebuilds with a fresh `.build`, reporting the commands and
output. If the same red returns with an unchanged head, it says so and asks for an uncached rerun.
`pipeline/tests/test_mason_prompts.py` pins those sentences.

## Not done
The replay of cached results (`reused ... run result(s) from an earlier batch`) is MASON engine
behaviour in brianm998/mason, not in this repo. A proposal was filed there.
