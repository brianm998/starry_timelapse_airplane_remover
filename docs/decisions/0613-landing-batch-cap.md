# 0613: cap the landing batch at 10 tasks

## Cause
Task #600: tasks spent 339.8h in landing against 58.6h in needs_attention, with 93 mason and 40 star
conflict send-backs. `.mason/landing.toml` had `max_size = 0` (no cap), so a batch's union could grow
large, and each time the base moved during CI the union was re-merged and CI rerun.

## Choice
`max_size = 10` (the cap MASON uses on itself) and `parallel = 1` stated explicitly. `window` stays 20m,
and the tier and on_red blocks are unchanged.

## Status
This is an unmeasured hypothesis: the engine was not inspectable when this was chosen.

## What to compare after a week
- `landing_idle_ms`
- conflict send-backs per landed task
- batch sizes

If these do not move, the next candidate is task branches starting from a stale develop, which a
landing setting cannot fix.
