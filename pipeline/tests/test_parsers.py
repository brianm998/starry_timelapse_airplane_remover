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
                "Test Case '-[StarCoreTests.T d]' skipped (0.001 seconds).\n")
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
