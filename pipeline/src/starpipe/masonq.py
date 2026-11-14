"""starpipe's client of masond, MASON's daemon: the one arbiter of this Mac's heavy work and model sessions.

starpipe no longer schedules the machine itself. A heavy job runs under `mason run`, a model session holds `llm:claude` through
`mason hold`, and a freeze is `mason pause` plus an exclusive `mason hold` (pause.py). When masond cannot be reached nothing runs
unqueued and nothing falls back to an older queue: callers wait, say so, and alert after `ALERT_AFTER_S`.
"""

from __future__ import annotations

import contextlib
import os
import shutil
import subprocess
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Self

from . import adapter_star

ALERT_AFTER_S = 600.0  # masond unreachable this long is an alert
RETRY_S = 5.0
RETRY_MAX_S = 30.0
CLASS_FLAGS = {adapter_star.BUILD: "compile", adapter_star.TEST: "test-suite"}
LLM_CLASS = "llm:claude"


class Unreachable(RuntimeError):
    """masond did not answer."""


def binary() -> str:
    """STARPIPE_MASON, else `mason` on PATH, else the installed ~/.config/mason/bin/mason."""
    if env := os.environ.get("STARPIPE_MASON"):
        return env
    if found := shutil.which("mason"):
        return found
    return str(Path.home() / ".config" / "mason" / "bin" / "mason")


def under_mason_task() -> bool:
    return bool(os.environ.get("MASON_TASK"))


def admitted(env: Mapping[str, str] | None = None) -> str:
    """Why MASON has already admitted this process's heavy work, or "" if it has not and the job must queue.

    `MASON_HELD` names the classes MASON holds for the command it runs (a landing batch's suites set it per suite). Queueing such
    a command in masond again (`mason run`) would wait behind the slots it already holds, so it runs directly. Nothing else is
    taken as admitted: a task's test step that runs the project's `test` command (star's: no `suites = [...]` on the step) holds
    nothing in masond, and the `mason run` here is the only thing scheduling its jobs."""
    env = os.environ if env is None else env
    if held := env.get("MASON_HELD", "").strip():
        return f"MASON already holds {held} for this command"
    return ""


def run_argv(kind: str, argv: list[str], *, ticket: str = "", stage: str = "", ticket_priority: int = 9, label: str = "") -> list[str]:
    """`mason run` around argv. Under a MASON task (MASON_TASK) it is plain, so the job ranks as that task; from a ticket stage it
    ranks as starpipe's, by the ticket's priority and how far along the stage is; otherwise (a person) it names no pipeline."""
    from .heavy import PROGRESS  # heavy imports this module

    out = [binary(), "run"]
    # mason requires --needs on every run; `--exclusive` only adds the whole-machine class on top of it
    out += ["--needs", "exclusive", "--exclusive"] if kind not in CLASS_FLAGS else ["--needs", CLASS_FLAGS[kind]]
    if label:
        out += ["--label", label]
    if not under_mason_task() and ticket:
        out += ["--pipeline", "starpipe", "--priority", PRIORITY_NAMES.get(ticket_priority, "low"),
                "--progress", str(PROGRESS.get(stage, 0))]
    return [*out, "--", *argv]


PRIORITY_NAMES = {0: "urgent", 1: "high", 2: "normal", 3: "low"}  # a ticket's p0..p3


def reachable() -> bool:
    try:
        return subprocess.run([binary(), "resources", "--json"], check=False, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=30).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def _sleep(seconds: float) -> None:  # looked up at call time, so a test can replace it
    time.sleep(seconds)


def _clock() -> float:
    return time.monotonic()


def wait_reachable(report: Callable[[str], None] | None = None, alert: Callable[[str], None] | None = None, *,
                   sleep: Callable[[float], None] | None = None, clock: Callable[[], float] | None = None,
                   probe: Callable[[], bool] | None = None) -> float:
    """Return (seconds waited) once masond answers. Retries with a growing pause, says so each time, alerts once after ALERT_AFTER_S.
    Never gives up: the caller must not run its job unqueued."""
    ok = probe or reachable
    sleep, clock = sleep or _sleep, clock or _clock
    started, delay, alerted = clock(), RETRY_S, False
    while not ok():
        waited = clock() - started
        say = f"masond cannot be reached: waiting to queue ({int(waited)}s); nothing runs unqueued"
        if report:
            report(say)
        if waited >= ALERT_AFTER_S and not alerted:
            alerted = True
            if alert:
                alert(f"masond has been unreachable for {int(waited)}s: starpipe's heavy jobs and sessions are waiting")
            elif report:
                report("ALERT: " + say)
        sleep(delay)
        delay = min(delay * 2, RETRY_MAX_S)
    return clock() - started


@dataclass
class Hold:
    """`mason hold` for a process's life: started, waited on for its `granted` line, closed (stdin) to release."""
    proc: subprocess.Popen[str]
    label: str

    @classmethod
    def start(cls, needs: str | None, label: str, *, exclusive: bool = False, pipeline: str = "starpipe") -> Self:
        argv = [binary(), "hold"]
        if needs or exclusive:  # mason requires --needs; an exclusive hold names the whole-machine class
            argv += ["--needs", needs or "exclusive"]
        if exclusive:
            argv.append("--exclusive")
        argv += ["--pipeline", pipeline, "--label", label]
        proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, start_new_session=True)
        return cls(proc, label)

    def granted(self) -> bool:
        """Block until `granted` (True) or mason exits without it (False: masond went away)."""
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            if line.strip() == "granted":
                return True
        return False

    def release(self) -> None:
        with contextlib.suppress(OSError, ValueError):
            if self.proc.stdin:
                self.proc.stdin.close()
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        with contextlib.suppress(OSError, ValueError):
            if self.proc.stdout:
                self.proc.stdout.close()

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_: object) -> None:
        self.release()


def acquire(needs: str | None, label: str, *, exclusive: bool = False, report: Callable[[str], None] | None = None,
            alert: Callable[[str], None] | None = None,
            sleep: Callable[[float], None] | None = None) -> Hold:
    """A granted Hold, retrying while masond is unreachable (a hold that exits before `granted` is that)."""
    delay = RETRY_S
    sleep = sleep or _sleep
    while True:
        wait_reachable(report, alert, sleep=sleep)
        hold = Hold.start(needs, label, exclusive=exclusive)
        if hold.granted():
            return hold
        hold.release()
        if report:
            report(f"mason hold for {label} ended before it was granted: retrying")
        sleep(delay)
        delay = min(delay * 2, RETRY_MAX_S)
