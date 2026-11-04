"""The machine-wide heavy-job lock (plan §9.1): one build / test suite / star run at a time.

With `heavy_light_slots` above 1, a light job (adapter_star.job_class) may take a second slot beside a light holder while the
machine has room. Every hold records its CPU and memory use (_Activity), so the owner can decide per job from evidence.

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

from . import adapter_star
from .config import Config, home, load

INTERACTIVE, PIPELINE, NIGHTLY = 0, 1, 2
LIGHT, EXCLUSIVE = "light", "exclusive"


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
    job_class: str = EXCLUSIVE

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


def _holder_file(slot: int) -> Path:
    return locks_dir() / f"holder.{slot}.json"


def _write_holder(slot: int, record: dict[str, Any]) -> None:
    """Atomically, so a reader never sees half a record."""
    path = _holder_file(slot)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(record))
    os.replace(tmp, path)


def _read_holder(slot: int) -> dict[str, Any] | None:
    try:
        data: dict[str, Any] = json.loads(_holder_file(slot).read_text())
        if psutil.pid_exists(int(data["pid"])):
            return data
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        pass
    return None


def _room_to_share(cfg: Config, total: int) -> bool:
    """Every job holding a slot is light and under the RSS limit, and the machine has free memory."""
    for slot in range(total):
        fd = _try_slot(slot)
        if fd is not None:
            os.close(fd)  # free: nothing to judge
            continue
        info = _read_holder(slot)
        if info is None or info.get("job_class") != LIGHT or info.get("rss_peak_mb", 0.0) >= cfg.heavy_light_rss_gb * 1024:
            return False
    mem = psutil.virtual_memory()
    return mem.available / mem.total * 100 >= cfg.heavy_free_mem_pct


def _slots_for(cfg: Config, queue: list[Waiter], rank: int, kind: str) -> range | None:
    """The slots this waiter may take now, or None. With heavy_light_slots == heavy_slots this is the plain rule: the head of the
    queue takes a free slot. Slots from heavy_slots up are sharing slots, only ever held by light jobs."""
    base = cfg.heavy_slots
    total = max(base, cfg.heavy_light_slots)
    sharing = total > base
    if kind != LIGHT:
        if sharing and _free_slots(total) < total:  # an exclusive job needs the whole machine
            return None
        return range(base) if rank < _free_slots(base) else None
    exclusive_ahead = sharing and any(w.job_class != LIGHT for w in queue[:rank])
    if rank < _free_slots(base) and not exclusive_ahead:
        return range(base)
    # sharing: only the head of the queue, and never while any exclusive job waits (it would starve)
    if sharing and rank == 0 and all(w.job_class == LIGHT for w in queue) and _room_to_share(cfg, total):
        return range(base, total)
    return None


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
    kind = job_class or adapter_star.job_class(cmd)
    me = psutil.Process()
    waiter = Waiter(prio, time.time(), os.getpid(), me.create_time(),
                    os.environ.get("STARPIPE_TICKET", ""), cmd, kind)
    entry = locks_dir() / "queue" / f"{waiter.pid}.json"
    entry.write_text(json.dumps(asdict(waiter)))
    started, last_report = time.monotonic(), 0.0
    try:
        while True:
            with _grant_lock():
                queue = _queue()
                rank = next((i for i, w in enumerate(queue) if w.pid == waiter.pid), 0)
                slots = _slots_for(cfg, queue, rank, kind)
                for i in slots or ():
                    fd = _try_slot(i)
                    if fd is not None:
                        entry.unlink(missing_ok=True)
                        # written under the grant lock, so a sharer never finds a held slot without its class
                        _write_holder(i, {"pid": waiter.pid, "ticket": waiter.ticket, "cmd": cmd, "since": time.time(),
                                          "job_class": kind})
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
) -> RunResult:
    """Wait for a slot, run argv in its own process group, release. A job idle for `heavy_idle_kill_s` is killed and
    reported as hung, so a wedged test run cannot hold the slot until the owner notices."""
    cfg = config or load()
    cmd = " ".join(argv)
    kind = EXCLUSIVE if keep_display_awake else adapter_star.job_class(cmd)  # a UI run needs the display and the machine
    held = acquire(cmd, priority=priority, config=cfg, report=report, job_class=kind)
    try:
        record = {"pid": os.getpid(), "ticket": os.environ.get("STARPIPE_TICKET", ""), "cmd": cmd, "since": time.time(),
                  "job_class": kind}
        _write_holder(held.slot, record)
        if keep_display_awake:  # XCUITest / Compose UI freeze when the display sleeps
            argv = ["caffeinate", "-d", "-u", *argv]
        proc = subprocess.Popen(argv, process_group=0, cwd=cwd, stdout=stdout, env=env,
                                stderr=subprocess.STDOUT if stdout is not None else None)
        record["job_pid"] = proc.pid  # `pid` is the caller; this is what is running
        _write_holder(held.slot, record)

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
                _write_holder(held.slot, {**record, "cpu_mean": watch.cpu_mean, "cpu_peak": watch.cpu_peak,
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
    return Status(holders, _queue())
