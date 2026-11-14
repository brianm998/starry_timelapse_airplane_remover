# 0309: the gui build wrapper links the artifacts

Cause: ledger worktrees skip the `setup` step, so the gitignored OpenCV, StarDecisionTrees, gui/videos and external_binaries/bin links are missing and build-gui fails (task #331).

Choice: `.mason/scripts/xcodebuild-signed.sh` runs the idempotent `link-artifacts.sh` before xcodebuild, non-fatally, so the ledger and the test step behave the same.

Follow-up for MASON: the ledger could also run the project's setup step.
