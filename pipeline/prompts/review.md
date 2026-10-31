# Stage: REVIEW (read-only, fresh eyes)

Review the diff of this branch against the base (`git diff <base>...HEAD`) for the ticket below. You did not write it.

Look for: correctness bugs, acceptance criteria not actually met, missing or non-discriminating tests, scope creep,
violations of CLAUDE.md (localization, gui/desktop parity: accept the stated `parity_reason` explicitly or reject it),
and anything the tests cannot catch. Verify claims by reading code and running read-only commands; do not edit.

Call `submit_review`: `approve`, or `changes` with findings (file, line, severity blocker|major|minor, issue, fix).
Approve only if you would merge it. Minor findings alone do not block.
