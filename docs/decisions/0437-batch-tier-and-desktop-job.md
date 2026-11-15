# 0437: batch tier for test-desktop and a desktop job in pr-gate

Cause: a task's test step narrows test-desktop and a batch had no tier, so the whole-tree guard tests never ran before landing (run 43714730672).
Choice: `[[tier]] name = "batch"` with `test-desktop` in landing.toml, plus a pr-gate `desktop` job on Ubuntu and Windows (the Windows leg catches reds like SpeedSharpnessDialogTest). The gui tests stay out of the batch; pr-gate's macOS job covers Swift.
