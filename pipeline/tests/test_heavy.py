from __future__ import annotations

import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest

from starpipe import heavy
from starpipe.config import Config

CFG = Config(heavy_slots=1)


def starpipe(*args: str, env: dict[str, str] | None = None) -> subprocess.Popen[str]:
    import os
    return subprocess.Popen([sys.executable, "-m", "starpipe.cli", *args], text=True,
                            env={**os.environ, **(env or {})}, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def test_two_jobs_run_one_after_the_other(tmp_path: Path) -> None:
    log = tmp_path / "log"
    script = f"import time;f=open('{log}','a');f.write('s ');f.flush();time.sleep(1);f.write('e ');f.flush()"
    a = starpipe("heavy", "--", sys.executable, "-c", script)
    b = starpipe("heavy", "--", sys.executable, "-c", script)
    a.wait(30)
    b.wait(30)
    assert log.read_text().split() == ["s", "e", "s", "e"]


def test_exit_code_is_preserved() -> None:
    p = starpipe("heavy", "--", sys.executable, "-c", "raise SystemExit(7)")
    assert p.wait(30) == 7


def test_interactive_caller_goes_before_an_older_pipeline_waiter(tmp_path: Path) -> None:
    log = tmp_path / "order"

    def mark(tag: str) -> str:
        return f"open('{log}','a').write('{tag} ')"

    holder = starpipe("heavy", "--", sys.executable, "-c", "import time;time.sleep(2)")
    time.sleep(0.7)
    pipe = starpipe("heavy", "--", sys.executable, "-c", mark("pipeline"), env={"STARPIPE_TICKET": "42"})
    time.sleep(0.5)
    inter = starpipe("heavy", "--", sys.executable, "-c", mark("interactive"))
    for p in (holder, pipe, inter):
        p.wait(30)
    assert log.read_text().split() == ["interactive", "pipeline"]


def test_a_dead_holder_frees_the_slot() -> None:
    h = starpipe("heavy", "--", sys.executable, "-c", "import time;time.sleep(60)")
    time.sleep(0.7)
    h.kill()  # the kernel drops the flock; no stale lock to wait out
    h.wait()
    held = heavy.acquire("probe", config=CFG, poll=0.05)
    heavy.release(held)


def wait_until(condition: Callable[[], bool], timeout: float = 20.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.1)
    return False


def test_status_lists_holder_and_waiter() -> None:
    h = starpipe("heavy", "--", sys.executable, "-c", "import time;time.sleep(60)")
    assert wait_until(lambda: len(heavy.status().holders) == 1)
    w = starpipe("heavy", "--", sys.executable, "-c", "pass")
    assert wait_until(lambda: len(heavy.status().queue) == 1)
    st = heavy.status()
    assert len(st.holders) == 1 and len(st.queue) == 1
    h.kill()
    w.kill()
    h.wait()
    w.wait()


def test_priority_defaults_from_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    assert heavy.default_priority() == heavy.INTERACTIVE
    monkeypatch.setenv("STARPIPE_TICKET", "1")
    assert heavy.default_priority() == heavy.PIPELINE
    monkeypatch.setenv("STARPIPE_NIGHTLY", "1")
    assert heavy.default_priority() == heavy.NIGHTLY


def test_heavy_run_works_from_a_worker_thread() -> None:
    """The daemon's run_checks runs heavy jobs on a worker thread, where signal.signal raises. It used to launch the
    child, then raise, release the lock and leave the child running unmanaged."""
    import threading

    result: list[tuple[int, float]] = []
    errors: list[BaseException] = []

    def work() -> None:
        try:
            result.append(heavy.run([sys.executable, "-c", "raise SystemExit(3)"], config=CFG))
        except BaseException as exc:  # noqa: BLE001
            errors.append(exc)

    t = threading.Thread(target=work)
    t.start()
    t.join(30)
    assert errors == [] and result[0][0] == 3
    assert heavy.status().holders == []


def test_a_child_is_killed_if_the_wait_is_interrupted() -> None:
    import threading

    started = threading.Event()
    pids: list[int] = []

    def work() -> None:
        popen: Any = subprocess.Popen
        real_wait = popen.wait

        def interrupted(self: Any, timeout: float | None = None) -> int:
            if not started.is_set():
                started.set()
                pids.append(self.pid)
                raise KeyboardInterrupt
            return real_wait(self, timeout)

        popen.wait = interrupted
        try:
            with pytest.raises(KeyboardInterrupt):
                heavy.run([sys.executable, "-c", "import time;time.sleep(60)"], config=CFG)
        finally:
            popen.wait = real_wait

    t = threading.Thread(target=work)
    t.start()
    t.join(30)
    import psutil

    assert pids and not psutil.pid_exists(pids[0])
    assert heavy.status().holders == []
