# 1137: `_kill_group` waits for the job's tree to exit

Task #1189, 2026-11-25.

## Problem

CI run 45751956625 at 6356bdb98 failed one pipeline test,
`test_an_interrupted_job_kills_children_in_other_groups` (1 failed, 582 passed). `_kill_group` in
`pipeline/src/starpipe/heavy.py` SIGKILLed the job's tree and waited only for the leader. SIGKILL is
delivered asynchronously, and a child in another process group is waited on by nobody here, so it could
still be running when `_kill_group` returned. That also broke the function's promise that the lock is
never released with part of the job still running.

## Decision

Fix the production code, not the test: after SIGKILL, `_kill_group` polls until every process it
collected has exited or is a zombie. The wait is bounded by `KILL_WAIT_S` (5 s), because a process in
uninterruptible sleep (a USB disk stall) cannot be killed until it wakes and must not hang the caller.
Past the bound `_kill_group` returns, as before.

`psutil.wait_procs` is not used: it would wait on zombies that are not our children.

## Undo

Remove the wait loop after `proc.wait()` in `_kill_group`, `KILL_WAIT_S`, and the two `test_kill_group_*`
tests.
