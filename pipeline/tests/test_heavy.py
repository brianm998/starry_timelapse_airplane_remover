from __future__ import annotations

import os
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


def test_exit_code_is_preserved() -> None:
    p = starpipe("heavy", "--", sys.executable, "-c", "raise SystemExit(7)")
    assert p.wait(30) == 7


def wait_until(condition: Callable[[], bool], timeout: float = 20.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.1)
    return False


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


def test_a_child_is_killed_if_the_wait_is_interrupted() -> None:
    import threading

    started = threading.Event()
    pids: list[int] = []

    def work() -> None:
        popen: Any = subprocess.Popen
        real_wait = popen.wait

        def interrupted(self: Any, timeout: float | None = None) -> int:
            if not started.is_set() and self.args[1:2] == ["run"]:  # the job's `mason run`, not the probe of masond
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


FAST = Config(heavy_idle_kill_s=1.5, heavy_idle_grace_s=1.0, heavy_idle_poll_s=0.2)


def test_idle_job_is_killed_and_lock_released() -> None:
    start = time.monotonic()
    result = heavy.run_job([sys.executable, "-c", "import time;time.sleep(60)"], config=FAST)
    assert time.monotonic() - start < 20
    assert result.code != 0
    assert result.hung is not None and "time.sleep(60)" in result.hung.cmd and result.hung.idle_s >= FAST.heavy_idle_kill_s


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
        if not interrupted and self.args[1:2] == ["run"]:
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
    assert result.cpu_mean > 0.05 and result.cpu_peak >= result.cpu_mean
    assert result.rss_peak_mb >= 100 and result.seconds >= 2.0
    # the ledger row keeps it, and a row from before these fields still loads
    ledger.record(ledger.Result("c", "pass", "sha1", 1.0, cpu_mean=result.cpu_mean, cpu_peak=result.cpu_peak,
                                rss_peak_mb=result.rss_peak_mb))
    got = ledger.latest("sha1", "c")
    assert got is not None and got.rss_peak_mb == result.rss_peak_mb and got.cpu_peak == result.cpu_peak
    (state_home / "results.jsonl").write_text('{"check": "old", "status": "pass", "sha": "s0", "seconds": 1.0}\n')
    old = ledger.latest("s0", "old")
    assert old is not None and old.cpu_mean == 0.0 and old.rss_peak_mb == 0.0


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
    from starpipe.config import load

    monkeypatch.delenv("STARPIPE_UI_NOW", raising=False)
    calls: list[float] = []

    def fake_wait(need: float, **_kw: object) -> float:
        calls.append(need)
        return 7.0

    def fake_is_idle(*_a: object, **_kw: object) -> bool:
        return True

    def fake_drives_display(_argv: list[str]) -> bool:
        return True

    monkeypatch.setattr(idle, "wait_until_idle", fake_wait)
    monkeypatch.setattr(idle, "is_idle", fake_is_idle)
    ui = [sys.executable, "-c", "pass"]
    assert heavy.run_job(ui).waited < 7.0 and calls == []  # not an xcodebuild test: no gate
    monkeypatch.setattr("starpipe.adapter_star.drives_display", fake_drives_display)
    idle_mode = load().model_copy(update={"ui_local": "idle"})
    assert heavy.run_job(ui, config=idle_mode).waited >= 7.0 and calls == [600.0]
    monkeypatch.setenv("STARPIPE_UI_NOW", "1")
    monkeypatch.delenv("STARPIPE_TICKET", raising=False)
    heavy.run_job(ui, config=idle_mode)
    assert calls == [600.0]


def test_a_ui_job_is_refused_by_default_and_a_ticket_cannot_override_that(monkeypatch: pytest.MonkeyPatch, state_home: Path, tmp_path: Path) -> None:
    def fake_drives_display(_argv: list[str]) -> bool:
        return True

    monkeypatch.setattr("starpipe.adapter_star.drives_display", fake_drives_display)
    monkeypatch.delenv("STARPIPE_UI_NOW", raising=False)
    monkeypatch.delenv("STARPIPE_TICKET", raising=False)
    ran = tmp_path / "ran"
    job = [sys.executable, "-c", f"open({str(ran)!r}, 'w')"]
    said: list[str] = []
    assert heavy.run_job(job, report=said.append).code == heavy.UI_TESTS_REFUSED
    assert not ran.exists() and "NOT RUN" in said[0]
    monkeypatch.setenv("STARPIPE_UI_NOW", "1")
    monkeypatch.setenv("STARPIPE_TICKET", "430")
    assert heavy.run_job(job, report=said.append).code == heavy.UI_TESTS_REFUSED and not ran.exists()
    monkeypatch.delenv("STARPIPE_TICKET")
    assert heavy.run_job(job).code == 0 and ran.exists()  # the owner, deliberately


def _shim(name: str, args: list[str], home: Path, **env: str) -> subprocess.CompletedProcess[str]:
    shim = Path(__file__).resolve().parent.parent / "shims" / name
    fake = home / "fake-tool"
    fake.write_text('#!/bin/bash\necho "ran: $*"\n')
    fake.chmod(0o755)
    full = {"PATH": f"{home}:/usr/bin:/bin", "STARPIPE_HOME": str(home), "STARPIPE_REAL_XCODEBUILD": str(fake),
            "STARPIPE_REAL_CAFFEINATE": str(fake),
            **{k: os.environ[k] for k in ("STARPIPE_MASON", "FAKE_MASON_LOG", "FAKE_MASON_DIR") if k in os.environ}, **env}  # the fake mason, never masond
    return subprocess.run([str(shim), *args], capture_output=True, text=True, env=full, check=False)


def test_the_xcodebuild_shim_refuses_ui_runs_and_passes_the_rest(tmp_path: Path) -> None:
    ui = ["test", "-only-testing:starUITests/GeneratedFeatureUITests/testFoo"]
    assert _shim("xcodebuild", ui, tmp_path).returncode == 69
    assert _shim("xcodebuild", ["test", "-scheme", "star"], tmp_path).returncode == 69  # the whole scheme includes the UI tests
    assert _shim("xcodebuild", ui, tmp_path, STARPIPE_UI_NOW="1", STARPIPE_TICKET="430").returncode == 69
    assert "ran:" in _shim("xcodebuild", ui, tmp_path, STARPIPE_UI_NOW="1").stdout
    assert "ran:" in _shim("xcodebuild", ["-only-testing:starTests", "test"], tmp_path).stdout
    assert "ran:" in _shim("xcodebuild", ["-scheme", "star", "build"], tmp_path).stdout
    (tmp_path / "config.toml").write_text('ui_local = "always"\n')
    assert "ran:" in _shim("xcodebuild", ui, tmp_path).stdout


def test_the_caffeinate_shim_never_wakes_the_display_for_unit_tests(tmp_path: Path) -> None:
    (tmp_path / "xcodebuild").write_text('#!/bin/bash\necho "bare: $*"\n')
    (tmp_path / "xcodebuild").chmod(0o755)
    unit = ["-d", "-u", "xcodebuild", "-only-testing:starTests", "test"]
    assert _shim("caffeinate", unit, tmp_path).stdout.strip() == "bare: -only-testing:starTests test"
    assert _shim("caffeinate", ["-i", "-w", "928"], tmp_path).stdout.strip() == "ran: -i -w 928"
    ui = ["-d", "-u", "xcodebuild", "-only-testing:starUITests/X", "test"]
    assert _shim("caffeinate", ui, tmp_path).stdout.strip().startswith("ran: -d -u")




# --- masond: argv per caller kind, and masond unreachable (ticket #169) ---------------------------------------------

def mason_lines(log: Path) -> list[list[str]]:
    return [line.split()[1:] for line in log.read_text().splitlines() if line.startswith("run ")]


def test_a_ticket_stage_job_ranks_as_starpipes_with_its_class(monkeypatch: pytest.MonkeyPatch, fake_mason: Path) -> None:
    monkeypatch.setenv("STARPIPE_TICKET", "42")
    monkeypatch.setenv("STARPIPE_STAGE", "ci-fix")
    monkeypatch.setenv("STARPIPE_TICKET_PRIORITY", "1")
    for kind, flags in ((heavy.BUILD, ["--needs", "compile"]), (heavy.TEST, ["--needs", "test-suite"]), (heavy.EXCLUSIVE, ["--needs", "exclusive", "--exclusive"])):
        fake_mason.write_text("")
        assert heavy.run_job([sys.executable, "-c", "pass"], config=CFG, job_class=kind).code == 0
        (line,) = mason_lines(fake_mason)
        sep = line.index("--", 2)
        head = line[1:sep]
        assert head[: len(flags)] == flags
        assert head[-6:] == ["--pipeline", "starpipe", "--priority", "high", "--progress", str(heavy.PROGRESS["ci-fix"])]
        assert "--label" in head and "starpipe #42 ci-fix" in " ".join(head)
        assert sys.executable in line[sep + 1:]  # after the start-marker wrapper


def test_a_persons_session_names_no_pipeline(fake_mason: Path) -> None:
    assert heavy.run_job([sys.executable, "-c", "pass"], config=CFG, job_class=heavy.TEST).code == 0
    (line,) = mason_lines(fake_mason)
    assert "--pipeline" not in line and "--priority" not in line and "--progress" not in line
    assert line[1:3] == ["--needs", "test-suite"]


def test_a_mason_task_runs_mason_plainly(monkeypatch: pytest.MonkeyPatch, fake_mason: Path) -> None:
    monkeypatch.setenv("MASON_TASK", "161")
    monkeypatch.setenv("STARPIPE_TICKET", "42")  # even if a ticket's variables leaked in
    assert heavy.run_job([sys.executable, "-c", "pass"], config=CFG, job_class=heavy.BUILD).code == 0
    (line,) = mason_lines(fake_mason)
    assert "--pipeline" not in line and "--priority" not in line and "--progress" not in line
    assert line[1:3] == ["--needs", "compile"]


def test_the_jobs_exit_code_comes_back_through_mason() -> None:
    assert heavy.run_job([sys.executable, "-c", "raise SystemExit(7)"], config=CFG).code == 7


def test_the_queue_wait_is_counted_and_not_mistaken_for_idle(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("FAKE_MASON_WAIT", "3")  # queued in masond for 3 s: longer than the idle limit, but nothing is running
    result = heavy.run_job([sys.executable, "-c", "pass"], config=FAST)
    assert result.code == 0 and result.hung is None and result.waited >= 2.5


def test_status_reads_masonds_holders(fake_mason: Path) -> None:
    assert heavy.status().holders == []
    (fake_mason.parent / "holders").touch()
    (holder,) = heavy.status().holders
    assert holder.ticket == "starpipe #7 develop" and holder.slots == ["compile=1"]


def test_with_masond_unreachable_the_job_waits_says_so_and_never_runs(monkeypatch: pytest.MonkeyPatch, fake_mason: Path,
                                                                      tmp_path: Path) -> None:
    from starpipe import masonq

    (fake_mason.parent / "down").touch()
    ran = tmp_path / "ran"
    said: list[str] = []
    slept: list[float] = []
    clock = [0.0]

    def sleep(seconds: float) -> None:
        slept.append(seconds)
        clock[0] += seconds
        if clock[0] > 700:  # masond comes back after the alert
            (fake_mason.parent / "down").unlink()

    alerts: list[str] = []
    waited = masonq.wait_reachable(said.append, alerts.append, sleep=sleep, clock=lambda: clock[0])
    assert waited > 700 and len(alerts) == 1 and "unreachable" in alerts[0]
    assert said and all("masond cannot be reached" in m for m in said) and max(slept) <= masonq.RETRY_MAX_S
    assert not ran.exists() and mason_lines(fake_mason) == []
    # and run_job itself waits before queueing: nothing is run while down
    (fake_mason.parent / "down").touch()
    attempts: list[int] = []

    def flaky_sleep(_s: float) -> None:
        attempts.append(1)
        if len(attempts) == 3:
            (fake_mason.parent / "down").unlink()
        assert not mason_lines(fake_mason)  # the job has not been queued, let alone run, while masond is down

    monkeypatch.setattr(masonq, "_sleep", flaky_sleep)
    messages: list[str] = []
    result = heavy.run_job([sys.executable, "-c", f"open({str(ran)!r}, 'w')"], config=CFG, report=messages.append)
    assert result.code == 0 and ran.exists() and len(attempts) == 3 and len(messages) == 3
    assert len(mason_lines(fake_mason)) == 1



def test_a_job_mason_already_holds_runs_without_queueing_again(monkeypatch: pytest.MonkeyPatch, fake_mason: Path,
                                                                tmp_path: Path) -> None:
    """A landing batch's suite holds what MASON_HELD names; queueing it in masond again would wait behind its own slots."""
    ran = tmp_path / "ran"
    job = [sys.executable, "-c", f"open({str(ran)!r}, 'w')"]
    monkeypatch.setenv("MASON_HELD", "test-suite")
    (fake_mason.parent / "down").touch()  # it does not even wait for masond
    for kind in (heavy.BUILD, heavy.TEST, heavy.EXCLUSIVE):
        ran.unlink(missing_ok=True)
        assert heavy.run_job(job, config=CFG, job_class=kind).code == 0 and ran.exists()
    assert mason_lines(fake_mason) == []
    assert heavy.run_job([sys.executable, "-c", "raise SystemExit(5)"], config=CFG).code == 5  # its exit code still comes back


def test_a_mason_tasks_test_step_still_queues(monkeypatch: pytest.MonkeyPatch, fake_mason: Path) -> None:
    """A task's test step that runs the project's `test` command holds nothing in masond: its jobs must queue."""
    monkeypatch.setenv("MASON_TASK", "169")
    monkeypatch.setenv("MASON_STEP", "test")
    monkeypatch.setenv("MASON_HELD", "")
    assert heavy.run_job([sys.executable, "-c", "pass"], config=CFG, job_class=heavy.TEST).code == 0
    (line,) = mason_lines(fake_mason)
    assert line[1:3] == ["--needs", "test-suite"]


def test_admitted_reads_only_mason_held() -> None:
    from starpipe import masonq

    assert masonq.admitted({"MASON_HELD": "compile"})
    assert not masonq.admitted({"MASON_HELD": " "})
    assert not masonq.admitted({"MASON_TASK": "1", "MASON_STEP": "test"})
    assert not masonq.admitted({})


def _no_sleep(_seconds: float) -> None:
    pass


def test_a_dropped_request_is_queued_again_until_the_job_runs(monkeypatch: pytest.MonkeyPatch, fake_mason: Path, tmp_path: Path) -> None:
    """masond reaps a waiting request whose poll comes late; `mason run` then exits 1 without running the job (#169, 2026-11-12)."""
    from starpipe import masonq

    slept: list[float] = []
    monkeypatch.setattr(masonq, "_sleep", slept.append)
    (fake_mason.parent / "drop").write_text("2")
    ran = tmp_path / "ran"
    said: list[str] = []
    result = heavy.run_job([sys.executable, "-c", f"open({str(ran)!r}, 'a').write('x')"], config=CFG, report=said.append,
                           job_class=heavy.TEST)
    assert result.code == 0 and ran.read_text() == "x"  # it ran exactly once
    assert len(mason_lines(fake_mason)) == 3 and len(said) == 2 and all("dropped the queued request" in m for m in said)
    assert slept == [masonq.RETRY_S, masonq.RETRY_S * 2]


def test_a_job_that_ran_and_failed_is_not_queued_again(monkeypatch: pytest.MonkeyPatch, fake_mason: Path) -> None:
    from starpipe import masonq

    monkeypatch.setattr(masonq, "_sleep", _no_sleep)
    assert heavy.run_job([sys.executable, "-c", "raise SystemExit(1)"], config=CFG).code == 1
    assert len(mason_lines(fake_mason)) == 1


def test_requests_dropped_again_and_again_fail_the_run(monkeypatch: pytest.MonkeyPatch, fake_mason: Path, tmp_path: Path) -> None:
    from starpipe import masonq

    monkeypatch.setattr(masonq, "_sleep", _no_sleep)
    (fake_mason.parent / "drop").write_text("99")
    ran = tmp_path / "ran"
    result = heavy.run_job([sys.executable, "-c", f"open({str(ran)!r}, 'w')"], config=CFG)
    assert result.code == 1 and not ran.exists()
    assert len(mason_lines(fake_mason)) == heavy.REQUEUE_MAX + 1
