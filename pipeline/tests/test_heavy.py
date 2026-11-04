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


def fake_swift(tmp_path: Path, seconds: float) -> dict[str, str]:
    """A `swift` on PATH that logs `s<package>` and `e<package>` around a sleep: a light job without building anything."""
    import os
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    tool = bindir / "swift"
    tool.write_text(f'#!/bin/sh\necho "s$3" >> "{tmp_path}/swift.log"\nsleep {seconds}\necho "e$3" >> "{tmp_path}/swift.log"\n')
    tool.chmod(0o755)
    return {"PATH": f"{bindir}{os.pathsep}{os.environ['PATH']}"}


def test_two_jobs_run_one_after_the_other(tmp_path: Path) -> None:
    log = tmp_path / "log"
    script = f"import time;f=open('{log}','a');f.write('s ');f.flush();time.sleep(1);f.write('e ');f.flush()"
    a = starpipe("heavy", "--", sys.executable, "-c", script)
    b = starpipe("heavy", "--", sys.executable, "-c", script)
    a.wait(30)
    b.wait(30)
    assert log.read_text().split() == ["s", "e", "s", "e"]
    # light jobs, with the default heavy_light_slots = 1, are no different
    stub_env = fake_swift(tmp_path, 1.0)
    jobs = [starpipe("heavy", "--", "swift", "build", "--package-path", tag, env=stub_env) for tag in ("a", "b")]
    for job in jobs:
        job.wait(30)
    lines = (tmp_path / "swift.log").read_text().split()
    assert [x[0] for x in lines] == ["s", "e", "s", "e"]


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


FAST = Config(heavy_slots=1, heavy_idle_kill_s=1.5, heavy_idle_grace_s=1.0, heavy_idle_poll_s=0.2)


def test_idle_job_is_killed_and_lock_released() -> None:
    start = time.monotonic()
    result = heavy.run_job([sys.executable, "-c", "import time;time.sleep(60)"], config=FAST)
    assert time.monotonic() - start < 20
    assert result.code != 0
    assert result.hung is not None and "time.sleep(60)" in result.hung.cmd and result.hung.idle_s >= FAST.heavy_idle_kill_s
    assert heavy.status().holders == []
    heavy.release(heavy.acquire("probe", config=FAST, poll=0.05))  # the slot is free again


def _spawn_tree_script(pidfile: Path) -> str:
    """A job whose child moves itself into a new session (so a new process group), records its pid, and sleeps."""
    child = "import time;time.sleep(60)"
    return (
        "import subprocess,sys,time\n"
        f"c=subprocess.Popen([sys.executable,'-c',{child!r}],start_new_session=True)\n"
        f"open({str(pidfile)!r},'w').write(str(c.pid))\n"
        "time.sleep(60)"
    )


def _gone(pid: int) -> bool:
    import psutil

    try:
        return psutil.Process(pid).status() == psutil.STATUS_ZOMBIE
    except psutil.NoSuchProcess:
        return True


def test_idle_kill_reaches_a_child_in_its_own_process_group(tmp_path: Path) -> None:
    pidfile = tmp_path / "child.pid"
    result = heavy.run_job([sys.executable, "-c", _spawn_tree_script(pidfile)], config=FAST)
    assert result.hung is not None
    child = int(pidfile.read_text())
    try:
        assert _gone(child)
    finally:
        import os
        import signal

        if not _gone(child):
            os.kill(child, signal.SIGKILL)


def test_an_interrupted_job_kills_children_in_other_groups(tmp_path: Path) -> None:
    pidfile = tmp_path / "child.pid"
    popen: Any = subprocess.Popen
    real_wait = popen.wait
    interrupted: list[int] = []

    def wait(self: Any, timeout: float | None = None) -> int:
        if not interrupted:
            assert wait_until(pidfile.exists)
            time.sleep(0.2)  # the pid is written before the file is flushed closed; let it settle
            interrupted.append(self.pid)
            raise KeyboardInterrupt
        return real_wait(self, timeout)

    popen.wait = wait
    try:
        with pytest.raises(KeyboardInterrupt):
            heavy.run_job([sys.executable, "-c", _spawn_tree_script(pidfile)], config=CFG)
    finally:
        popen.wait = real_wait
    child = int(pidfile.read_text())
    try:
        assert _gone(child)
    finally:
        import os
        import signal

        if not _gone(child):
            os.kill(child, signal.SIGKILL)
    assert heavy.status().holders == []


def test_busy_job_is_not_killed(tmp_path: Path) -> None:
    spin = "import time;t=time.time()\nwhile time.time()-t<4: pass"
    writer = "import time,sys\nfor _ in range(14):\n  print('x',flush=True);time.sleep(0.3)"
    # a shell parent that does nothing itself, with the CPU burnt in children, and a quiet child that only writes to the log
    script = f"import subprocess,sys;ps=[subprocess.Popen([sys.executable,'-c',{spin!r}]),subprocess.Popen([sys.executable,'-c',{writer!r}])];[p.wait() for p in ps]"
    with (tmp_path / "log").open("wb") as out:
        busy = heavy.run_job([sys.executable, "-c", script], config=FAST, stdout=out.fileno())
        assert busy.hung is None and busy.code == 0
        # the writer alone, with no CPU to speak of
        quiet = heavy.run_job([sys.executable, "-c", writer], config=FAST, stdout=out.fileno())
        assert quiet.hung is None and quiet.code == 0
    spinner = heavy.run_job([sys.executable, "-c", spin], config=FAST)
    assert spinner.hung is None and spinner.code == 0


def test_a_hold_records_its_cpu_and_memory(state_home: Path) -> None:
    from starpipe.checks import ledger

    cfg = Config(heavy_slots=1, heavy_idle_poll_s=0.2)
    burn = "import time;ballast=bytearray(120*1024*1024);t=time.time()\nwhile time.time()-t<2.5: pass"
    result = heavy.run_job([sys.executable, "-c", burn], config=cfg)
    assert result.code == 0
    assert result.cpu_mean > 0.4 and result.cpu_peak >= result.cpu_mean
    assert result.rss_peak_mb >= 100 and result.seconds >= 2.5
    # the ledger row keeps it, and a row from before these fields still loads
    ledger.record(ledger.Result("c", "pass", "sha1", 1.0, cpu_mean=result.cpu_mean, cpu_peak=result.cpu_peak,
                                rss_peak_mb=result.rss_peak_mb))
    got = ledger.latest("sha1", "c")
    assert got is not None and got.rss_peak_mb == result.rss_peak_mb and got.cpu_peak == result.cpu_peak
    (state_home / "results.jsonl").write_text('{"check": "old", "status": "pass", "sha": "s0", "seconds": 1.0}\n')
    old = ledger.latest("s0", "old")
    assert old is not None and old.cpu_mean == 0.0 and old.rss_peak_mb == 0.0
    # `--status` shows a running hold's numbers
    (state_home / "config.toml").write_text("heavy_idle_poll_s = 0.2\n")
    job = starpipe("heavy", "--", sys.executable, "-c", burn.replace("2.5", "30"))
    try:
        assert wait_until(lambda: any(h.rss_peak_mb >= 100 and h.cpu_peak > 0 for h in heavy.status().holders))
        shown = starpipe("heavy", "--status")
        out = shown.communicate(timeout=30)[0]
        assert "exclusive" in out and "rss peak" in out and "cpu" in out
    finally:
        job.kill()
        job.wait()


def test_jobs_are_classed_light_or_exclusive() -> None:
    from starpipe.adapter_star import job_class

    light = [
        "swift build --package-path cli",
        "swift test --package-path StarCore --parallel --num-workers 8 --skip OpenCVQoSTests",
        "script -q /dev/null swift test --package-path StarCore",
        "./gradlew compileKotlin compileTestKotlin --no-daemon",
    ]
    exclusive = [
        "swift run star -i x",
        ".build/debug/star --help",
        ".build/release/stard",
        "star-gherkin features/x.feature",
        "xcodebuild test -project gui/star.xcodeproj -scheme star",
        "xcodebuild -project gui/star.xcodeproj -scheme star build",
        "./gradlew test --no-daemon",
        "swift test --package-path cli --filter GherkinTests.GeneratedFeatureTests/testFooFeature",
        "swift test --package-path StarCpp --parallel --num-workers 1 --filter OpenCVQoSTests",
        "./gradlew",
        "make all",
        "",
    ]
    assert [c for c in light if job_class(c) != "light"] == []
    assert [c for c in exclusive if job_class(c) != "exclusive"] == []


def share_config(home: Path, *, mem_pct: float = 0.0, rss_gb: float = 12.0, slots: int = 2) -> None:
    home.mkdir(parents=True, exist_ok=True)
    (home / "config.toml").write_text(f"heavy_light_slots = {slots}\nheavy_free_mem_pct = {mem_pct}\n"
                                      f"heavy_light_rss_gb = {rss_gb}\nheavy_idle_poll_s = 0.2\n")


def light_pair(tmp_path: Path, second: str = "light") -> list[str]:
    """Start a light job, then (once it holds the lock) a second job; the log's order says whether they overlapped."""
    env = fake_swift(tmp_path, 3.0)
    log = tmp_path / "swift.log"
    first = starpipe("heavy", "--", "swift", "build", "--package-path", "1", env=env)
    assert wait_until(lambda: len(heavy.status().holders) == 1)
    if second == "light":
        other = starpipe("heavy", "--", "swift", "build", "--package-path", "2", env=env)
    else:
        other = starpipe("heavy", "--", sys.executable, "-c", f"open('{log}','a').write('x\\n')")
    first.wait(60)
    other.wait(60)
    return log.read_text().split()


def test_a_light_job_shares_only_with_a_light_holder_and_free_memory(tmp_path: Path, state_home: Path) -> None:
    share_config(state_home)  # memory demand 0 %: always enough
    assert light_pair(tmp_path)[:2] == ["s1", "s2"]  # the second job started while the first still held its slot
    (tmp_path / "swift.log").unlink()
    share_config(state_home, mem_pct=101.0)  # more free memory than the machine has
    assert light_pair(tmp_path) == ["s1", "e1", "s2", "e2"]
    (tmp_path / "swift.log").unlink()
    share_config(state_home, rss_gb=0.0)  # the holder is already at the limit
    assert light_pair(tmp_path) == ["s1", "e1", "s2", "e2"]
    (tmp_path / "swift.log").unlink()
    share_config(state_home)  # an exclusive job takes the whole machine: it neither shares nor is shared with
    assert light_pair(tmp_path, "exclusive") == ["s1", "e1", "x"]
    (tmp_path / "swift.log").unlink()
    # a light job behind an exclusive holder waits too
    log = tmp_path / "swift.log"
    holder = starpipe("heavy", "--", sys.executable, "-c",
                      f"import time;open('{log}','a').write('xs\\n');time.sleep(3);open('{log}','a').write('xe\\n')")
    assert wait_until(lambda: len(heavy.status().holders) == 1)
    light = starpipe("heavy", "--", "swift", "build", "--package-path", "2", env=fake_swift(tmp_path, 0.2))
    holder.wait(60)
    light.wait(60)
    assert log.read_text().split() == ["xs", "xe", "s2", "e2"]


def test_an_exclusive_waiter_blocks_new_sharing(tmp_path: Path, state_home: Path) -> None:
    share_config(state_home)
    env = fake_swift(tmp_path, 3.0)
    log = tmp_path / "swift.log"
    first = starpipe("heavy", "--", "swift", "build", "--package-path", "1", env=env)
    assert wait_until(lambda: len(heavy.status().holders) == 1)
    exclusive = starpipe("heavy", "--", sys.executable, "-c", f"open('{log}','a').write('x\\n')")
    assert wait_until(lambda: len(heavy.status().queue) == 1)
    late = starpipe("heavy", "--", "swift", "build", "--package-path", "3", env=env)
    for job in (first, exclusive, late):
        job.wait(60)
    # without the rule `late` would have shared the slot with `first` at once
    assert log.read_text().split() == ["s1", "e1", "x", "s3", "e3"]
