# Stage: CONFLICT

`origin/develop` moved and merging it into this branch left conflicts (listed below). Resolve them in the worktree, keeping
BOTH sides' intent: every line develop added must survive unless this ticket's own change removed it. Finish the merge
commit, run `run_checks`, then `submit_change`. A mechanical audit afterwards looks for dropped landed lines: if it lists any you are called once more to restore them, and the ticket is parked if the second audit still finds some.
