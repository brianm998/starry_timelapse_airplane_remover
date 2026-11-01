"""Run a plan's checks, prove each one from its own output, record it in the ledger."""

from __future__ import annotations

import os
import subprocess
import time
from collections.abc import Callable
from pathlib import Path

from .. import adapter_star as star
from .. import gitutil, heavy
from ..config import home
from . import impact, ledger, parsers, t0


def build_dir(root: Path) -> Path:
    path = home() / "build" / root.name
    path.mkdir(parents=True, exist_ok=True)
    return path


def _merge_base(root: Path, base: str) -> str:
    """Where this branch left `base`. Diffing against the moving tip instead (as `git diff <tip>` does) shows what landed on the
    base since as this branch's own reversed lines, so a ticket was failed for whitespace in someone else's change (#59)."""
    out = subprocess.run(["git", "merge-base", base, "HEAD"], cwd=root, capture_output=True, text=True, check=False)
    return out.stdout.strip() or base


def _argv(spec: star.CheckSpec, root: Path, base: str) -> list[str]:
    mergebase = _merge_base(root, base) if any("{mergebase}" in a for a in spec.argv) else base
    return [a.format(base=base, mergebase=mergebase, build=build_dir(root)) for a in spec.argv]


def _run_command(spec: star.CheckSpec, root: Path, base: str, log: Path, sha: str,
                 allow_skips: bool, say: Callable[[str], None], priority: int | None = None) -> ledger.Result:
    argv = _argv(spec, root, base)
    cwd = str(root / spec.cwd)
    env = {**os.environ, **{k: v.format(root=root, build=build_dir(root)) for k, v in spec.env}} if spec.env else None
    started = time.monotonic()
    with log.open("wb") as out:
        if spec.heavy:
            code, wait = heavy.run(argv, report=say, keep_display_awake=spec.ui, cwd=cwd, stdout=out.fileno(),
                                   priority=priority, env=env)
        else:
            code = subprocess.run(argv, cwd=cwd, stdout=out, stderr=subprocess.STDOUT, check=False, env=env).returncode
            wait = 0.0
    text = log.read_text(errors="replace")
    counts = parsers.Counts()
    if spec.parser == "xctest":
        counts = parsers.parse_xctest(text)
    elif spec.parser == "pytest":
        counts = parsers.parse_pytest(text)
    elif spec.parser == "gradle" and spec.results_glob:
        counts = parsers.parse_gradle(root / spec.cwd / spec.results_glob)
    status = "pass"
    if code != 0 or counts.failed:
        status = "fail"
    elif spec.parser != "exit" and counts.vacuous:
        status = "vacuous"  # exit 0 and a green banner, but nothing ran
    elif spec.expect is not None and counts.executed != spec.expect:
        status = "partial"  # some of the expected tests did not run
    elif counts.skipped and not allow_skips:
        status = "skipped-tests"
    return ledger.Result(spec.id, status, sha, time.monotonic() - started - wait, wait, counts.executed,
                         counts.failed, counts.skipped, str(log), f"exit {code}")


def log_name(check_id: str) -> str:
    """A check id as a file name: `build:pipeline/monitor` must not become a nested path."""
    return check_id.replace(":", "_").replace("/", "_")


def run_spec(spec: star.CheckSpec, root: Path, base: str, log_dir: Path, *, priority: int | None = None,
             allow_skips: bool = False, say: Callable[[str], None] = lambda _m: None) -> ledger.Result:
    """Run one check that is not in the impact map's CHECKS (the nightly's own), recorded in the ledger like any other."""
    sha = gitutil.head_sha(root)
    log = log_dir / (log_name(spec.id) + ".log")
    result = _run_command(spec, root, base, log, sha, allow_skips, say, priority)
    ledger.record(result)
    return result


def run_check(check_id: str, root: Path, base: str, log_dir: Path, *, allow_skips: bool = False,
              say: Callable[[str], None] = lambda _m: None) -> ledger.Result:
    sha = gitutil.head_sha(root)
    log = log_dir / (log_name(check_id) + ".log")
    if check_id in ("t0:artifacts", "t0:i18n"):
        started = time.monotonic()
        ok, detail = (t0.artifacts if check_id == "t0:artifacts" else t0.i18n)(root, base)
        log.write_text(detail + "\n")
        result = ledger.Result(check_id, "pass" if ok else "fail", sha, time.monotonic() - started,
                               log=str(log), detail=detail)
    else:
        result = _run_command(star.CHECKS[check_id], root, base, log, sha, allow_skips, say)
    ledger.record(result)
    return result


def run_plan(plan: impact.Plan, root: Path, base: str, tiers: set[str], *, allow_skips: bool = False,
             say: Callable[[str], None] = lambda _m: None) -> list[ledger.Result]:
    ids = ([*plan.t0] if "t0" in tiers else []) + (plan.t1() if "t1" in tiers else [])
    log_dir = home() / "checks" / gitutil.head_sha(root)[:12]
    log_dir.mkdir(parents=True, exist_ok=True)
    results: list[ledger.Result] = []
    for check_id in ids:
        say(f"running {check_id}")
        result = run_check(check_id, root, base, log_dir, allow_skips=allow_skips, say=say)
        results.append(result)
        say(_line(result))
        if not result.green:
            break  # a red stops the rest: later checks would only bury it
    return results


def _line(r: ledger.Result) -> str:
    counts = f"  {r.executed} tests, {r.failed} failed, {r.skipped} skipped" if r.executed or r.failed else ""
    wait = f" (+{r.lock_wait:.0f}s lock wait)" if r.lock_wait >= 1 else ""
    tail = "" if r.green else f"  {r.detail}  log: {r.log}"
    return f"{'PASS' if r.green else r.status.upper():<13}{r.check:<22}{r.seconds:6.0f}s{wait}{counts}{tail}"
