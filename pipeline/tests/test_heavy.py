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

CFG = Config()


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


def test_concurrent_holder_writes_for_one_pid_do_not_collide() -> None:
    import json
    import threading

    n_threads, rounds = 16, 50
    barrier = threading.Barrier(n_threads)
    errors: list[BaseException] = []

    def work(i: int) -> None:
        barrier.wait()
        try:
            for r in range(rounds):
                heavy._write_holder(4242, {"writer": i, "round": r, "pad": "x" * 200})  # pyright: ignore[reportPrivateUsage]
        except BaseException as e:  # noqa: BLE001
            errors.append(e)

    threads = [threading.Thread(target=work, args=(i,)) for i in range(n_threads)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert errors == []
    rec = json.loads(heavy._holder_file(4242).read_text())  # pyright: ignore[reportPrivateUsage]
    assert rec["pad"] == "x" * 200 and 0 <= rec["writer"] < n_threads
    assert list(heavy.locks_dir().glob("*.tmp")) == []


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


FAST = Config(heavy_idle_kill_s=1.5, heavy_idle_grace_s=1.0, heavy_idle_poll_s=0.2)


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

    cfg = Config(heavy_idle_poll_s=0.2)
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


def test_jobs_are_classed_build_test_or_exclusive() -> None:
    from starpipe.adapter_star import BUILD, EXCLUSIVE, TEST, job_class

    expected = {
        "swift build --package-path cli": BUILD,
        "./gradlew compileKotlin compileTestKotlin --no-daemon": BUILD,
        "./gradlew checkProtoSync --no-daemon": BUILD,
        "xcodebuild -project gui/star.xcodeproj -scheme star build": BUILD,
        "swift test --package-path StarCore --parallel --num-workers 8 --skip OpenCVQoSTests": TEST,
        "script -q /dev/null swift test --package-path StarCore": TEST,
        "/usr/bin/python3 -m starpipe.shards --package-path StarCore --log-dir x": TEST,
        "swift run star -i x": EXCLUSIVE,
        ".build/debug/star --help": EXCLUSIVE,
        ".build/release/stard": EXCLUSIVE,
        "star-gherkin features/x.feature": EXCLUSIVE,
        "xcodebuild test -project gui/star.xcodeproj -scheme star": EXCLUSIVE,
        "./gradlew test --no-daemon": EXCLUSIVE,
        "swift test --package-path cli --filter GherkinTests.GeneratedFeatureTests/testFooFeature": EXCLUSIVE,
        "swift test --package-path StarCpp --parallel --num-workers 1 --filter OpenCVQoSTests": EXCLUSIVE,
        "./gradlew": EXCLUSIVE,
        "make all": EXCLUSIVE,
        "": EXCLUSIVE,
        # the PreToolUse hook wraps a session's whole Bash command: the most demanding command in it decides
        "bash -c 'cd StarCore && swift build 2>&1 | tail -20'": BUILD,
        "bash -c 'swift build --package-path cli && swift test --package-path cli --skip GherkinTests | tail'": TEST,
        "bash -c 'swift build --package-path cli && .build/debug/star -i frames'": EXCLUSIVE,
        "bash -c 'FOO=1 time xcodebuild -scheme star build; echo done'": BUILD,
        "bash -c 'echo nothing heavy here'": EXCLUSIVE,
        "bash -c 'unbalanced \"quote'": EXCLUSIVE,
    }
    got = {cmd: job_class(cmd) for cmd in expected}
    assert {c: k for c, k in got.items() if k != expected[c]} == {}


def split_config(home: Path, *, mem_pct: float = 0.0, builds: int = 3, split: bool = True) -> None:
    home.mkdir(parents=True, exist_ok=True)
    (home / "config.toml").write_text(f"heavy_build_slots = {builds}\nheavy_free_mem_pct = {mem_pct}\n"
                                      f"heavy_split = {'true' if split else 'false'}\nheavy_idle_poll_s = 0.2\n")


def fake_tools(tmp_path: Path, seconds: float) -> dict[str, str]:
    """`swift` on PATH logging `s<tag>`/`e<tag>` around a sleep: `swift build --package-path T` is a build, `swift test
    --package-path T` a test suite; `star T` is an exclusive job. Nothing is built."""
    import os
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    for name in ("swift", "star"):
        tool = bindir / name
        tag = "$3" if name == "swift" else "$1"
        tool.write_text(f'#!/bin/sh\necho "s{tag}" >> "{tmp_path}/jobs.log"\nsleep {seconds}\necho "e{tag}" >> "{tmp_path}/jobs.log"\n')
        tool.chmod(0o755)
    return {"PATH": f"{bindir}{os.pathsep}{os.environ['PATH']}"}


def job(kind: str, tag: str, env: dict[str, str], extra: dict[str, str] | None = None) -> subprocess.Popen[str]:
    argv = {"build": ["swift", "build", "--package-path", tag], "test": ["swift", "test", "--package-path", tag],
            "exclusive": ["star", tag]}[kind]
    return starpipe("heavy", "--", *argv, env={**env, **(extra or {})})


def run_after_first(tmp_path: Path, first: str, *others: str, seconds: float = 4.0) -> list[str]:
    """Start `first`, then (once it holds the lock) the others in turn, each once the one before is holding or queued; the log's
    order shows what overlapped."""
    env = fake_tools(tmp_path, seconds)

    def seen(tag: str) -> bool:
        st = heavy.status()
        return any(x.cmd.endswith(f" {tag}") for x in [*st.holders, *st.queue])

    jobs = [job(first, "1", env)]
    assert wait_until(lambda: seen("1"))
    for i, kind in enumerate(others, 2):
        jobs.append(job(kind, str(i), env))
        assert wait_until(lambda tag=str(i): seen(tag))
    for j in jobs:
        assert j.wait(60) == 0
    out = (tmp_path / "jobs.log").read_text().split()
    (tmp_path / "jobs.log").unlink()
    return out


def test_builds_share_and_a_test_runs_beside_them(tmp_path: Path, state_home: Path) -> None:
    split_config(state_home)
    assert run_after_first(tmp_path, "build", "build")[:2] == ["s1", "s2"]
    assert run_after_first(tmp_path, "test", "build")[:2] == ["s1", "s2"]
    assert run_after_first(tmp_path, "build", "test")[:2] == ["s1", "s2"]


def test_conflicting_jobs_wait(tmp_path: Path, state_home: Path) -> None:
    split_config(state_home)
    assert run_after_first(tmp_path, "test", "test") == ["s1", "e1", "s2", "e2"]  # one test suite at a time
    assert run_after_first(tmp_path, "build", "exclusive") == ["s1", "e1", "s2", "e2"]  # exclusive waits for every holder
    assert run_after_first(tmp_path, "exclusive", "build") == ["s1", "e1", "s2", "e2"]  # and nothing runs beside it
    split_config(state_home, builds=1)
    assert run_after_first(tmp_path, "build", "build") == ["s1", "e1", "s2", "e2"]  # only as many builds as slots
    split_config(state_home, mem_pct=101.0)  # more free memory than the machine has: nothing starts beside another job
    assert run_after_first(tmp_path, "build", "build") == ["s1", "e1", "s2", "e2"]
    split_config(state_home, split=False)  # the old one-at-a-time lock
    assert run_after_first(tmp_path, "build", "build") == ["s1", "e1", "s2", "e2"]


def test_a_waiting_exclusive_job_is_not_overtaken(tmp_path: Path, state_home: Path) -> None:
    split_config(state_home)
    # a build may start while a test suite waits, since it does not need the test slot...
    assert run_after_first(tmp_path, "test", "test", "build")[:2] == ["s1", "s3"]
    # ...but nothing starts while an exclusive job waits for the machine to drain
    order = run_after_first(tmp_path, "build", "exclusive", "build")
    assert order == ["s1", "e1", "s2", "e2", "s3", "e3"]


def W(pid: int, kind: str, *, stage: str = "", ticket: str = "", at: float = 0.0, prio: int = heavy.PIPELINE,
      tprio: int = heavy.NO_TICKET_PRIORITY) -> heavy.Waiter:
    return heavy.Waiter(prio, at, pid, 0.0, ticket, "cmd", kind, stage, tprio)


def granted(queue: list[heavy.Waiter], cfg: Config | None = None) -> list[int]:
    """Which of the queued waiters the grant would let start now, with every slot free."""
    cfg = cfg or Config(heavy_free_mem_pct=0.0)
    order = sorted(queue, key=heavy.Waiter.key)
    return [w.pid for w in order if heavy._grant(cfg, order, w.pid, lambda x: x.job_class) is not None]  # pyright: ignore[reportPrivateUsage]


def test_the_ticket_furthest_along_goes_first() -> None:
    ex = heavy.EXCLUSIVE
    # the develop job asked first, the conflict job (a ticket in the landing train) later: the conflict job gets the machine
    assert granted([W(1, ex, stage="develop", ticket="100", at=1.0), W(2, ex, stage="conflict", ticket="200", at=2.0)]) == [2]
    assert granted([W(1, ex, stage="explore", ticket="5", at=1.0), W(2, ex, stage="fix", ticket="9", at=9.0),
                    W(3, ex, stage="verify", ticket="7", at=5.0)]) == [3]
    # same stage: the ticket's priority, then the older ticket, then arrival
    assert granted([W(1, ex, stage="develop", ticket="100", tprio=2), W(2, ex, stage="develop", ticket="300", tprio=1)]) == [2]
    assert granted([W(1, ex, stage="develop", ticket="300", at=1.0), W(2, ex, stage="develop", ticket="100", at=2.0)]) == [2]
    assert granted([W(1, ex, stage="develop", ticket="100", at=2.0), W(2, ex, stage="develop", ticket="100", at=1.0)]) == [2]
    # the owner's own commands still go before any ticket, and the nightly after all of them
    assert granted([W(1, ex, stage="landing", ticket="1"), W(2, ex, prio=heavy.INTERACTIVE)]) == [2]
    assert granted([W(1, ex, prio=heavy.NIGHTLY), W(2, ex, stage="explore", ticket="9")]) == [2]


def test_progress_order_holds_across_classes() -> None:
    b, t, ex = heavy.BUILD, heavy.TEST, heavy.EXCLUSIVE
    cfg = Config(heavy_free_mem_pct=0.0, heavy_build_slots=2)
    # builds fill the build slots furthest-along first; the develop build that asked first is the one left waiting
    assert granted([W(1, b, stage="develop", ticket="1", at=1.0), W(2, b, stage="review", ticket="2", at=2.0),
                    W(3, b, stage="ci-fix", ticket="3", at=3.0)], cfg) == [3, 2]
    # an exclusive job further along keeps everything behind it waiting; one behind does not hold up what is ahead of it
    assert granted([W(1, b, stage="develop", ticket="1"), W(2, ex, stage="conflict", ticket="2")], cfg) == [2]
    assert granted([W(1, t, stage="conflict", ticket="1"), W(2, b, stage="develop", ticket="2"),
                    W(3, ex, stage="develop", ticket="3")], cfg) == [1, 2]


def test_the_requester_comes_from_the_engine_or_the_session_environment(monkeypatch: pytest.MonkeyPatch,
                                                                       tmp_path: Path) -> None:
    assert heavy.current_requester() == heavy.Requester("", "", heavy.NO_TICKET_PRIORITY)
    monkeypatch.setenv("STARPIPE_TICKET", "42")
    monkeypatch.setenv("STARPIPE_STAGE", "ci-fix")
    monkeypatch.setenv("STARPIPE_TICKET_PRIORITY", "1")
    assert heavy.current_requester() == heavy.Requester("42", "ci-fix", 1)
    import threading
    seen: list[heavy.Requester] = []
    with heavy.requester(7, "verify", 2):
        import asyncio
        asyncio.run(asyncio.to_thread(lambda: seen.append(heavy.current_requester())))  # the daemon's check threads
        t = threading.Thread(target=lambda: seen.append(heavy.current_requester()))  # a bare thread sees the environment
        t.start()
        t.join()
    assert seen == [heavy.Requester("7", "verify", 2), heavy.Requester("42", "ci-fix", 1)]
    # and a stage session's Bash gets the environment from agent.sanitized_env
    from starpipe import agent
    env = agent.sanitized_env(9, stage="conflict", ticket_priority=0)
    assert (env["STARPIPE_TICKET"], env["STARPIPE_STAGE"], env["STARPIPE_TICKET_PRIORITY"]) == ("9", "conflict", "0")
    # a queued job records it, and `heavy --status` shows it
    holder = starpipe("heavy", "--", sys.executable, "-c", "import time;time.sleep(30)")
    try:
        assert wait_until(lambda: len(heavy.status().holders) == 1)
        waiter = starpipe("heavy", "--", sys.executable, "-c", "pass")  # inherits STARPIPE_TICKET/STAGE from os.environ
        assert wait_until(lambda: len(heavy.status().queue) == 1)
        w = heavy.status().queue[0]
        assert (w.ticket, w.stage, w.ticket_priority, w.job_class) == ("42", "ci-fix", 1, "exclusive")
        out = starpipe("heavy", "--status").communicate(timeout=30)[0]
        assert "42 ci-fix" in out and "[exclusive]" in out
    finally:
        holder.kill()
        holder.wait()
    waiter.wait(30)


def test_a_holder_running_the_old_one_slot_lock_still_excludes_tests_and_exclusive_jobs() -> None:
    import fcntl
    import os
    fd = os.open(heavy.locks_dir() / "heavy.slot0", os.O_RDWR | os.O_CREAT, 0o644)  # what the old acquire() flocks
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    try:
        assert granted([W(1, heavy.TEST)]) == [] and granted([W(1, heavy.EXCLUSIVE)]) == []
        assert granted([W(1, heavy.BUILD)]) == [1]
    finally:
        os.close(fd)
    assert granted([W(1, heavy.TEST)]) == [1]


def test_ui_test_runs_are_told_from_unit_test_runs() -> None:
    from starpipe.adapter_star import drives_display

    ui = [
        ["xcodebuild", "test", "-scheme", "star"],  # the whole scheme includes starUITests
        ["xcodebuild", "test", "-only-testing:starUITests/GeneratedFeatureUITests/testFoo"],
        ["xcodebuild", "test", "-only-testing:starTests", "-only-testing:starUITests"],
        ["bash", "-c", "cd gui && FOO=1 xcodebuild test-without-building -scheme star | tail"],
    ]
    other = [
        ["xcodebuild", "test", "-only-testing:starTests"],
        ["xcodebuild", "-scheme", "star", "build"],
        ["swift", "test", "--package-path", "cli"],
        ["bash", "-c", "xcodebuild -scheme star build && echo done"],
        ["bash", "-c", "unbalanced \"quote"],
    ]
    assert [a for a in ui if not drives_display(a)] == []
    assert [a for a in other if drives_display(a)] == []


def test_idle_gate_waits_for_the_owner_to_leave() -> None:
    from starpipe import idle

    now = [0.0]
    slept: list[float] = []
    said: list[str] = []

    def sleep(s: float) -> None:
        slept.append(s)
        now[0] += s

    waited = idle.wait_until_idle(600, poll_s=15, report=said.append, read=lambda: 2.0 if now[0] < 30 else 650.0, sleep=sleep, clock=lambda: now[0])
    assert slept == [15, 15] and waited == 30 and len(said) == 1
    assert idle.is_idle(600, lambda: None)  # unreadable: never hold work for ever
    assert not idle.is_idle(600, lambda: 5.0)


def test_a_ui_job_is_held_until_idle_and_ui_now_skips_that(monkeypatch: pytest.MonkeyPatch, state_home: Path) -> None:
    from starpipe import idle

    split_config(state_home)
    monkeypatch.delenv("STARPIPE_UI_NOW", raising=False)
    calls: list[float] = []
    monkeypatch.setattr(idle, "wait_until_idle", lambda need, **_kw: calls.append(need) or 7.0)
    monkeypatch.setattr(idle, "is_idle", lambda *_a, **_kw: True)
    ui = [sys.executable, "-c", "pass"]
    assert heavy.run_job(ui).waited < 7.0 and calls == []  # not an xcodebuild test: no gate
    monkeypatch.setattr("starpipe.adapter_star.drives_display", lambda _argv: True)
    assert heavy.run_job(ui).waited >= 7.0 and calls == [600.0]
    monkeypatch.setenv("STARPIPE_UI_NOW", "1")
    heavy.run_job(ui)
    assert calls == [600.0]


def test_freeze_holds_every_slot_until_thawed(state_home: Path) -> None:
    from starpipe import pause
    from starpipe.config import load

    split_config(state_home)
    names = heavy._all_slots(load())  # pyright: ignore[reportPrivateUsage]
    pause.pause()
    try:
        assert wait_until(lambda: not heavy._free(names))  # pyright: ignore[reportPrivateUsage]
        assert pause.paused_pid() is not None
    finally:
        assert pause.resume()
    assert wait_until(lambda: heavy._free(names) == set(names))  # pyright: ignore[reportPrivateUsage]
    assert pause.paused_pid() is None
