"""The machine-wide heavy-job lock (plan §9.1), split by what each job actually needs of the machine.

Why there is a lock at all: on 2026-10-23 two star runs (~20 GB and most cores each) beside test suites wedged this Mac and
logged the owner out. What has to be kept apart is narrower than "everything heavy":

- `exclusive` jobs need the machine to themselves: star/stard runs, Gherkin, UI tests (the display), test classes that read the
  whole machine or hang beside others (adapter_star.EXCLUSIVE_TEST_MARKERS), and any command not recognised.
- `test` jobs (test suites) run one at a time, so one suite's timing never depends on another suite.
- `build` jobs (compiles) share the machine with each other and with a test, up to `heavy_build_slots` at once. They used a few
  cores and under 9 GB of this 18-core, 128 GB machine (results.jsonl, 2026-10-30..11-04).

Slots are flock()ed files, which the kernel releases when the holder dies, so there are no stale locks to guess about: one `test`
slot and `heavy_build_slots` build slots; an exclusive job takes all of them. Waiters queue in locks/queue/ and are served in
order: interactive callers first, then the ticket furthest along the pipeline (PROGRESS: a landing ticket before a develop
one), then the higher-priority and older ticket, then arrival. A waiter that cannot start yet keeps the slots it needs from
everyone behind it, so a later job can pass it only by using slots it does not need: a build may pass a waiting test suite,
nothing passes a waiting exclusive job. A job that would start beside another also needs `heavy_free_mem_pct` of memory free.
It counts jobs and never reads the load average.
"""

from __future__ import annotations

import contextlib
import contextvars
import fcntl
import json
import math
import os
import signal
import subprocess
import tempfile
import threading
import time
from collections.abc import Callable, Generator
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

import psutil

from . import adapter_star
from .config import Config, home, load

INTERACTIVE, PIPELINE, NIGHTLY = 0, 1, 2
BUILD, TEST, EXCLUSIVE = adapter_star.BUILD, adapter_star.TEST, adapter_star.EXCLUSIVE
TEST_SLOT = "test"

# How far along the pipeline a stage is: further along goes first, so a ticket that is about to land is never queued behind a
# ticket that has only started developing. "verify" is the daemon's own check run after develop submits.
PROGRESS = {"explore": 0, "develop": 1, "fix": 2, "verify": 3, "review": 3, "resolve": 4, "ci-fix": 5, "conflict": 5,
            "landing": 6}
NO_TICKET_PRIORITY = 9


def locks_dir() -> Path:
    path = home() / "locks"
    (path / "queue").mkdir(parents=True, exist_ok=True)
    return path


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


@dataclass
class Waiter:
    priority: int
    enqueued_at: float
    pid: int
    started: float  # the pid's create_time, so a reused pid is not mistaken for the waiter
    ticket: str
    cmd: str
    job_class: str = EXCLUSIVE
    stage: str = ""
    ticket_priority: int = NO_TICKET_PRIORITY

    def key(self) -> tuple[int, int, int, float, float, int]:
        number = float(self.ticket) if self.ticket.isdigit() else math.inf
        return (self.priority, -PROGRESS.get(self.stage, 0), self.ticket_priority, number, self.enqueued_at, self.pid)


def _alive(pid: int, started: float) -> bool:
    try:
        return abs(psutil.Process(pid).create_time() - started) < 1.0
    except psutil.Error:
        return False


def _queue() -> list[Waiter]:
    out: list[Waiter] = []
    for entry in (locks_dir() / "queue").glob("*.json"):
        try:
            waiter = Waiter(**json.loads(entry.read_text()))
        except (OSError, ValueError, TypeError):
            continue
        if _alive(waiter.pid, waiter.started):
            out.append(waiter)
        else:
            entry.unlink(missing_ok=True)
    return sorted(out, key=Waiter.key)


@contextlib.contextmanager
def _grant_lock() -> Generator[None]:
    with (locks_dir() / "grant.flock").open("a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def _slot_file(name: str) -> Path:
    """The test slot is the file the one-slot lock used, so a worktree still running that code (a branch cut before the split)
    and this one exclude each other: its jobs wait for a test suite or an exclusive job here, and theirs hold off ours."""
    return locks_dir() / ("heavy.slot0" if name == TEST_SLOT else f"slot.{name}")


def _try_slot(name: str) -> int | None:
    fd = os.open(_slot_file(name), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except OSError:
        os.close(fd)
        return None


def _build_slots(cfg: Config) -> list[str]:
    return [f"build{i}" for i in range(max(0, cfg.heavy_build_slots))]


def _all_slots(cfg: Config) -> list[str]:
    return [TEST_SLOT, *_build_slots(cfg)]


def _free(names: list[str]) -> set[str]:
    out: set[str] = set()
    for name in names:
        fd = _try_slot(name)
        if fd is not None:
            out.add(name)
            os.close(fd)  # closing releases the probe lock
    return out


def _needs(cfg: Config, kind: str) -> list[str]:
    """Every slot this class could use. A build needs any one of the build slots; a test, the test slot; anything else, all."""
    if kind == BUILD and cfg.heavy_build_slots > 0:
        return _build_slots(cfg)
    if kind == TEST:
        return [TEST_SLOT]
    return _all_slots(cfg)


def _pick(cfg: Config, kind: str, free: set[str]) -> list[str] | None:
    needs = _needs(cfg, kind)
    if kind == BUILD and cfg.heavy_build_slots > 0:
        return next(([n] for n in needs if n in free), None)
    return needs if all(n in free for n in needs) else None


def _memory_ok(cfg: Config) -> bool:
    mem = psutil.virtual_memory()
    return mem.available / mem.total * 100 >= cfg.heavy_free_mem_pct


def _grant(cfg: Config, queue: list[Waiter], me: int, kind_of: Callable[[Waiter], str]) -> list[str] | None:
    """The slots `me` may take now, or None. Walks the queue in order handing out the free slots: a waiter ahead that can start
    is given its slots (it takes them on its next poll), one that cannot keeps the slots it needs from everyone behind it."""
    all_slots = _all_slots(cfg)
    free = _free(all_slots)
    busy = len(free) < len(all_slots)
    memory: bool | None = None
    for w in queue:
        kind = kind_of(w)
        take = _pick(cfg, kind, free)
        if take is not None and busy:  # it would start beside another job: only with memory to spare
            memory = _memory_ok(cfg) if memory is None else memory
            if not memory:
                take = None
        if take is None:
            free -= set(_needs(cfg, kind))
            if w.pid == me:
                return None
            continue
        if w.pid == me:
            return take
        free -= set(take)
        busy = True
    return None


@dataclass
class Held:
    fds: list[int]
    slots: list[str]
    waited: float
    pid: int = field(default_factory=os.getpid)


def _holder_file(pid: int) -> Path:
    return locks_dir() / f"holder.{pid}.json"


def _write_holder(pid: int, record: dict[str, Any]) -> None:
    """Atomically, so a reader never sees half a record."""
    path = _holder_file(pid)
    # A unique temp per call: jobs inside one process share a pid, so a fixed name collides.
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps(record))
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def _effective_class(cfg: Config, kind: str) -> str:
    return kind if cfg.heavy_split else EXCLUSIVE


def acquire(
    cmd: str,
    *,
    priority: int | None = None,
    config: Config | None = None,
    report: Callable[[str], None] | None = None,
    poll: float = 0.25,
    job_class: str | None = None,
) -> Held:
    cfg = config or load()
    prio = default_priority() if priority is None else priority
    kind = _effective_class(cfg, job_class or adapter_star.job_class(cmd))
    who = current_requester()
    me = psutil.Process()
    waiter = Waiter(prio, time.time(), os.getpid(), me.create_time(), who.ticket, cmd, kind, who.stage, who.ticket_priority)
    entry = locks_dir() / "queue" / f"{waiter.pid}.json"
    entry.write_text(json.dumps(asdict(waiter)))
    started, last_report = time.monotonic(), 0.0
    try:
        while True:
            with _grant_lock():
                queue = _queue()
                if not any(w.pid == waiter.pid for w in queue):  # our entry was removed from outside: put it back
                    entry.write_text(json.dumps(asdict(waiter)))
                    queue = sorted([*queue, waiter], key=Waiter.key)
                rank = next(i for i, w in enumerate(queue) if w.pid == waiter.pid)
                slots = _grant(cfg, queue, waiter.pid, lambda w: _effective_class(cfg, w.job_class))
                if slots is not None:
                    fds = [_try_slot(s) for s in slots]
                    if all(fd is not None for fd in fds):
                        entry.unlink(missing_ok=True)
                        # written under the grant lock, so the status never shows a held slot without its holder
                        _write_holder(waiter.pid, {"pid": waiter.pid, "ticket": waiter.ticket, "cmd": cmd, "since": time.time(),
                                                   "job_class": kind, "stage": waiter.stage, "slots": slots})
                        return Held([fd for fd in fds if fd is not None], slots, time.monotonic() - started)
                    for fd in fds:
                        if fd is not None:
                            os.close(fd)
            now = time.monotonic()
            if report and now - last_report >= cfg.heavy_wait_report_s:
                last_report = now
                holders = status().holders
                busy = ", ".join(f"{h.ticket or 'interactive'} {h.job_class} {h.cmd[:40]}" for h in holders) or "?"
                report(f"waiting for the heavy lock ({kind}): {busy} ({int(now - started)}s), you are #{rank + 1}")
            time.sleep(poll)
    finally:
        entry.unlink(missing_ok=True)


def release(held: Held) -> None:
    _holder_file(held.pid).unlink(missing_ok=True)
    for fd in held.fds:
        os.close(fd)


@dataclass(frozen=True)
class Hung:
    """A job that was killed because it made no progress."""
    cmd: str
    idle_s: float


@dataclass(frozen=True)
class RunResult:
    code: int
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
            self.total += max(0.0, used - self.seen.get(p.pid, 0.0))
            self.seen[p.pid] = used
            with contextlib.suppress(psutil.Error):
                rss += p.memory_info().rss
        if now > self.last_at:
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
    with contextlib.suppress(ProcessLookupError):
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
    """Wait for a slot, run argv in its own process group, release. A job idle for `heavy_idle_kill_s` is killed and
    reported as hung, so a wedged test run cannot hold the slot until the owner notices."""
    cfg = config or load()
    cmd = " ".join(argv)
    kind = EXCLUSIVE if keep_display_awake else job_class or adapter_star.job_class(cmd)  # a UI run needs the display
    held = acquire(cmd, priority=priority, config=cfg, report=report, job_class=kind)
    try:
        who = current_requester()
        record: dict[str, Any] = {"pid": held.pid, "ticket": who.ticket, "cmd": cmd, "since": time.time(),
                                  "job_class": _effective_class(cfg, kind), "stage": who.stage, "slots": held.slots}
        _write_holder(held.pid, record)
        if keep_display_awake:  # XCUITest / Compose UI freeze when the display sleeps
            argv = ["caffeinate", "-d", "-u", *argv]
        proc = subprocess.Popen(argv, process_group=0, cwd=cwd, stdout=stdout, env=env,
                                stderr=subprocess.STDOUT if stdout is not None else None)
        record["job_pid"] = proc.pid  # `pid` is the caller; this is what is running
        _write_holder(held.pid, record)

        def forward(signum: int, _frame: object) -> None:
            if proc.poll() is None:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(proc.pid, signum)

        # Signal handlers can only be set on the main thread. The daemon runs this on a worker thread, so there the child
        # is not forwarded signals; it is still never left running past the lock (see the except below).
        old = {}
        if threading.current_thread() is threading.main_thread():
            old = {s: signal.signal(s, forward) for s in (signal.SIGINT, signal.SIGTERM)}
        hung: Hung | None = None
        watch = _Activity(proc.pid, stdout, cfg.heavy_idle_kill_s)  # always: it records the hold's CPU and memory
        try:
            while True:
                try:
                    code = proc.wait(cfg.heavy_idle_poll_s)
                    break
                except subprocess.TimeoutExpired:
                    pass
                now = time.monotonic()
                watch.sample(now)
                _write_holder(held.pid, {**record, "cpu_mean": watch.cpu_mean, "cpu_peak": watch.cpu_peak,
                                          "rss_peak_mb": watch.rss_peak_mb})
                idle = watch.idle_for(now) if cfg.heavy_idle_kill_s > 0 else None
                if idle is not None:
                    hung = Hung(cmd, idle)
                    _kill_group(proc, cfg.heavy_idle_grace_s)
                    code = proc.returncode
                    break
        except BaseException:
            _kill_group(proc, 0)  # never release the lock while any of the job is still running
            raise
        finally:
            for s, h in old.items():
                signal.signal(s, h)
        code = 128 + -code if code < 0 else code
        return RunResult(code or (128 + signal.SIGTERM if hung else 0), held.waited, hung, time.monotonic() - watch.start,
                         watch.cpu_mean, watch.cpu_peak, watch.rss_peak_mb)
    finally:
        release(held)


def run(argv: list[str], **kwargs: Any) -> tuple[int, float]:
    """run_job for callers that only want (exit code, lock wait s)."""
    result = run_job(argv, **kwargs)
    return result.code, result.waited


@dataclass
class Holder:
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
class Status:
    holders: list[Holder]
    queue: list[Waiter]


def status() -> Status:
    holders: list[Holder] = []
    for path in sorted(locks_dir().glob("holder.*.json")):
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        try:
            holder = Holder(**data)
        except TypeError:
            continue
        if psutil.pid_exists(holder.pid):
            holders.append(holder)
        else:
            path.unlink(missing_ok=True)
    return Status(holders, _queue())
