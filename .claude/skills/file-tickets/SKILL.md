---
name: file-tickets
description: Turn an approved task list into MASON tasks for star. Use when the owner asks to queue, file or hand off a body of work, or says "file tickets", "file it in MASON" or "send this to the pipeline".
---

# Filing star work in MASON

The owner approves a task list in conversation and you file each task in MASON, the pipeline that explores, develops,
tests, reviews and lands work on `develop`. Approval is the only gate, so do not file before it. starpipe no longer takes
new work: never run `starpipe ticket new` (CLAUDE.md, "File every new star ticket in MASON"). `mason help filing` is
MASON's own reference.

## Flow

1. Turn the conversation into a **numbered task list**. Each task has a title, a goal, acceptance criteria, tests and
   the tasks that must land before it.
2. **Show the list and wait for approval.** A task filed without `--proposed` is queued at once, so filing is the
   go-ahead to run.
3. Write each body to a file in the scratchpad and file in dependency order. Note the number each one prints
   (`Filed task #203 in star`):

   ```bash
   ~/.config/mason/bin/mason task add "<title>" --project star --body-file body.md [--after 201,202] [--explored] [--priority high]
   ```
4. Check each task with `~/.config/mason/bin/mason task show <id>`: its state, what it waits for, and whether exploring
   was skipped and why. Then give the owner the task numbers. They follow the work in the MASON monitor, or with
   `mason status`.

- `mason task add` files the task in MASON only. No GitHub issue is opened, so don't look for one.
- `--after` takes MASON task numbers, not GitHub issue numbers.
- The title is 1 to 200 characters and the body at most 100,000 bytes. Priority is `urgent`, `high`, `normal` (the
  default) or `low`.
- Filing many tasks: render the bodies from one script, check every `file:line` you cite against `origin/develop`
  before filing, and file in dependency order so each `--after` names a task that already exists.

## Proposing instead of queueing

Queue a task only when the owner approved it in conversation. If you were not given that approval (a review, a session
working on something else, out-of-scope work you noticed), add `--proposed`. Nothing runs until the owner runs
`mason task approve <id>`, or `mason task reject <id> --reason "…"` to turn it down.

## Body

When exploring is skipped, the developing agent's plan reads "(no plan was recorded)", so the body is all it has. Write
for a cold agent that has never seen this conversation:

```markdown
## Goal
<one or two sentences: what is true once this lands>
## Context
<what the conversation established: files, commits, numbers, measurements, traps already found>
## Approach
- <step>
- <repo path>:<line> — <what is there, and what changes>
## Acceptance criteria
- A1: <observable outcome> — check: <test name | command | "review: <what to look at>">
## Tests
- <test file> <test name> — shows A1 [— fails before the fix]
## Out of scope
<what this task leaves alone, and where that work goes instead>
```

- Every acceptance criterion has a `check:`. A bug's tests fail without the fix. A bug with no test needs a real reason:
  "visual" or "hard to test" is not one.
- For every user-visible change, say what happens in both clients (`gui/` and `star-desktop/`) and in all 22
  catalogues, or why one side cannot do it. The developing and reviewing agents are given CLAUDE.md's rules, so a body
  that leaves out the twin or the translations gets a red review.
- **Size:** one reviewable change, about 400 changed lines or fewer. Bigger work is several tasks joined with `--after`.
- `## Pipeline` lines (`effort_*`, `model_*`, `gherkin:`) were starpipe's, and MASON ignores them. star's MASON runs
  every agent step on Sonnet. A bigger model is the owner's decision in `.mason/mason.toml`, never a line in a task.
- The suites that run are chosen from the diff by the impact map in `.mason/mason.toml`, not by the body.

## Skipping exploration

Exploring costs an agent session. When the conversation already settled the approach **and you opened the files you
name**, the task already is a plan: pass `--explored`, or start the body with front matter:

```markdown
---
explored: true
---
```

Leave it off otherwise. A guessed plan is worse than none, because the developing agent trusts it. If a plan turns out
not to hold up, the developing agent sends the task back to exploring: no failure is charged, but the work is wasted.

Without the flag, MASON's clarity check still skips exploring when the body has all three of:

- named files that exist on `develop`. A file you will create needs `(new)` on the same line.
- a section whose heading contains "acceptance" or "criteria", with at least one `- ` item.
- a section whose heading contains "approach", "plan", "implementation" or "how", with at least 8 words.

Traps in that check:

- Any token that looks like a file name counts as one, even inside backticks: `word.ext` with a 2 to 6 letter
  extension, or anything with a `/`. So `Config.set`, `Bundle.module`, `json.dumps`, `homography.db` or `config.json`
  make the body unclear unless that file exists on `develop` or the line says `(new)`.
- The first heading that contains "how" is read as the approach, so a `## How to test` above `## Approach` is taken
  instead.

`mason task show <id>` says whether exploring was skipped, and whether by the flag or the clarity check.
`mason task explore-anyway <id>` sends a task back to exploring.

## Moving a starpipe ticket

A ticket already filed in starpipe moves by label, not by refiling: `starpipe cancel <n>`, swap `pipeline` and any
`pipe:*` labels for `mason`, wait about a minute for the import, then `mason task approve <id>`. GitHub's "blocked by"
links come across as blockers.
