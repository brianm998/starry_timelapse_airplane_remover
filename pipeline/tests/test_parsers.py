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
