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

## Proposing instead of queueing

You queue a ticket (the default) only when the owner approved it in conversation. If you are an agent that was **not** given that
approval (a review, a nightly, a stage that noticed out-of-scope work, a session working on something else), file it as a proposal:

```bash
STARPIPE_AGENT="<who you are>" pipeline/bin/starpipe ticket new --propose --title "…" --body-file body.md
```

It gets `pipe:proposed` and no `pipeline` label, so nothing runs. The owner sees it with `starpipe proposals` and either
`starpipe approve 41 [--priority p1]` or `starpipe reject 41 "why"`. Every ticket records who filed it. `ticket new` refuses a title that
nearly matches an open issue (`--force` overrides) and refuses past the caps (`max_open_tickets`, `max_proposed` in config.toml); do not
work around either: if you hit a cap, the owner has plenty to look at already. This is a workflow guard, not security: everything runs
with the owner's GitHub token.

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
(optional) effort_develop: high · gherkin: <feature> · skip_review: no
(`model_<stage>` / `effort_<stage>` exist for explore, develop, fix, review, resolve, ci_fix and conflict; efforts: low, medium, high, xhigh, max)
**Leave `model_<stage>` out.** Every stage runs sonnet by default, and the daemon ignores `model_<stage>: opus` unless the owner picked it in
the monitor or ran `starpipe allow-opus <n>`. Never write opus into a ticket on your own: only when the owner has told you to.
```

- Every acceptance criterion has a `check:`. A bug's tests say "fails without the fix"; `none:` for a bug needs a real
  reason, not "visual" or "hard to test".
- **Size:** one reviewable, independently landable change, about 400 changed lines or fewer. Bigger work is several
  tickets with `--blocked-by`. Lint warns past 6 criteria.
- Put in Context what the conversation established (files, commits, numbers) so a cold agent can start.
- Filing is all or nothing per ticket: on failure the command closes what it created and says so.
- Never apply `pipeline` to something the owner has not approved, and never treat an outsider's issue as approved work.

## Carrying a plan (skips EXPLORE)

EXPLORE costs up to 45 minutes. When the conversation that produced the ticket already settled the approach **and you opened the
files you name**, add a `## Plan` section and the pipeline builds `plan.json` from it with no EXPLORE session. Leave it out otherwise:
a ticket nobody planned should go through EXPLORE, and a guessed plan is worse than none, because the pipeline only checks that each
`file:` exists and has that line, not that your claim about it is true.

```markdown
## Plan
summary: <one or two sentences>
parity: neither | both | gui-only — <reason> | desktop-only — <reason>
localization: yes | no
- approach: <step>
- file: <repo path>:<line> — <what is there and why it matters>
- risk: <risk>
```

- `summary`, `parity` and `localization` are required, with at least one `approach`. `file:` and `risk:` lines are optional but a
  `file:` line per place you looked is what makes the plan checkable. `parity` and `localization` are the two cross-client decisions
  CLAUDE.md makes mandatory (a `pipeline/` or docs-only change is `neither` / `no`).
- The criteria are your `A<n> … — check:` lines (each check becomes the plan's acceptance check). `## Pipeline` must say `gherkin:`
  explicitly, a feature list or `no`.
- `## Tests` must then be structured, one per line, or `none:`:

  ```markdown
  - <unit|daemon|cli-gherkin|ui>: <target path> <test name> — shows: A<n>[ — fails before fix]
  none: <reason>
  ```
  A bug's tests say `— fails before fix`.
- `starpipe ticket lint` checks all of this without a worktree. At claim time the same checks EXPLORE's plan has to pass run against
  the fresh worktree; if they fail, the ticket goes to EXPLORE and its prompt lists what was wrong with your plan.
- A plan is used from any ticket the owner's token filed: an interactive session, a `$STARPIPE_AGENT` filing, or an approved proposal
  (`--propose`). Only tickets the pipeline files itself (its own follow-ups) always run EXPLORE.
