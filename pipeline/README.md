# starpipe

The automated development pipeline for star. The design and the owner's decisions are in
[plans/PIPELINE.md](../plans/PIPELINE.md); read that first. Built so far: Phase 1.

```bash
pipeline/bin/starpipe doctor                          # prerequisites and tools
pipeline/bin/starpipe check --explain                 # which builds/tests this change needs, and why
pipeline/bin/starpipe check [--tier t0|t1]            # run them; each verdict is proven from the run's own output
pipeline/bin/starpipe heavy -- swift test ...         # the machine-wide heavy-job lock
pipeline/bin/starpipe heavy --status                  # who holds it, who waits
```

Development (needs `uv`):

```bash
cd pipeline && uv sync && uv run pytest -q && uv run ruff check . && uv run pyright
```

- `src/starpipe/adapter_star.py` is the only module that names star paths and tools.
- State is in `~/.star-pipeline/` (`STARPIPE_HOME` overrides it): `locks/`, `results.jsonl` (the results
  ledger), `checks/<sha>/` (logs), `build/<worktree>/` (DerivedData).
- `hooks/heavy_wrap.py` is the interactive-session hook wired in `.claude/settings.json`.
