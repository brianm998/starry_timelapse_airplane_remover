"""Run a plan's checks, prove each one from its own output, record it in the ledger."""

from __future__ import annotations

import os
import subprocess
import time
from collections.abc import Callable
from pathlib import Path

from .. import adapter_star as star
from .. import gitutil, heavy
from ..config import home, load
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


def _argv(spec: star.CheckSpec, root: Path, base: str, log_dir: Path | None = None, *, serial: bool = False) -> list[str]:
    return _format(spec.serial_argv if serial else spec.argv, root, base, log_dir or home() / "checks")


def _format(argv: tuple[str, ...], root: Path, base: str, log_dir: Path) -> list[str]:
    mergebase = _merge_base(root, base) if any("{mergebase}" in a for a in argv) else base
    return [a.format(base=base, mergebase=mergebase, build=build_dir(root), log_dir=log_dir,
                     workers=load().heavy_test_workers) for a in argv]


def _run_argv(spec: star.CheckSpec, argv: list[str], root: Path, log: Path, say: Callable[[str], None],
              priority: int | None) -> heavy.RunResult:
    """One process of a check: exit code, seconds waiting for the lock, hung, and what it used of the machine."""
    cwd = str(root / spec.cwd)
    env = {**os.environ, **{k: v.format(root=root, build=build_dir(root)) for k, v in spec.env}} if spec.env else None
    with log.open("wb") as out:
        if spec.heavy:
            return heavy.run_job(argv, report=say, keep_display_awake=spec.ui, cwd=cwd, stdout=out.fileno(),
                                 priority=priority, env=env)
        code = subprocess.run(argv, cwd=cwd, stdout=out, stderr=subprocess.STDOUT, check=False, env=env).returncode
        return heavy.RunResult(code, 0.0)


def _combine(a: heavy.RunResult, b: heavy.RunResult) -> heavy.RunResult:
    """Two passes of one check as one hold: the mean is weighted by how long each held the lock."""
    seconds = a.seconds + b.seconds
    mean = (a.cpu_mean * a.seconds + b.cpu_mean * b.seconds) / seconds if seconds else 0.0
    return heavy.RunResult(a.code or b.code, a.waited + b.waited, b.hung or a.hung, seconds, mean,
                           max(a.cpu_peak, b.cpu_peak), max(a.rss_peak_mb, b.rss_peak_mb))


def _run_command(spec: star.CheckSpec, root: Path, base: str, log: Path, sha: str,
                 allow_skips: bool, say: Callable[[str], None], priority: int | None = None) -> ledger.Result:
    started = time.monotonic()
    for xml in spec.xunit:  # a file left by an earlier run of this commit must not stand in for this run's
        Path(_format((xml,), root, base, log.parent)[0]).unlink(missing_ok=True)
    job = _run_argv(spec, _argv(spec, root, base, log.parent), root, log, say, priority)
    code, wait, hung = job.code, job.waited, job.hung
    if spec.serial_argv and not hung:  # the classes the parallel pass skipped, alone on the machine
        serial_log = log.with_name(log.stem + ".serial.log")
        serial = _run_argv(spec, _argv(spec, root, base, log.parent, serial=True), root, serial_log, say, priority)
        hung = serial.hung
        code, wait = code or serial.code, wait + serial.waited
        log = serial_log if serial.code else log
        job = _combine(job, serial)
    if hung:
        return ledger.Result(spec.id, "hung", sha, time.monotonic() - started - wait, wait, log=str(log),
                             detail=f"hung: `{hung.cmd}` made no progress for {hung.idle_s:.0f}s and was killed; the lock is "
                                    "free. This is not a failure of your change: rerun run_checks",
                             cpu_mean=job.cpu_mean, cpu_peak=job.cpu_peak, rss_peak_mb=job.rss_peak_mb)
    text = log.read_text(errors="replace")
    counts = parsers.Counts()
    if spec.parser == "xunit":
        for xml in spec.xunit:
            path = Path(_format((xml,), root, base, log.parent)[0])
            if path.exists() or not path.name.endswith("-swift-testing.xml"):  # that one is written only when swift-testing ran
                counts += parsers.parse_xunit(path)
    elif spec.parser == "xctest":
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
    detail = f"exit {code}"
    if counts.failures:
        shown = ", ".join(counts.failures[:10]) + (f" and {len(counts.failures) - 10} more" if len(counts.failures) > 10 else "")
        detail += f"; failed: {shown}"
    return ledger.Result(spec.id, status, sha, time.monotonic() - started - wait, wait, counts.executed,
                         counts.failed, counts.skipped, str(log), detail, failures=counts.failures,
                         cpu_mean=job.cpu_mean, cpu_peak=job.cpu_peak, rss_peak_mb=job.rss_peak_mb)


def log_name(check_id: str) -> str:
    """A check id as a file name: `build:pipeline/monitor` must not become a nested path."""
    return star.log_stem(check_id)


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
        if not result.green and check_id.startswith(("build:", "t0:")):
            break  # a red build's tests could not run and a red t0 is cheap to fix first; a red test check does not hide the others
    return results


def _line(r: ledger.Result) -> str:
    counts = f"  {r.executed} tests, {r.failed} failed, {r.skipped} skipped" if r.executed or r.failed else ""
    wait = f" (+{r.lock_wait:.0f}s lock wait)" if r.lock_wait >= 1 else ""
    tail = "" if r.green else f"  {r.detail}  log: {r.log}"
    return f"{'PASS' if r.green else r.status.upper():<13}{r.check:<22}{r.seconds:6.0f}s{wait}{counts}{tail}"
