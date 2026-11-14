"""Heavy jobs, queued in masond (MASON's daemon), the one arbiter of this Mac (plan §9.1, ticket #169).

Why there is a queue at all: on 2026-10-23 two star runs (~20 GB and most cores each) beside test suites wedged this Mac and
logged the owner out. starpipe no longer schedules the machine itself: every job runs under `mason run`, which queues it with
MASON's own work (masonq.py). The class decides what it asks for:

- build (compiles) -> `--needs compile`; they share the machine up to MASON's `compile` limit.
- test (suites) -> `--needs test-suite`; one at a time.
- exclusive (star/stard runs, Gherkin, UI tests, test classes that read the whole machine, any command not recognised) -> `--exclusive`.

From a ticket stage the job ranks as starpipe's (`--pipeline starpipe --priority --progress`: the ticket furthest along first);
from a person's session it names no pipeline, so it ranks as a person's; under a MASON task (`MASON_TASK`) it is a plain
`mason run`. If masond cannot be reached the job waits and retries, and never runs unqueued.
"""

from __future__ import annotations

import contextlib
import contextvars
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
from collections.abc import Callable, Generator
from dataclasses import dataclass, field
from typing import Any, cast

import psutil

from . import adapter_star, masonq
from . import idle as input_idle
from .config import Config, load

INTERACTIVE, PIPELINE, NIGHTLY = 0, 1, 2
BUILD, TEST, EXCLUSIVE = adapter_star.BUILD, adapter_star.TEST, adapter_star.EXCLUSIVE

# How far along the pipeline a stage is: further along goes first, so a ticket that is about to land is never queued behind a
# ticket that has only started developing. "verify" is the daemon's own check run after develop submits.
PROGRESS = {"explore": 0, "develop": 1, "fix": 2, "verify": 3, "review": 3, "resolve": 4, "ci-fix": 5, "conflict": 5,
            "landing": 6}
NO_TICKET_PRIORITY = 9
REQUEUE_MAX = 5  # masond dropping a queued request this many times in a row is not a blip: the job's run fails


def default_priority() -> int:
    env = os.environ
    if env.get("STARPIPE_NIGHTLY"):
        return NIGHTLY
    return PIPELINE if env.get("STARPIPE_TICKET") else INTERACTIVE


@dataclass(frozen=True)
class Requester:
    """Which ticket, in which stage, a job is for. The daemon runs many tickets' checks on worker threads of one process, so its
    environment cannot say; the engine sets this around each one (asyncio.to_thread carries it into the thread)."""
    ticket: str
    stage: str = ""
    ticket_priority: int = NO_TICKET_PRIORITY


_requester: contextvars.ContextVar[Requester | None] = contextvars.ContextVar("heavy_requester", default=None)


@contextlib.contextmanager
def requester(ticket: int | str, stage: str, ticket_priority: int = NO_TICKET_PRIORITY) -> Generator[None]:
    token = _requester.set(Requester(str(ticket), stage, ticket_priority))
    try:
        yield
    finally:
        _requester.reset(token)


def current_requester() -> Requester:
    """The engine's context if set, else the environment a stage session's Bash runs with (agent.sanitized_env)."""
    found = _requester.get()
    if found is not None:
        return found
    env = os.environ
    try:
        prio = int(env.get("STARPIPE_TICKET_PRIORITY", NO_TICKET_PRIORITY))
    except ValueError:
        prio = NO_TICKET_PRIORITY
    return Requester(env.get("STARPIPE_TICKET", ""), env.get("STARPIPE_STAGE", ""), prio)


@dataclass(frozen=True)
class Hung:
    """A job that was killed because it made no progress."""
    cmd: str
    idle_s: float


@dataclass(frozen=True)
class RunResult:
    code: int  # UI_TESTS_REFUSED when the job never started
    waited: float
    hung: Hung | None = None
    seconds: float = 0.0  # how long the job held the lock
    cpu_mean: float = 0.0  # cores: the job tree's CPU seconds over the hold
    cpu_peak: float = 0.0  # cores: the busiest interval between two samples
    rss_peak_mb: float = 0.0  # the largest sum of the tree's resident sets seen


@dataclass
class _Sample:
    at: float
    cpu: float  # cumulative CPU seconds used by the job's group, exiting children never lowering it
    log_size: int


class _Activity:
    """Judges whether a job has been idle: CPU in its whole process group, or its log growing, counts as activity."""

    def __init__(self, leader: int, log_fd: int | None, idle_s: float) -> None:
        self.leader, self.log_fd, self.idle_s = leader, log_fd, idle_s
        self.seen: dict[int, float] = {}
        self.total = 0.0
        self.samples: list[_Sample] = []
        self.start = self.last_at = time.monotonic()
        self.last_total = 0.0
        self.cpu_peak = 0.0
        self.rss_peak = 0

    def _members(self) -> list[psutil.Process]:
        return _tree(self.leader)

    @property
    def cpu_mean(self) -> float:
        return self.total / (self.last_at - self.start) if self.last_at > self.start else 0.0

    @property
    def rss_peak_mb(self) -> float:
        return self.rss_peak / (1024 * 1024)

    def sample(self, now: float) -> None:
        rss = 0
        for p in self._members():
            try:
                t = p.cpu_times()
            except psutil.Error:
                continue
            used = t.user + t.system
            if self.samples:  # the first sample is only a baseline: CPU used before the watch began is not the watch's
                self.total += max(0.0, used - self.seen.get(p.pid, 0.0))
            self.seen[p.pid] = used
            with contextlib.suppress(psutil.Error):
                rss += p.memory_info().rss
        if now - self.last_at >= 0.1:  # a shorter interval says nothing (the first sample sees all the CPU used so far at once)
            self.cpu_peak = max(self.cpu_peak, (self.total - self.last_total) / (now - self.last_at))
        self.last_at, self.last_total = now, self.total
        self.rss_peak = max(self.rss_peak, rss)
        size = 0
        if self.log_fd is not None:
            try:
                size = os.fstat(self.log_fd).st_size
            except OSError:
                pass
        self.samples.append(_Sample(now, self.total, size))
        while len(self.samples) > 1 and self.samples[1].at <= now - self.idle_s:
            self.samples.pop(0)

    def idle_for(self, now: float) -> float | None:
        """Seconds the job has been idle, once that is at least idle_s; else None."""
        first, last = self.samples[0], self.samples[-1]
        span = now - first.at
        if span < self.idle_s:
            return None
        if last.cpu - first.cpu >= 0.01 * span or last.log_size > first.log_size:
            return None
        return span


def _tree(leader: int) -> list[psutil.Process]:
    """The job's processes: the leader, all its descendants (whatever process group they moved to) and its group's members."""
    found: dict[int, psutil.Process] = {}
    try:
        root = psutil.Process(leader)
        found[root.pid] = root
        for child in root.children(recursive=True):
            found[child.pid] = child
    except psutil.Error:
        pass
    for p in psutil.process_iter():
        try:
            if p.pid not in found and os.getpgid(p.pid) == leader:
                found[p.pid] = p
        except (psutil.Error, OSError):
            continue
    return list(found.values())


def _signal_tree(leader: int, tree: list[psutil.Process], sig: signal.Signals) -> None:
    with contextlib.suppress(OSError):  # ProcessLookupError, or EPERM once macOS has reaped the group's leader
        os.killpg(leader, sig)
    for p in tree:
        with contextlib.suppress(psutil.Error, OSError):
            p.send_signal(sig)


def _running(p: psutil.Process) -> bool:
    try:
        return p.is_running() and p.status() != psutil.STATUS_ZOMBIE
    except psutil.Error:
        return False


def _kill_group(proc: subprocess.Popen[bytes], grace: float) -> None:
    """TERM then, after the grace, KILL the job's whole tree. The tree is collected first: once the leader dies its
    children are reparented and can no longer be found from it. Children in other process groups are signalled
    individually, so the lock is never released with part of the job still running."""
    tree = [p for p in _tree(proc.pid) if p.pid != proc.pid]
    if grace > 0:
        _signal_tree(proc.pid, tree, signal.SIGTERM)
        deadline = time.monotonic() + grace
        with contextlib.suppress(subprocess.TimeoutExpired):
            proc.wait(grace)
        while time.monotonic() < deadline and any(_running(p) for p in tree):
            time.sleep(0.05)
    _signal_tree(proc.pid, tree, signal.SIGKILL)  # whatever ignored the TERM, or outlived its leader
    proc.wait()


UI_TESTS_REFUSED = 69  # sysexits' EX_UNAVAILABLE, the same code pipeline/shims/xcodebuild exits with


def _job_started(proc: subprocess.Popen[bytes]) -> bool:
    """`mason run` spawns the job as its child once it holds its lease; while it queues it has none."""
    try:
        return bool(psutil.Process(proc.pid).children())
    except psutil.Error:
        return False


def run_job(
    argv: list[str],
    *,
    priority: int | None = None,
    config: Config | None = None,
    report: Callable[[str], None] | None = None,
    keep_display_awake: bool = False,
    cwd: str | None = None,
    stdout: int | None = None,
    env: dict[str, str] | None = None,
    job_class: str | None = None,
) -> RunResult:
    """Queue argv in masond (`mason run`) unless MASON already holds the machine for it (masonq.admitted), and run it in its own
    process group. A job idle for `heavy_idle_kill_s` once it runs is
    killed and reported as hung, so a wedged test run cannot hold its lease until the owner notices. `priority` is not used:
    masond ranks by who asks (see masonq.run_argv)."""
    del priority
    cfg = config or load()
    cmd = " ".join(argv)
    kind = EXCLUSIVE if keep_display_awake else job_class or adapter_star.job_class(cmd)  # a UI run needs the display
    owner_said_now = bool(os.environ.get("STARPIPE_UI_NOW")) and not os.environ.get("STARPIPE_TICKET")  # never a ticket agent's call
    gated = adapter_star.drives_display(argv) and cfg.ui_local != "always" and not owner_said_now
    if gated and cfg.ui_local == "ci":  # no wait for "idle" here: being idle is exactly when the display is asleep and must stay so
        message = (f"NOT RUN: {cmd}: UI tests (starUITests) take over this Mac's display, mouse and keyboard, so they do not run here. "
                   "GitHub's runners run them: push the change and read CI's result.")
        if report:
            report(message)
        else:
            print(message, file=sys.stderr, flush=True)
        return RunResult(UI_TESTS_REFUSED, 0.0)
    waited = 0.0
    if gated:  # before queueing: a held-back UI run must not keep a lease while it waits for the owner to go away
        waited += input_idle.wait_until_idle(cfg.ui_idle_s, poll_s=cfg.ui_idle_poll_s, report=report)
    inner = ["caffeinate", "-d", "-u", *argv] if keep_display_awake else argv  # XCUITest / Compose UI freeze when the display sleeps
    direct = masonq.admitted()  # MASON already holds the machine for this command: queueing again would wait on itself
    if direct:
        return _attempt(inner, cmd, cfg, cwd, stdout, env, direct=True, waited=waited)
    who = current_requester()
    label = f"starpipe #{who.ticket} {who.stage}".strip() if who.ticket else ""
    with tempfile.TemporaryDirectory(prefix="starpipe-job-") as scratch:
        marker = os.path.join(scratch, "started")
        # The job says it started before it execs, so a `mason run` that ends without running it (masond dropped the queued
        # request; it says so and exits 1, which is indistinguishable from the job's own status) is told apart and queued again.
        marked = ["/bin/sh", "-c", ': > "$0" && exec "$@"', marker, *inner]
        delay = masonq.RETRY_S
        drops = 0
        while True:
            waited += masonq.wait_reachable(report)  # never run unqueued
            mason = masonq.run_argv(kind, marked, ticket=who.ticket, stage=who.stage, ticket_priority=who.ticket_priority,
                                    label=label)
            result = _attempt(mason, cmd, cfg, cwd, stdout, env, direct=False, waited=waited)
            if os.path.exists(marker) or result.hung or result.code == 0 or drops >= REQUEUE_MAX:
                return result
            drops += 1
            waited = result.waited
            say = f"masond dropped the queued request before {cmd} started: queueing it again ({drops} of {REQUEUE_MAX})"
            if report:
                report(say)
            else:
                print(f"starpipe: {say}", file=sys.stderr, flush=True)
            masonq._sleep(delay)  # pyright: ignore[reportPrivateUsage]
            waited += delay
            delay = min(delay * 2, masonq.RETRY_MAX_S)


def _attempt(argv: list[str], cmd: str, cfg: Config, cwd: str | None, stdout: int | None, env: dict[str, str] | None, *,
             direct: bool, waited: float) -> RunResult:
    """One run of argv (`mason run …`, or the job itself when MASON already admitted it) in its own process group."""
    queued_at = time.monotonic()
    proc = subprocess.Popen(argv, process_group=0, cwd=cwd, stdout=stdout, env=env,
                            stderr=subprocess.STDOUT if stdout is not None else None)

    def forward(signum: int, _frame: object) -> None:
        if proc.poll() is None:
            with contextlib.suppress(OSError):
                os.killpg(proc.pid, signum)

    # Signal handlers can only be set on the main thread. The daemon runs this on a worker thread, so there the child
    # is not forwarded signals; it is still never left running (see the except below).
    old = {}
    if threading.current_thread() is threading.main_thread():
        old = {s: signal.signal(s, forward) for s in (signal.SIGINT, signal.SIGTERM)}
    hung: Hung | None = None
    watch: _Activity | None = None
    try:
        while True:
            try:
                code = proc.wait(cfg.heavy_idle_poll_s)
                break
            except subprocess.TimeoutExpired:
                pass
            if watch is None:
                if not direct and not _job_started(proc):  # still queued in masond: not idle, not running
                    continue
                waited += time.monotonic() - queued_at
                watch = _Activity(proc.pid, stdout, cfg.heavy_idle_kill_s)
            now = time.monotonic()
            watch.sample(now)
            idle = watch.idle_for(now) if cfg.heavy_idle_kill_s > 0 else None
            if idle is not None:
                hung = Hung(cmd, idle)
                _kill_group(proc, cfg.heavy_idle_grace_s)
                code = proc.returncode
                break
    except BaseException:
        _kill_group(proc, 0)  # never leave any of the job running
        raise
    finally:
        for s, h in old.items():
            signal.signal(s, h)
    if watch is None:
        waited += time.monotonic() - queued_at
    code = 128 + -code if code < 0 else code
    code = code or (128 + signal.SIGTERM if hung else 0)
    if watch is None:
        return RunResult(code, waited, hung)
    return RunResult(code, waited, hung, time.monotonic() - watch.start, watch.cpu_mean, watch.cpu_peak, watch.rss_peak_mb)


def run(argv: list[str], **kwargs: Any) -> tuple[int, float]:
    """run_job for callers that only want (exit code, lock wait s)."""
    result = run_job(argv, **kwargs)
    return result.code, result.waited


@dataclass
class Holder:
    """A lease masond holds. `pid` is 0: masond does not say whose process it is."""
    pid: int
    ticket: str
    cmd: str
    since: float
    job_pid: int = 0
    job_class: str = ""
    stage: str = ""
    slots: list[str] = field(default_factory=list[str])
    cpu_mean: float = 0.0
    cpu_peak: float = 0.0
    rss_peak_mb: float = 0.0


@dataclass
class Waiter:
    priority: int
    enqueued_at: float
    pid: int
    started: float
    ticket: str
    cmd: str
    job_class: str = EXCLUSIVE
    stage: str = ""
    ticket_priority: int = NO_TICKET_PRIORITY


@dataclass
class Status:
    holders: list[Holder]
    queue: list[Waiter]  # masond keeps the queue; `mason resources` explains every wait


def status() -> Status:
    """What masond says is held (starpipe's own leases and everyone else's); empty when it cannot be asked."""
    try:
        done = subprocess.run([masonq.binary(), "resources", "--json"], capture_output=True, text=True, timeout=10, check=False)
        data: object = json.loads(done.stdout) if done.returncode == 0 else {}
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return Status([], [])
    raw: object = cast("dict[str, Any]", data).get("holders") if isinstance(data, dict) else None
    holders: list[Holder] = []
    for item in cast("list[object]", raw) if isinstance(raw, list) else []:
        if not isinstance(item, dict):
            continue
        h = cast("dict[str, Any]", item)
        uses = cast("dict[str, Any]", h.get("uses") or {})
        label = str(h.get("label") or "")
        try:
            since = float(h.get("since_ms") or 0) / 1000
        except (TypeError, ValueError):
            since = 0.0
        holders.append(Holder(0, label if h.get("pipeline") == "starpipe" else "", label, since,
                              slots=["exclusive"] if h.get("exclusive") else [f"{k}={v}" for k, v in uses.items()]))
    return Status(holders, [])
