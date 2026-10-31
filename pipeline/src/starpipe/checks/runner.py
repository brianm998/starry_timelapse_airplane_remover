"""Run a plan's checks, prove each one from its own output, record it in the ledger."""

from __future__ import annotations

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


def _argv(spec: star.CheckSpec, root: Path, base: str) -> list[str]:
    return [a.format(base=base, build=build_dir(root)) for a in spec.argv]


def _run_command(spec: star.CheckSpec, root: Path, base: str, log: Path, sha: str,
                 allow_skips: bool, say: Callable[[str], None]) -> ledger.Result:
    argv = _argv(spec, root, base)
    cwd = str(root / spec.cwd)
    started = time.monotonic()
    with log.open("wb") as out:
        if spec.heavy:
            code, wait = heavy.run(argv, report=say, keep_display_awake=spec.ui, cwd=cwd, stdout=out.fileno())
        else:
            code = subprocess.run(argv, cwd=cwd, stdout=out, stderr=subprocess.STDOUT, check=False).returncode
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
    elif counts.skipped and not allow_skips:
        status = "skipped-tests"
    return ledger.Result(spec.id, status, sha, time.monotonic() - started - wait, wait, counts.executed,
                         counts.failed, counts.skipped, str(log), f"exit {code}")


def run_check(check_id: str, root: Path, base: str, log_dir: Path, *, allow_skips: bool = False,
              say: Callable[[str], None] = lambda _m: None) -> ledger.Result:
    sha = gitutil.head_sha(root)
    log = log_dir / (check_id.replace(":", "_") + ".log")
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
