"""Turn a test run's own output into counts. Exit codes and banners can be vacuous (plan §8.4)."""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Counts:
    executed: int = 0
    failed: int = 0
    skipped: int = 0

    @property
    def vacuous(self) -> bool:
        return self.executed < 1


_XCTEST_TOTAL = re.compile(r"Executed (\d+) tests?, with (\d+) failures?(?: \((\d+) unexpected\))?")
_XCTEST_SKIPPED = re.compile(r"Test Case '.*' skipped \(")
# A test that skips itself because its data is not in the repo or it is an opt-in measurement skips on every machine and every
# develop run: that is not a test the change silently lost. Only these reasons are expected; any other skip is still red.
_XCTEST_EXPECTED_SKIP = re.compile(
    r"Test skipped - (?:opt-in|no horizon (?:reference fixtures|test sequence)|set STAR_\w+ to\b)")
# swift-testing: "✔ Test run with 12 tests in 3 suites passed after 0.1 seconds."
_SWIFT_TESTING = re.compile(r"Test run with (\d+) tests?.* (passed|failed)")


def _clean(text: str) -> str:
    return text.replace("\r", "")


def parse_xctest(text: str) -> Counts:
    """XCTest ('Executed N tests') and swift-testing ('Test run with N tests') in one log.

    xcodebuild and swift test print an "Executed" line per suite and bundle; the largest is the
    run's total, because the totals nest.
    """
    text = _clean(text)
    counts = Counts()
    for match in _XCTEST_TOTAL.finditer(text):
        n, failures = int(match.group(1)), int(match.group(2))
        if n >= counts.executed:
            counts.executed, counts.failed = n, failures
    for match in _SWIFT_TESTING.finditer(text):
        counts.executed += int(match.group(1))
        if match.group(2) == "failed":
            counts.failed += 1
    counts.skipped = max(0, len(_XCTEST_SKIPPED.findall(text)) - len(_XCTEST_EXPECTED_SKIP.findall(text)))
    return counts


def parse_gradle(results_dir: Path) -> Counts:
    """JUnit XML under build/test-results, which Gradle always writes."""
    counts = Counts()
    for xml in sorted(results_dir.glob("*.xml")):
        try:
            suite = ET.parse(xml).getroot()
        except ET.ParseError:
            counts.failed += 1
            continue
        counts.executed += int(suite.get("tests", 0))
        counts.failed += int(suite.get("failures", 0)) + int(suite.get("errors", 0))
        counts.skipped += int(suite.get("skipped", 0))
    return counts


def parse_pytest(text: str) -> Counts:
    counts = Counts()
    for line in _clean(text).splitlines():
        if " in " in line and ("passed" in line or "failed" in line or "skipped" in line):
            passed = re.search(r"(\d+) passed", line)
            failed = re.search(r"(\d+) failed", line)
            skipped = re.search(r"(\d+) skipped", line)
            p, f, s = (int(m.group(1)) if m else 0 for m in (passed, failed, skipped))
            counts = Counts(executed=p + f + s, failed=f, skipped=s)
    return counts
