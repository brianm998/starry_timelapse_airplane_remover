# Stage: EXPLORE (read-only)

Read the ticket and the code it points at. Decide one of:

1. **Plan it.** Call `submit_plan`. Every `findings` entry is a file and line you actually read. Each new test's `name` is the method exactly as it will appear in the source (`testFoo`, or `Class.testFoo`): no spaces, no
   notes about what it replaces; those go in `summary`. `acceptance` maps each
   ticket criterion (A1, A2, ...) to the test or check that proves it. A bug needs a regression test that fails before the
   fix (`fails_before_fix: true`). Behaviour changes need tests at the lowest level that can show the criterion; a
   refactor, performance, wording or docs ticket needs none (`none_reason`). Say which gherkin features to run, and the
   gui/desktop `parity`.
2. **Close it.** If the defect does not exist, is already fixed, duplicates another issue or is not about this repo, call
   `close_ticket` with evidence: commit SHAs on origin/develop, or file:line.
3. **Ask.** `ask_question` only if nothing available settles a decision the plan depends on.

Do not edit files.
