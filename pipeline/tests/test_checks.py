from __future__ import annotations

import os
import re
import stat
import sys
import threading
import time
from collections.abc import Mapping
from pathlib import Path

import pytest

from starpipe import adapter_star as star
from starpipe import heavy, shards, worktrees
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

# The part of `swift` that starpipe.shards uses besides the tests themselves: the build, the bin path holding the .xctest
# bundle, and `swift test list`. $FAKE_CLASSES (space separated) are the test classes the package has.
FAKE_SWIFT_DISCOVERY = f"""#!{sys.executable}
import os, sys
if "list" in sys.argv:
    for cls in os.environ["FAKE_CLASSES"].split():
        print(f"FakeTests.{{cls}}/testOne")
elif "--show-bin-path" in sys.argv:
    print(os.environ["FAKE_BIN"])
sys.exit(0)
"""


def _install_fakes(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, xcrun_body: str, classes: str) -> None:
    """A fake `swift` (build, bin path, test list) and a fake `xcrun xctest` running `xcrun_body`, first on PATH."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(parents=True)
    for name, body in (("swift", FAKE_SWIFT_DISCOVERY), ("xcrun", xcrun_body)):
        tool = bin_dir / name
        tool.write_text(body)
        tool.chmod(tool.stat().st_mode | stat.S_IXUSR)
    bundle_dir = tmp_path / "debug"
    (bundle_dir / "FakePackageTests.xctest").mkdir(parents=True)
    monkeypatch.setenv("PATH", f"{bin_dir}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("FAKE_BIN", str(bundle_dir))
    monkeypatch.setenv("FAKE_CLASSES", classes)


def _fake_swift(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    plan = star.SHARDS["test:daemon"]
    classes = " ".join(["OtherTests", *(c for g in plan.concurrent for c in g), *plan.serial])
    _install_fakes(tmp_path, monkeypatch, FAKE_SWIFT, classes)
    release = tmp_path / "release"
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
    # the daemon check runs as shards, each launching the fake once, and its counts are summed
    assert results and results[0].status == "pass" and results[0].executed == len(star.CHECKS["test:daemon"].shard_logs)


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
    # the others keep the XCTest banner: StarCore and daemon are slower in parallel (see SERIAL_CLASSES), so they run as class shards
    for check_id in ("test:StarCore", "test:daemon", "test:cli"):
        assert star.CHECKS[check_id].parser == "xctest" and "--parallel" not in star.CHECKS[check_id].argv
    for check_id in ("test:StarCore", "test:daemon"):
        sharded = star.CHECKS[check_id]
        assert sharded.argv[1:3] == ("-m", "starpipe.shards") and "--shard" in sharded.argv
        assert sharded.argv[sharded.argv.index("--concurrency") + 1] == "{workers}"
        plan = star.SHARDS[check_id]
        assert len(sharded.shard_logs) == 1 + len(plan.concurrent) + len(plan.serial)
    assert "--serial-shard" in star.CHECKS["test:daemon"].argv and not star.CHECKS["test:cli"].shard_logs

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


def _banner(executed: int, failures: int = 0, skipped: int = 0, extra: str = "") -> str:
    skips = f" with {skipped} tests skipped and {failures} failures" if skipped else f" with {failures} failures"
    return f"{extra}Test Suite 'Selected tests' passed.\n\t Executed {executed} tests,{skips} (0 unexpected) in 1.0 (1.0) seconds\n"


def _shard_spec(tmp_path: Path, logs: Mapping[str, str | None]) -> star.CheckSpec:
    """A check whose process writes the given shard logs (None: never writes that one), as starpipe.shards does."""
    body = "".join(f"open({'{log_dir}/' + name!r}.format(log_dir=sys.argv[1]),'w').write({text!r});"
                   for name, text in logs.items() if text is not None)
    return star.CheckSpec("test:sharded", "sharded", (sys.executable, "-c", f"import sys;{body}", "{log_dir}"), parser="xctest",
                          shard_logs=tuple("{log_dir}/" + name for name in logs))


def test_sharded_check_sums_counts_across_shard_logs(tmp_path: Path) -> None:
    wt = _wt(tmp_path)
    skip = "Test Case '-[M.C testSkips]' skipped (0.0 seconds).\n"
    ok = {"a.log": _banner(10), "b.log": _banner(5, skipped=1, extra=skip + "Test Case '-[M.C testS]' skipped (0.0 seconds).\n")}
    # the banner of each shard is parsed on its own and summed (parse_xctest alone would keep the largest, 10)
    spec = _shard_spec(tmp_path, ok)
    result = runner.run_spec(spec, wt, "origin/develop", tmp_path, allow_skips=True)
    assert result.green and result.executed == 15 and result.skipped == 2
    assert not runner.run_spec(spec, wt, "origin/develop", tmp_path).green, "an unexpected skip is red"
    expected = "Test Case '-[M.C testSkips]' skipped (0.0 seconds).\n\t Test skipped - opt-in measurement\n"
    expected_spec = _shard_spec(tmp_path, {"a.log": _banner(10), "b.log": _banner(5, skipped=1, extra=expected)})
    assert runner.run_spec(expected_spec, wt, "origin/develop", tmp_path).green

    # a shard that never wrote its log (a crash before the banner) is red, not zero tests
    missing = runner.run_spec(_shard_spec(tmp_path, {"a.log": _banner(10), "gone.log": None}), wt, "origin/develop", tmp_path)
    assert missing.status == "fail" and "gone.log" in missing.detail
    # a stale log of an earlier run does not stand in for this run's
    runner.run_spec(_shard_spec(tmp_path, {"a.log": _banner(10), "b.log": _banner(5)}), wt, "origin/develop", tmp_path)
    assert not runner.run_spec(_shard_spec(tmp_path, {"a.log": _banner(10), "b.log": None}), wt, "origin/develop", tmp_path).green

    # a failing shard names its test
    bad = "Test Case '-[StarCoreTests.Foo testBroken]' failed (0.1 seconds).\n"
    failing = runner.run_spec(_shard_spec(tmp_path, {"a.log": _banner(10), "b.log": _banner(5, failures=1, extra=bad)}), wt,
                              "origin/develop", tmp_path)
    assert failing.status == "fail" and failing.executed == 15 and failing.failed == 1
    assert "StarCoreTests.Foo.testBroken" in failing.detail


def test_xctest_banner_with_skips_is_parsed() -> None:
    from starpipe.checks import parsers
    counts = parsers.parse_xctest("\t Executed 1625 tests, with 8 tests skipped and 0 failures (0 unexpected) in 398.7 (399.0) seconds\n")
    assert (counts.executed, counts.failed) == (1625, 0)


# A stand-in `xcrun xctest` for starpipe.shards: it records its start and end time and its class list, takes 0.6 s, prints a
# banner, and exits 1 when its classes include $FAKE_FAIL.
FAKE_SHARD_XCRUN = f"""#!{sys.executable}
import os, sys, time
classes = sys.argv[sys.argv.index("-XCTest") + 1]
start = time.time()
time.sleep(0.6)
open(os.environ["FAKE_RECORD"], "a").write(f"test {{start}} {{time.time()}} {{classes}}\\n")
print("\\t Executed 3 tests, with 0 failures (0 unexpected) in 0.6 (0.6) seconds")
fail = os.environ.get("FAKE_FAIL")
sys.exit(1 if fail and fail in classes.split(",") else 0)
"""


def _run_shards(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, fail: str = "",
                serial: tuple[str, ...] = ("SlowOne",)) -> tuple[int, list[list[str]], Path]:
    _install_fakes(tmp_path, monkeypatch, FAKE_SHARD_XCRUN, "ClassA ClassB ClassC SlowOne NewClass")
    record = tmp_path / "record"
    record.write_text("")
    monkeypatch.setenv("FAKE_RECORD", str(record))
    monkeypatch.setenv("FAKE_FAIL", fail)
    monkeypatch.setattr(shards, "_PTY", ())  # no pty in the test
    logs = tmp_path / "logs"
    code = shards.run("PKG", logs, "stem", 4, ["ClassA|ClassB", "ClassC"], list(serial))
    return code, [line.split() for line in record.read_text().splitlines()], logs


def test_shard_runner_runs_concurrent_shards_then_serial_ones(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    code, lines, logs = _run_shards(tmp_path, monkeypatch)
    assert code == 0
    tests = {line[3]: (float(line[1]), float(line[2])) for line in lines}
    assert len(tests) == 4, "one launch per shard"
    # the catch-all is every class of the bundle that no shard names, so a class added later is still run
    assert set(tests) == {"NewClass", "ClassA,ClassB", "ClassC", "SlowOne"}
    serial = tests["SlowOne"]
    concurrent = [v for cls, v in tests.items() if cls != "SlowOne"]
    assert max(v[0] for v in concurrent) < min(v[1] for v in concurrent), "the concurrent shards overlap in time"
    assert serial[0] >= max(v[1] for v in concurrent), "a serial shard starts after every concurrent one ended"
    assert all((logs / f"stem.shard{k}.log").read_text().count("Executed 3 tests") == 1 for k in range(4))


def test_shard_runner_fails_when_any_shard_fails(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    code, lines, _logs = _run_shards(tmp_path, monkeypatch, fail="SlowOne")
    assert code != 0 and len(lines) == 4, "every shard still ran"
    assert _run_shards(tmp_path / "again", monkeypatch, serial=("NoSuchClass",))[0] == 2, "a class the bundle lacks is an error"


def test_shard_table_names_only_real_test_classes() -> None:
    root = Path(__file__).resolve().parents[2]
    tests_dirs = {"test:StarCore": root / "StarCore/Tests", "test:daemon": root / "daemon/Tests"}
    for check_id, tests_dir in tests_dirs.items():
        found = {m for f in tests_dir.rglob("*.swift") for m in re.findall(r"^\s*(?:final\s+)?class\s+(\w+)\b", f.read_text(), re.MULTILINE)}
        plan = star.SHARDS[check_id]
        named = [c for group in plan.concurrent for c in group] + list(plan.serial)
        assert named and not set(named) - found, f"{check_id} names classes that do not exist: {set(named) - found}"
        assert len(named) == len(set(named)), "a class is in one shard only"
    assert "BackgroundExtractionSessionTests" in star.SHARDS["test:daemon"].serial
