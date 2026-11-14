# 0156: starpipe queues in masond

Status: accepted (task #169; owner decision 0119-5 for freeze).

Two schedulers shared this Mac: starpipe's flock slots, session cap and CPU gate, and MASON's classes. The only bridge was a
`starpipe heavy` wrapper on star's MASON suites. Now masond is the one arbiter.

- A heavy job is `mason run` (build → `compile`, test → `test-suite`, exclusive → `--exclusive`). From a ticket stage it adds
  `--pipeline starpipe --priority <ticket priority> --progress <stage>`; from a person no `--pipeline`; under `MASON_TASK` it is plain.
- A model session holds `mason hold --needs llm:claude --pipeline starpipe --label "starpipe #n stage"` from before the SDK
  session until it ends. `max_llm_sessions`, `cpu_limit_pct` and `cpu_window_s` are gone; the limit is
  `mason resources limit llm:claude N`. `load.py` is deleted.
- Unreachable masond: wait, retry, say so, alert after 10 minutes, never run unqueued, never use the old queue. Reachability is
  probed with `mason resources --json` before queueing, because `mason run` does not distinguish its own failure from the job's exit code.
- `starpipe freeze` = `mason pause --mode all` + `mason hold --exclusive --pipeline starpipe --label freeze`; `thaw` releases both.
- `.mason/mason.toml` has no wrapper; its suites ask for `test-suite`, not the nonexistent `test` class.
- A command MASON already holds slots for is not queued again: `starpipe heavy` runs it directly when `MASON_HELD` names
  classes (a landing batch's suites; masonq.admitted). Queueing it in masond would wait behind its own slots. A task's test step
  is not exempt: star's runs the project's `test` command (no `suites = [...]` on the step), holds nothing in masond, and its
  `mason run` is what schedules it.
- Not done: starpipe's idle kill of a job still works over the `mason run` tree; the SIGCONT watch of heavy jobs waits for MASON's watcher.
