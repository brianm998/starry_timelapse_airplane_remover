from __future__ import annotations

import signal
import subprocess
import sys
import time
from pathlib import Path

import psutil
import pytest

from starpipe import heavy, watch
from starpipe.config import Config
from starpipe.daemon import Daemon

from .test_engine import Rig


class Fake:
    """A scripted process tree: tests change `cpu` and `stopped` between ticks and read back what was signalled."""

    def __init__(self) -> None:
        self.cpu = 0.0
        self.stopped: list[int] = []
        self.gone = False
        self.sent: list[tuple[int, int]] = []

    def snap(self, pid: int) -> watch.Tree | None:
        return None if self.gone else watch.Tree([pid, pid + 1, pid + 2], list(self.stopped), self.cpu)

    def send(self, pid: int, sig: int) -> None:
        self.sent.append((pid, sig))


def make(fake: Fake) -> watch.Watch:
    return watch.Watch(cont_after=600, kill_after=1800, snap=fake.snap, send=fake.send)


def test_progress_keeps_a_busy_tree_alive_forever() -> None:
    f = Fake()
    w = make(f)
    t = watch.Target("stage:1", 100)
    for minute in range(0, 120, 5):
        f.cpu += 5.0  # always burning CPU
        assert w.tick([t], now=minute * 60.0) == []
    assert f.sent == []


def test_a_stopped_descendant_is_continued_after_ten_minutes_of_silence() -> None:
    f = Fake()
    w = make(f)
    t = watch.Target("stage:1", 100)
    w.tick([t], now=0)
    f.stopped = [102]
    assert w.tick([t], now=500) == []  # silent, but not yet ten minutes
    (action,) = w.tick([t], now=700)
    assert action.kind == "sigcont" and action.pids == [102]
    assert f.sent == [(102, signal.SIGCONT)] and w.sigconts == 1


def test_the_root_itself_is_never_sent_sigcont() -> None:
    f = Fake()
    w = make(f)
    t = watch.Target("stage:1", 100)
    w.tick([t], now=0)
    f.stopped = [100]  # only the root is stopped: that is not "its own descendants"
    assert [a.kind for a in w.tick([t], now=700)] == []


def test_a_silent_idle_tree_is_killed_after_thirty_minutes_leaves_first() -> None:
    f = Fake()
    w = make(f)
    t = watch.Target("stage:1", 100)
    w.tick([t], now=0)
    assert w.tick([t], now=1700) == []
    (action,) = w.tick([t], now=1900)
    assert action.kind == "kill"
    assert f.sent == [(102, signal.SIGKILL), (101, signal.SIGKILL), (100, signal.SIGKILL)]


def test_new_output_counts_as_progress() -> None:
    f = Fake()
    w = make(f)
    clock = {"t": 0.0}
    t = watch.Target("stage:1", 100, activity=lambda: clock["t"])
    w.tick([t], now=0)
    clock["t"] = 1500.0  # the transcript grew at minute 25
    assert w.tick([t], now=1500) == []
    assert w.tick([t], now=2300) == []  # 13 minutes since the last output: not killed yet
    assert [a.kind for a in w.tick([t], now=3400)] == ["kill"]


def test_a_stage_queued_for_the_heavy_lock_is_not_killed() -> None:
    f = Fake()
    w = make(f)
    t = watch.Target("stage:1", 100, waiting_pids=frozenset({101}))  # a `starpipe heavy` waiter inside the tree
    w.tick([t], now=0)
    assert w.tick([t], now=7200) == [] and f.sent == []


def test_a_target_that_exits_is_forgotten() -> None:
    f = Fake()
    w = make(f)
    t = watch.Target("stage:1", 100)
    w.tick([t], now=0)
    f.gone = True
    w.tick([t], now=10)
    assert w.states == {}


def test_a_real_sigstopped_child_is_continued() -> None:
    """Real processes and real psutil: a sleeping child of a shell is SIGSTOPped, then the watch SIGCONTs it."""
    code = "import subprocess,sys,time;subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)']);time.sleep(60)"
    shell = subprocess.Popen([sys.executable, "-c", code])
    try:
        deadline = time.monotonic() + 10
        while not psutil.Process(shell.pid).children() and time.monotonic() < deadline:
            time.sleep(0.05)
        (child,) = psutil.Process(shell.pid).children()
        child.suspend()
        w = watch.Watch(cont_after=5)
        t = watch.Target("heavy:x", shell.pid)
        w.tick([t], now=0)
        (action,) = w.tick([t], now=6)
        assert action.kind == "sigcont" and action.pids == [child.pid]
        deadline = time.monotonic() + 5
        while child.status() == psutil.STATUS_STOPPED and time.monotonic() < deadline:
            time.sleep(0.05)
        assert child.status() != psutil.STATUS_STOPPED
    finally:
        for p in [*psutil.Process(shell.pid).children(recursive=True), psutil.Process(shell.pid)]:
            p.kill()


def test_the_daemon_watches_pipeline_heavy_jobs_but_never_interactive_ones(
        tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    rig = Rig(tmp_path)
    d = Daemon(rig.engine, Config(), token="t")
    mine = heavy.Holder(pid=4242, ticket="20", cmd="swift test", since=0.0)
    other = heavy.Holder(pid=4343, ticket="", cmd="gradlew test", since=0.0)
    monkeypatch.setattr(heavy, "status", lambda: heavy.Status([mine, other], []))
    labels = [t.label for t in d.watch_targets()]
    assert labels == ["heavy:4242"]
