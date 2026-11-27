# 1179: star's landing window is 5 minutes

Task #1169.

## Problem

Over 7 days 17 of 30 landed star batches held one task. Ten of those waited exactly 20.0 minutes between
review passing and the batch forming, a third to a half of their landing time. The median first-ready wait
was 20 minutes against a 1.2 h median claim-to-land.

## Decision

`window = "5m"` in `.mason/landing.toml`, the top of the 2 to 5 minute range the task proposed: it still
lets tasks that finish review close together share a batch, and cuts the idle wait by 15 minutes.
`max_size = 10` is unchanged.

## Check afterwards

Compare `landing_idle_ms`, batch size and conflict send-backs per landed task against the 20m figures above.
If batches shrink without the idle time paying off, try 2m or a window that opens only when other tasks are
near ready.
