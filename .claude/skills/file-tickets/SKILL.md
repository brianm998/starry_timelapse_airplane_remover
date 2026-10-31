---
name: file-tickets
description: Turn an approved task list into GitHub tickets for the starpipe pipeline. Use when the owner asks to queue, file or hand off a body of work, or says "file tickets" / "send this to the pipeline".
---

# Filing tickets for the pipeline

The owner no longer writes `plans/*.md` for another agent. They approve a task list in conversation and you file it.
Design: `plans/PIPELINE.md` §6. Approval is the only gate, so do not file before it.

## Flow

1. Turn the conversation into a **numbered task list**. Each task has a title, a goal, acceptance criteria, tests and
   dependencies on other tasks.
2. **Show the list and wait for approval.** Filing applies the `pipeline` label, which is the owner's go-ahead to run.
3. Write each body to a temp file (scratchpad) and file in dependency order, noting each printed issue number:

   ```bash
   pipeline/bin/starpipe ticket lint body.md
   pipeline/bin/starpipe ticket new --title "…" --body-file body.md [--blocked-by 41,42] [--priority p1]
   ```
4. Print the issue links, then `pipeline/bin/starpipe status` once it exists.

## Body (section headers are exact)

```markdown
## Goal
## Context
## Acceptance criteria
- A1: <observable outcome> — check: <test name | command | "review: <what to look at>">
## Tests
<tests to add, or `none: <reason>`>
## Out of scope
## Pipeline
(optional) model_develop: opus · effort_develop: high · gherkin: <feature> · skip_review: no
(`model_<stage>` / `effort_<stage>` exist for explore, develop, fix, review, resolve, ci_fix and conflict; models: opus, sonnet, haiku; efforts: low, medium, high, xhigh, max)
```

- Every acceptance criterion has a `check:`. A bug's tests say "fails without the fix"; `none:` for a bug needs a real
  reason, not "visual" or "hard to test".
- **Size:** one reviewable, independently landable change, about 400 changed lines or fewer. Bigger work is several
  tickets with `--blocked-by`. Lint warns past 6 criteria.
- Put in Context what the conversation established (files, commits, numbers) so a cold agent can start.
- Filing is all or nothing per ticket: on failure the command closes what it created and says so.
- Never apply `pipeline` to something the owner has not approved, and never treat an outsider's issue as approved work.
