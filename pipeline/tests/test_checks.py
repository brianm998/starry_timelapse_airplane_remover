from __future__ import annotations

import os
import stat
import sys
import threading
import time
from pathlib import Path

import pytest

from starpipe import adapter_star as star
from starpipe import heavy, worktrees
from starpipe.checks import ledger, runner
from starpipe.config import Config
from starpipe.contracts import Contract
from starpipe.db import Database

from .fakes import GOOD_BODY, make_repo

FAST = Config(heavy_idle_kill_s=1.0, heavy_idle_grace_s=1.0, heavy_idle_poll_s=0.2)

# A stand-in for `swift test` that behaves as xctest does: it prints a test's start line through ordinary buffered stdio, so
# the line reaches a file only when the buffer is flushed or the process exits. It then blocks, as a hung test does.
FAKE_SWIFT = f"""#!{sys.executable}
import os, sys, time
print("Test Case '-[StarDaemonTests.FakeTests testHang]' started.")
release = os.environ["FAKE_SWIFT_RELEASE"]
deadline = time.time() + 60
while not os.path.exists(release) and time.time() < deadline:
    time.sleep(0.05)
print("Test Case '-[StarDaemonTests.FakeTests testHang]' passed (0.1 seconds).")
print("\\t Executed 1 test, with 0 failures (0 unexpected) in 0.1 (0.1) seconds")
sys.exit(int(os.environ.get("FAKE_SWIFT_EXIT", "0")))
"""


def _fake_swift(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    swift = bin_dir / "swift"
    swift.write_text(FAKE_SWIFT)
    swift.chmod(swift.stat().st_mode | stat.S_IXUSR)
    release = tmp_path / "release"
    monkeypatch.setenv("PATH", f"{bin_dir}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("FAKE_SWIFT_RELEASE", str(release))
    return release


def _run_daemon_check(tmp_path: Path) -> tuple[threading.Thread, list[ledger.Result], Path]:
    root = tmp_path / "repo"
    root.mkdir()
    log = tmp_path / "test_daemon.log"
    results: list[ledger.Result] = []

    def go() -> None:
        results.append(runner._run_command(star.CHECKS["test:daemon"], root, "HEAD", log, "0" * 40, False, lambda _m: None))  # pyright: ignore[reportPrivateUsage]

    thread = threading.Thread(target=go)
    thread.start()
    return thread, results, log


def test_daemon_test_log_names_the_running_test(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """A hung daemon test held the heavy lock for hours and the log did not say which test it was (#209)."""
    release = _fake_swift(tmp_path, monkeypatch)
    thread, results, log = _run_daemon_check(tmp_path)
    try:
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and "testHang" not in (log.read_text(errors="replace") if log.exists() else ""):
            time.sleep(0.1)
        seen_while_running = "testHang" in (log.read_text(errors="replace") if log.exists() else "")
        assert thread.is_alive(), "the fake swift test should still be running here"
        assert seen_while_running, "the log names no test while it runs, so a hang could not be traced to one"
    finally:
        release.write_text("go")
        thread.join(30)
    assert results and results[0].status == "pass" and results[0].executed == 1


def test_a_failing_daemon_test_run_is_still_red_through_the_pty(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Running under a pty must not turn the exit code into 0."""
    release = _fake_swift(tmp_path, monkeypatch)
    monkeypatch.setenv("FAKE_SWIFT_EXIT", "1")
    release.write_text("go")
    thread, results, _log = _run_daemon_check(tmp_path)
    thread.join(30)
    assert results and results[0].status == "fail"


def test_hung_check_is_reported_as_hung(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(heavy, "load", lambda: FAST)
    repo = make_repo(tmp_path)
    db = Database(tmp_path / "s.db")
    db.upsert_ticket(7, "Tidy docs", GOOD_BODY, "brianm998", 2, [])
    wt, branch = worktrees.create(repo, 7, "Tidy docs", "origin/develop")
    db.set_fields(7, worktree=str(wt), branch=branch)
    ticket = db.ticket(7)
    assert ticket
    spec = star.CheckSpec("test:wedged", "a wedged suite", (sys.executable, "-c", "import time;time.sleep(60)"))

    result = runner.run_spec(spec, wt, "origin/develop", tmp_path)
    assert result.status == "hung" and not result.green
    assert "made no progress" in result.detail and "time.sleep(60)" in result.detail and "rerun run_checks" in result.detail
    assert heavy.status().holders == [], "the lock was released"

    told = Contract(ticket, wt, "origin/develop", db, check_runner=lambda _w, _b: [result]).run_checks({})
    assert told.startswith("HUNG test:wedged") and "rerun run_checks" in told
    assert db.checks(7)[0]["result"] == "hung"


def _xunit_script(cases: list[tuple[str, str, str]], exit_code: int = 0) -> str:
    """A python program that writes the xunit file named by its first argument, like `swift test --xunit-output`."""
    body = "".join(
        f'<testcase classname="{cls}" name="{name}">'
        + {"pass": "", "fail": '<failure message="boom"/>', "skip": '<skipped message="Test skipped - nope"/>'}[kind]
        + "</testcase>"
        for cls, name, kind in cases
    )
    xml = f'<testsuites><testsuite name="TestResults">{body}</testsuite></testsuites>'
    return f"import sys;open(sys.argv[1],'w').write({xml!r});sys.exit({exit_code})"


def _wt(tmp_path: Path) -> Path:
    repo = make_repo(tmp_path)
    wt, _branch = worktrees.create(repo, 7, "Tidy docs", "origin/develop")
    return wt


def test_parallel_swift_test_counts_come_from_xunit(tmp_path: Path) -> None:
    wt = _wt(tmp_path)
    spec = star.CHECKS["test:StarCpp"]
    assert spec.parser == "xunit"
    assert "--parallel" in spec.argv and spec.argv[spec.argv.index("--num-workers") + 1] == "{workers}"
    assert spec.argv[spec.argv.index("--xunit-output") + 1].startswith("{log_dir}/")
    assert Config().heavy_test_workers == 8
    # the others keep the serial run and its banner: StarCore and daemon are slower in parallel (see SERIAL_CLASSES)
    for check_id in ("test:StarCore", "test:daemon", "test:cli"):
        assert star.CHECKS[check_id].parser == "xctest" and "--parallel" not in star.CHECKS[check_id].argv

    cases = [("A", "t1", "pass"), ("A", "t2", "pass"), ("B", "t3", "skip")]
    spec = star.CheckSpec("test:par", "parallel", (sys.executable, "-c", _xunit_script(cases), "{log_dir}/par.xml"),
                          parser="xunit", xunit=("{log_dir}/par.xml",))
    log_dir = tmp_path / "logs"
    log_dir.mkdir()
    result = runner.run_spec(spec, wt, "origin/develop", log_dir, allow_skips=True)
    assert result.green and (result.executed, result.failed, result.skipped) == (3, 0, 1)
    assert not runner.run_spec(spec, wt, "origin/develop", log_dir).green, "an unexpected skip is still red"

    # no xunit file at all (a crash before it was written) is red, not zero tests
    gone = star.CheckSpec("test:gone", "no file", (sys.executable, "-c", "pass"), parser="xunit", xunit=("{log_dir}/none.xml",))
    assert not runner.run_spec(gone, wt, "origin/develop", log_dir).green


def test_a_parallel_failure_is_red_and_named(tmp_path: Path) -> None:
    wt = _wt(tmp_path)
    cases = [("StarCoreTests.Foo", "testOk", "pass"), ("StarCoreTests.Foo", "testBroken", "fail")]
    spec = star.CheckSpec("test:par", "parallel", (sys.executable, "-c", _xunit_script(cases, 1), "{log_dir}/par.xml"),
                          parser="xunit", xunit=("{log_dir}/par.xml",))
    result = runner.run_spec(spec, wt, "origin/develop", tmp_path)
    assert result.status == "fail" and not result.green
    assert (result.executed, result.failed) == (2, 1)
    assert "StarCoreTests.Foo.testBroken" in result.detail and "testOk" not in result.detail

    # exit 0 with a failure in the file is still red
    spec = star.CheckSpec("test:par", "parallel", (sys.executable, "-c", _xunit_script(cases, 0), "{log_dir}/par.xml"),
                          parser="xunit", xunit=("{log_dir}/par.xml",))
    assert runner.run_spec(spec, wt, "origin/develop", tmp_path).status == "fail"


def test_serial_classes_run_in_their_own_pass(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    wt = _wt(tmp_path)
    monkeypatch.setitem(star.SERIAL_CLASSES, "test:StarCpp", ("TimingTests", "OtherTests"))
    spec = star.swift_test("StarCpp", tid="StarCpp")
    assert spec.argv.count("--skip") == 2 and "TimingTests" in spec.argv and "OtherTests" in spec.argv
    assert spec.serial_argv and spec.serial_argv[spec.serial_argv.index("--num-workers") + 1] == "1"
    assert [a for a in spec.serial_argv if a not in ("--filter",)].count("TimingTests") == 1
    assert spec.serial_argv.count("--filter") == 2 and "--skip" not in spec.serial_argv
    assert any(f.endswith("-serial.xml") for f in spec.xunit)
    # a suite with nothing to run alone has no second pass
    monkeypatch.setitem(star.SERIAL_CLASSES, "test:StarCpp", ())
    assert star.swift_test("StarCpp", tid="StarCpp").serial_argv == ()

    # run both passes: the counts add, and each pass is its own process
    first = _xunit_script([("A", "t1", "pass"), ("A", "t2", "pass")])
    second = _xunit_script([("TimingTests", "t3", "pass")])
    ran = tmp_path / "ran"
    marker = f"import sys;open({str(ran)!r},'a').write(sys.argv[1]+chr(10));"
    fake = star.CheckSpec(
        "test:two", "two passes", (sys.executable, "-c", marker + first, "{log_dir}/a.xml"), parser="xunit",
        xunit=("{log_dir}/a.xml", "{log_dir}/b.xml"),
        serial_argv=(sys.executable, "-c", marker + second, "{log_dir}/b.xml"),
    )
    log_dir = tmp_path / "logs"
    log_dir.mkdir()
    result = runner.run_spec(fake, wt, "origin/develop", log_dir)
    assert result.green and (result.executed, result.failed) == (3, 0)
    assert ran.read_text().splitlines() == [f"{log_dir}/a.xml", f"{log_dir}/b.xml"]

    # a failure in the serial pass is red and named
    bad = _xunit_script([("TimingTests", "testSlow", "fail")], 1)
    fake2 = star.CheckSpec("test:two", "two passes", fake.argv, parser="xunit", xunit=fake.xunit,
                           serial_argv=(sys.executable, "-c", bad, "{log_dir}/b.xml"))
    red = runner.run_spec(fake2, wt, "origin/develop", log_dir)
    assert red.status == "fail" and "TimingTests.testSlow" in red.detail


def test_run_plan_continues_past_a_red_test_check(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from starpipe.checks import impact

    repo = make_repo(tmp_path)
    ran: list[str] = []

    def fake(check_id: str, root: Path, base: str, log_dir: Path, **_k: object) -> ledger.Result:
        ran.append(check_id)
        return ledger.Result(check_id, "fail" if check_id in ("test:a", "build:z") else "pass", "s", 0.0)

    monkeypatch.setattr(runner, "run_check", fake)
    out = runner.run_plan(impact.Plan(builds=["build:a"], tests=["test:a", "test:b", "test:c"]), repo, "origin/develop", {"t1"})
    assert ran == ["build:a", "test:a", "test:b", "test:c"] and [r.check for r in out if not r.green] == ["test:a"]

    ran.clear()
    out = runner.run_plan(impact.Plan(builds=["build:z"], tests=["test:b"]), repo, "origin/develop", {"t1"})
    assert ran == ["build:z"], "a red build's tests could not run"
