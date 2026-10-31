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


def run(
    argv: list[str],
    *,
    priority: int | None = None,
    config: Config | None = None,
    report: Callable[[str], None] | None = None,
    keep_display_awake: bool = False,
    cwd: str | None = None,
    stdout: int | None = None,
    env: dict[str, str] | None = None,
) -> tuple[int, float]:
    """Wait for a slot, run argv in its own process group, release. Returns (exit code, lock wait s)."""
    cmd = " ".join(argv)
    held = acquire(cmd, priority=priority, config=config, report=report)
    try:
        _holder_file(held.slot).write_text(json.dumps({
            "pid": os.getpid(), "ticket": os.environ.get("STARPIPE_TICKET", ""),
            "cmd": cmd, "since": time.time(),
        }))
        if keep_display_awake:  # XCUITest / Compose UI freeze when the display sleeps
            argv = ["caffeinate", "-d", "-u", *argv]
        proc = subprocess.Popen(argv, process_group=0, cwd=cwd, stdout=stdout, env=env,
                                stderr=subprocess.STDOUT if stdout is not None else None)

        def forward(signum: int, _frame: object) -> None:
            if proc.poll() is None:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(proc.pid, signum)

        # Signal handlers can only be set on the main thread. The daemon runs this on a worker thread, so there the child
        # is not forwarded signals; it is still never left running past the lock (see the except below).
        old = {}
        if threading.current_thread() is threading.main_thread():
            old = {s: signal.signal(s, forward) for s in (signal.SIGINT, signal.SIGTERM)}
        try:
            code = proc.wait()
        except BaseException:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(proc.pid, signal.SIGKILL)  # never release the lock while the job is still running
            proc.wait()
            raise
        finally:
            for s, h in old.items():
                signal.signal(s, h)
        return (128 + -code if code < 0 else code), held.waited
    finally:
        release(held)


@dataclass
class Holder:
    pid: int
    ticket: str
    cmd: str
    since: float


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
