"""The machine-wide heavy-job lock (plan §9.1): one build / test suite / star run at a time.

Slots are flock()ed files, which the kernel releases when the holder dies, so there are no stale
locks to guess about. Waiters queue in locks/queue/; the head of the queue (lowest priority number,
then oldest) takes the next free slot. It counts jobs and never reads the load average.
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import signal
import subprocess
import threading
import time
from collections.abc import Callable, Generator
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import psutil

from .config import Config, home, load

INTERACTIVE, PIPELINE, NIGHTLY = 0, 1, 2


def locks_dir() -> Path:
    path = home() / "locks"
    (path / "queue").mkdir(parents=True, exist_ok=True)
    return path


def default_priority() -> int:
    env = os.environ
    if env.get("STARPIPE_NIGHTLY"):
        return NIGHTLY
    return PIPELINE if env.get("STARPIPE_TICKET") else INTERACTIVE


@dataclass
class Waiter:
    priority: int
    enqueued_at: float
    pid: int
    started: float  # the pid's create_time, so a reused pid is not mistaken for the waiter
    ticket: str
    cmd: str

    def key(self) -> tuple[int, float, int]:
        return (self.priority, self.enqueued_at, self.pid)


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


def _try_slot(index: int) -> int | None:
    fd = os.open(locks_dir() / f"heavy.slot{index}", os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except OSError:
        os.close(fd)
        return None


def _free_slots(slots: int) -> int:
    free = 0
    for i in range(slots):
        fd = _try_slot(i)
        if fd is not None:
            free += 1
            os.close(fd)  # closing releases the probe lock
    return free


@dataclass
class Held:
    fd: int
    slot: int
    waited: float


def acquire(
    cmd: str,
    *,
    priority: int | None = None,
    config: Config | None = None,
    report: Callable[[str], None] | None = None,
    poll: float = 0.25,
) -> Held:
    cfg = config or load()
    prio = default_priority() if priority is None else priority
    me = psutil.Process()
    waiter = Waiter(prio, time.time(), os.getpid(), me.create_time(),
                    os.environ.get("STARPIPE_TICKET", ""), cmd)
    entry = locks_dir() / "queue" / f"{waiter.pid}.json"
    entry.write_text(json.dumps(asdict(waiter)))
    started, last_report = time.monotonic(), 0.0
    try:
        while True:
            with _grant_lock():
                queue = _queue()
                rank = next((i for i, w in enumerate(queue) if w.pid == waiter.pid), 0)
                if rank < _free_slots(cfg.heavy_slots):
                    for i in range(cfg.heavy_slots):
                        fd = _try_slot(i)
                        if fd is not None:
                            entry.unlink(missing_ok=True)
                            return Held(fd, i, time.monotonic() - started)
            now = time.monotonic()
            if report and now - last_report >= cfg.heavy_wait_report_s:
                last_report = now
                holders = status().holders
                who = f"{holders[0].ticket or 'interactive'} {holders[0].cmd[:60]}" if holders else "?"
                report(f"waiting for heavy lock: {who} ({int(now - started)}s), you are #{rank + 1}")
            time.sleep(poll)
    finally:
        entry.unlink(missing_ok=True)


def _holder_file(slot: int) -> Path:
    return locks_dir() / f"holder.{slot}.json"


def release(held: Held) -> None:
    _holder_file(held.slot).unlink(missing_ok=True)
    os.close(held.fd)


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

    def _members(self) -> list[psutil.Process]:
        return _tree(self.leader)

    def sample(self, now: float) -> None:
        for p in self._members():
            try:
                t = p.cpu_times()
            except psutil.Error:
                continue
            used = t.user + t.system
            self.total += max(0.0, used - self.seen.get(p.pid, 0.0))
            self.seen[p.pid] = used
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
) -> RunResult:
    """Wait for a slot, run argv in its own process group, release. A job idle for `heavy_idle_kill_s` is killed and
    reported as hung, so a wedged test run cannot hold the slot until the owner notices."""
    cfg = config or load()
    cmd = " ".join(argv)
    held = acquire(cmd, priority=priority, config=cfg, report=report)
    try:
        holder = _holder_file(held.slot)
        record = {"pid": os.getpid(), "ticket": os.environ.get("STARPIPE_TICKET", ""), "cmd": cmd, "since": time.time()}
        holder.write_text(json.dumps(record))
        if keep_display_awake:  # XCUITest / Compose UI freeze when the display sleeps
            argv = ["caffeinate", "-d", "-u", *argv]
        proc = subprocess.Popen(argv, process_group=0, cwd=cwd, stdout=stdout, env=env,
                                stderr=subprocess.STDOUT if stdout is not None else None)
        holder.write_text(json.dumps({**record, "job_pid": proc.pid}))  # `pid` is the caller; this is what is running

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
        try:
            watch = _Activity(proc.pid, stdout, cfg.heavy_idle_kill_s) if cfg.heavy_idle_kill_s > 0 else None
            while True:
                try:
                    code = proc.wait(cfg.heavy_idle_poll_s if watch else None)
                    break
                except subprocess.TimeoutExpired:
                    pass
                assert watch is not None
                now = time.monotonic()
                watch.sample(now)
                idle = watch.idle_for(now)
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
        return RunResult(code or (128 + signal.SIGTERM if hung else 0), held.waited, hung)
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
    return Status(holders, _queue())
