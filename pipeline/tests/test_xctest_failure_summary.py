"""gherkin/summarize-xctest-failures.sh: what the failing mac gui xcodebuild step ends with."""

from __future__ import annotations

import subprocess
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "gherkin" / "summarize-xctest-failures.sh"
CLASS = "starUITests.GeneratedFeatureUITests"
RUNNER = "/Users/runner/work/star/star/gui/starUITests/GuiFeatureRunner.swift"


def started(test: str) -> str:
    return f"Test Case '-[{CLASS} {test}]' started.\n    t =     0.00s Start Test\n"


def ended(test: str, result: str) -> str:
    return f"Test Case '-[{CLASS} {test}]' {result} (9.567 seconds).\n"


def run(log: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(SCRIPT), str(log)], capture_output=True, text=True, check=False)


def summary(tmp_path: Path, text: str) -> list[str]:
    log = tmp_path / "gherkin-gui.log"
    log.write_text(text)
    done = run(log)
    assert done.returncode == 0, done.stderr
    assert done.stderr == ""
    return done.stdout.splitlines()


def test_names_the_failures_last_with_their_evidence(tmp_path: Path) -> None:
    probe = "last click: outlier.first, frame (1.0, 2.0, 3.0, 4.0), hittable true, window none, status " + "x" * 500
    cell = 'grid.cell.1: exists true, hittable false, frame (0.0, 0.0, 1.0, 1.0), path a/b'
    tree = "Attributes: Application, pid: 1\n  Button, identifier: 'tree-only', label: 'a/b'\n" + "  y" * 400 + "\n"
    text = (
        started("testUiPasses")
        + ended("testUiPasses", "passed")
        + started("testUiOne")
        + 'STEP FAILED: status.keep says "1 will keep": timed out\n'
        + f'{RUNNER}:198: error: -[{CLASS} testUiOne] : failed: caught error: "step "keep" failed: status/keep timed out\n'
        + probe + "\n" + probe + "\n" + tree + '"\n'
        + ended("testUiOne", "failed")
        + started("testUiTwo")
        + "STEP FAILED: the window is open: the cell never came\n"
        + cell + "\n" + tree
        + ended("testUiTwo", "failed")
        + started("testUiAlsoPasses")
        + ended("testUiAlsoPasses", "passed")
        + "Executed 4 tests, with 2 failures (2 unexpected) in 1.0 (1.0) seconds\n** TEST FAILED **\n"
    )
    lines = summary(tmp_path, text)
    out = "\n".join(lines)
    assert lines[-1] == "FAILED UI TESTS (2): testUiOne, testUiTwo"
    assert lines[-3].startswith('testUiOne: GuiFeatureRunner.swift:198: "step "keep" failed: status/keep timed out')
    assert lines[-2] == "testUiTwo: STEP FAILED: the window is open: the cell never came"
    assert "/Users/runner" not in out
    assert out.count("last click: outlier.first") == 1
    assert cell in lines
    assert "tree-only" not in out and "Attributes:" not in out
    assert "Passes" not in out
    assert max(len(line) for line in lines) <= 300


def test_a_log_without_a_failed_test_case_says_so(tmp_path: Path) -> None:
    lines = summary(tmp_path, "Compiling\n/a/b.swift:1:2: error: cannot find 'x' in scope\n** BUILD FAILED **\n")
    assert lines[0].startswith("NO FAILED TEST CASE in ")
    assert "/a/b.swift:1:2: error: cannot find 'x' in scope" in lines
    assert "FAILED UI TESTS" not in "\n".join(lines)


def test_an_unfinished_test_is_named(tmp_path: Path) -> None:
    lines = summary(tmp_path, started("testUiCrashes") + "Restarting after unexpected exit, crashed\n")
    assert lines[0].startswith("NO FAILED TEST CASE in ")
    assert lines[-1] == "did not finish: testUiCrashes"


def test_an_unfinished_test_before_a_failed_one(tmp_path: Path) -> None:
    lines = summary(tmp_path, started("testUiCrashes") + started("testUiFails") + ended("testUiFails", "failed"))
    assert "did not finish: testUiCrashes" in lines
    assert lines[-1] == "FAILED UI TESTS (1): testUiFails"


def test_a_missing_log_says_so(tmp_path: Path) -> None:
    done = run(tmp_path / "nope.log")
    assert done.returncode == 0
    assert done.stdout.startswith("NO LOG: ")


def test_a_missing_argument_is_an_error() -> None:
    assert subprocess.run([str(SCRIPT)], capture_output=True, check=False).returncode == 2
