from __future__ import annotations

import os
import stat
import sys
import threading
import time
from pathlib import Path

import pytest

from starpipe import adapter_star as star
from starpipe.checks import ledger, runner

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
