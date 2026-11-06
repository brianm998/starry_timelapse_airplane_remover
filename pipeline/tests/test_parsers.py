from __future__ import annotations

from pathlib import Path

from starpipe.checks import parsers

XC_GREEN = """Test Suite 'All tests' passed at 2026-10-30 10:00:00.000.
\t Executed 12 tests, with 0 failures (0 unexpected) in 0.5 (0.5) seconds
Test Suite 'Foo.xctest' passed at x
\t Executed 12 tests, with 0 failures (0 unexpected) in 0.5 (0.5) seconds
Test Suite 'Foo' passed at x
\t Executed 5 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds
"""


def test_xctest_total_is_the_largest_nested_line() -> None:
    c = parsers.parse_xctest(XC_GREEN)
    assert (c.executed, c.failed, c.skipped) == (12, 0, 0)


def test_xctest_bundle_total_with_skips_is_read() -> None:
    """#249: a bundle banner with skips ("with 7 tests skipped and 0 failures") did not match, so a smaller per-suite line (47)
    was taken as the total."""
    log = ("\t Executed 47 tests, with 0 failures (0 unexpected) in 1.0 (1.0) seconds\n"
           "Test Suite 'StarCppTests.xctest' passed at x\n"
           "\t Executed 254 tests, with 7 tests skipped and 0 failures (0 unexpected) in 9.0 (9.0) seconds\n")
    c = parsers.parse_xctest(log)
    assert (c.executed, c.failed) == (254, 0)
    one = parsers.parse_xctest("\t Executed 9 tests, with 1 test skipped and 1 failure (1 unexpected) in 1.0 (1.0) seconds\n")
    assert (one.executed, one.failed) == (9, 1)


def test_zero_tests_is_vacuous_even_with_a_green_banner() -> None:
    c = parsers.parse_xctest("Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds\n** TEST SUCCEEDED **")
    assert c.vacuous


def test_no_summary_at_all_is_vacuous() -> None:
    assert parsers.parse_xctest("** TEST SUCCEEDED **\n").vacuous


def test_carriage_returns_do_not_hide_the_count() -> None:
    assert parsers.parse_xctest("Executed 3 tests, with 1 failure (1 unexpected)\r\n").failed == 1


def test_skips_for_missing_fixtures_and_opt_in_measurements_are_expected() -> None:
    """Found live: 8 StarCore tests skip on this Mac (horizon fixtures not in the repo, opt-in measurements), so every ticket that
    touched StarCore failed its checks with `skipped-tests` and parked."""
    expected = ("/w/H.swift:472: -[StarCoreTests.H a] : Test skipped - no horizon test sequence found — not in the repo\n"
                "Test Case '-[StarCoreTests.H a]' skipped (0.001 seconds).\n"
                "/w/C.swift:48: -[StarCoreTests.C b] : Test skipped - no horizon reference fixtures present\n"
                "Test Case '-[StarCoreTests.C b]' skipped (0.001 seconds).\n"
                "/w/S.swift:7: -[StarCoreTests.S c] : Test skipped - opt-in\n"
                "Test Case '-[StarCoreTests.S c]' skipped (0.001 seconds).\n"
                "/w/T.swift:17: -[StarCoreTests.T d] : Test skipped - set STAR_MEASURE_TIFF to a night frame to run this\n"
                "Test Case '-[StarCoreTests.T d]' skipped (0.001 seconds).\n"
                "/w/Q.swift:41: -[StarCppBridgeTests.Q e] : Test skipped - GCD's width narrowing for DISPATCH_APPLY_AUTO was only "
                "measured on Apple silicon\n"
                "Test Case '-[StarCppBridgeTests.Q e]' skipped (0.001 seconds).\n"
                "/w/G.swift:327: -[StarCppBridgeTests.G f] : Test skipped - run with 'swift test -c release' -- see doc comment\n"
                "Test Case '-[StarCppBridgeTests.G f]' skipped (0.001 seconds).\n"
                "/w/U.swift:528: -[StarCppBridgeTests.U g] : Test skipped - a discrete GPU always copies\n"
                "Test Case '-[StarCppBridgeTests.U g]' skipped (0.001 seconds).\n"
                "/w/K.swift:24: -[StarCppBridgeTests.K h] : Test skipped - set STAR_KP_MEASURE=1\n"
                "Test Case '-[StarCppBridgeTests.K h]' skipped (0.000 seconds).\n"
                "/w/R.swift:23: -[StarDaemonTests.R i] : Test skipped - STAR_REAL_SEQUENCE_DIR is not set to a folder of frames\n"
                "Test Case '-[StarDaemonTests.R i]' skipped (0.001 seconds).\n"
                "/w/B.swift:175: -[StarDaemonTests.B j] : Test skipped - NSHomeDirectory() ignores $HOME on this machine\n"
                "Test Case '-[StarDaemonTests.B j]' skipped (0.001 seconds).\n")
    assert parsers.parse_xctest(XC_GREEN + expected).skipped == 0
    other = ("/w/X.swift:9: -[StarCoreTests.X e] : Test skipped - the decoder is not available\n"
             "Test Case '-[StarCoreTests.X e]' skipped (0.001 seconds).\n")
    assert parsers.parse_xctest(XC_GREEN + expected + other).skipped == 1, "any other reason still counts"


def test_skipped_tests_are_counted() -> None:
    text = XC_GREEN + "Test Case '-[A b]' skipped (0.001 seconds).\n"
    assert parsers.parse_xctest(text).skipped == 1


def test_swift_testing_run_line_is_added() -> None:
    c = parsers.parse_xctest(XC_GREEN + "✔ Test run with 4 tests in 1 suites passed after 0.002 seconds.\n")
    assert c.executed == 16


def test_gradle_junit_xml(tmp_path: Path) -> None:
    (tmp_path / "a.xml").write_text('<testsuite tests="5" failures="1" errors="0" skipped="2"/>')
    (tmp_path / "b.xml").write_text('<testsuite tests="3" failures="0" errors="1" skipped="0"/>')
    c = parsers.parse_gradle(tmp_path)
    assert (c.executed, c.failed, c.skipped) == (8, 2, 2)


def test_gradle_with_no_results_is_vacuous(tmp_path: Path) -> None:
    assert parsers.parse_gradle(tmp_path).vacuous


def test_pytest_summary() -> None:
    c = parsers.parse_pytest("..F\n1 failed, 2 passed, 1 skipped in 0.12s\n")
    assert (c.executed, c.failed, c.skipped) == (4, 1, 1)


def test_diff_check_compares_with_where_the_branch_left_develop_not_with_its_moving_tip(tmp_path: Path) -> None:
    """Found live (#59): develop gained a commit that cleaned up a file, and `git diff --check <tip>` then reported the branch's
    untouched, older copy of that file as added lines with trailing whitespace."""
    import subprocess

    from starpipe import adapter_star
    from starpipe.checks import runner

    def sh(*argv: str) -> None:
        subprocess.run(argv, cwd=tmp_path, check=True, capture_output=True)

    sh("git", "init", "-q", "-b", "develop")
    sh("git", "config", "user.email", "t@t")
    sh("git", "config", "user.name", "t")
    (tmp_path / "f.txt").write_text("dirty \n")  # already on develop when the branch is cut
    sh("git", "add", "-A")
    sh("git", "commit", "-q", "-m", "base")
    sh("git", "checkout", "-q", "-b", "pipe/1")
    (tmp_path / "g.txt").write_text("clean\n")
    sh("git", "add", "-A")
    sh("git", "commit", "-q", "-m", "ticket")
    sh("git", "checkout", "-q", "develop")
    (tmp_path / "f.txt").write_text("clean\n")  # develop moves on
    sh("git", "commit", "-qam", "tidy")
    sh("git", "checkout", "-q", "pipe/1")
    spec = adapter_star.CHECKS["t0:diff-check"]
    argv = runner._argv(spec, tmp_path, "develop")  # pyright: ignore[reportPrivateUsage]
    assert subprocess.run(argv, check=False, cwd=tmp_path, capture_output=True).returncode == 0
    assert subprocess.run(["git", "diff", "--check", "develop"], check=False, cwd=tmp_path, capture_output=True).returncode != 0, "the old form"


XC_RED = """Test Case '-[StarCppTests.OpenCVQoSTests testLowQoSUsesFewerWorkersThanNormalQoS]' started.
/w/Q.swift:41: error: -[StarCppTests.OpenCVQoSTests testLowQoSUsesFewerWorkersThanNormalQoS] : XCTAssertLessThan failed
Test Case '-[StarCppTests.OpenCVQoSTests testLowQoSUsesFewerWorkersThanNormalQoS]' failed (0.113 seconds).
Test Case '-[StarCppTests.OtherTests testFine]' passed (0.001 seconds).
Test Case '-[StarCppTests.VideoConvertTests testStockFFmpeg]' failed (2.0 seconds).
Test Case '-[StarCppTests.OpenCVQoSTests testLowQoSUsesFewerWorkersThanNormalQoS]' failed (0.113 seconds).
\t Executed 3 tests, with 3 failures (0 unexpected) in 2.1 (2.1) seconds
"""


def test_xctest_failures_are_named() -> None:
    c = parsers.parse_xctest(XC_RED)
    assert c.failures == ["StarCppTests.OpenCVQoSTests.testLowQoSUsesFewerWorkersThanNormalQoS",
                          "StarCppTests.VideoConvertTests.testStockFFmpeg"]  # once each, though XCTest prints a failure twice
    assert parsers.parse_xctest(XC_GREEN).failures == []
    named = parsers.parse_xctest("Test Case '-[A.B testOne]' failed (0.1 seconds).\n"
                                 "Test Case '-[A.B testTwo]' failed (0.1 seconds).\n"
                                 "\t Executed 4 tests, with 2 failures (0 unexpected) in 1 (1) seconds\n")
    assert named.failures == ["A.B.testOne", "A.B.testTwo"] and named.failed == 2


def test_pytest_and_gradle_failures_are_named(tmp_path: Path) -> None:
    out = parsers.parse_pytest("FAILED tests/test_a.py::test_x - assert 1 == 2\n1 failed, 3 passed in 0.5s\n")
    assert out.failures == ["tests/test_a.py::test_x"] and out.failed == 1
    (tmp_path / "TEST-a.xml").write_text(
        '<testsuite tests="2" failures="1" errors="0" skipped="0"><testcase classname="a.B" name="ok"/>'
        '<testcase classname="a.B" name="bad"><failure message="m"/></testcase></testsuite>')
    assert parsers.parse_gradle(tmp_path).failures == ["a.B.bad"]
