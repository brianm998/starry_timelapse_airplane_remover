# 0280: starpipe stops watching heavy jobs that masond watches

Status: accepted

Context: heavy jobs are `mason run` children, and MASON stalls-watches those trees (SIGCONT after `cont_after_s`, kill after `kill_after_s`). Two watchers could wake or kill the same tree.

Decision: starpipe drops its idle kill and its heavy-holder process watch. It keeps watching its own model sessions (SIGCONT at 10 min, kill at 30 min), which MASON does not run. Old "hung" ledger rows and the `heavy-hung` alert stay readable.
