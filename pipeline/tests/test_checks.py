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
