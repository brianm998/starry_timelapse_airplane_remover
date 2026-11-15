"""Unit tests of the nightly decision: one per rule. Run: python3 -m pytest .github/scripts"""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))
from gherkin_nightly_decide import decide, path_matches, relevant_globs  # noqa: E402

TIP = "t" * 40
OLD = "o" * 40
GLOBS = ["cli/**", "gherkin/**", ".github/workflows/gherkin.yml"]


def run(i, sha=OLD, status="completed", conclusion="success", title="Gherkin: full", event="workflow_dispatch"):
    return {"id": i, "head_sha": sha, "status": status, "conclusion": conclusion, "display_title": title, "event": event}


def test_already_running_skips():
    action, reason = decide([run(2, status="in_progress", conclusion=None), run(1)], TIP, GLOBS, lambda s: ["cli/a.swift"])
    assert action == "skip" and "in flight" in reason


def test_queued_skips_even_when_forced():
    assert decide([run(2, status="queued", conclusion=None)], TIP, GLOBS, lambda s: [], force=True)[0] == "skip"


def test_same_tip_skips():
    action, reason = decide([run(1, sha=TIP, conclusion="failure")], TIP, GLOBS, lambda s: ["cli/a"])
    assert action == "skip" and "already tested" in reason


def test_cancelled_run_at_tip_does_not_count():
    assert decide([run(2, sha=TIP, conclusion="cancelled"), run(1)], TIP, GLOBS, lambda s: ["cli/a"])[0] == "dispatch"


def test_never_green_dispatches():
    action, reason = decide([run(1, conclusion="failure")], TIP, GLOBS, lambda s: [])
    assert action == "dispatch" and "no green" in reason


def test_subset_run_is_not_a_green_full_run():
    assert decide([run(1, title="Gherkin: a,b")], TIP, GLOBS, lambda s: [])[0] == "dispatch"


def test_push_run_counts_as_full():
    assert decide([run(1, title="msg", event="push")], TIP, GLOBS, lambda s: ["README.md"])[0] == "skip"


def test_relevant_change_dispatches():
    action, reason = decide([run(1)], TIP, GLOBS, lambda s: ["docs/x.md", "cli/Sources/a.swift"])
    assert action == "dispatch" and "cli/Sources/a.swift" in reason


def test_irrelevant_change_skips():
    action, _ = decide([run(1)], TIP, GLOBS, lambda s: ["docs/x.md", "pipeline/a.py"])
    assert action == "skip"


def test_unreachable_sha_dispatches():
    action, reason = decide([run(1)], TIP, GLOBS, lambda s: None)
    assert action == "dispatch" and "not in the repo" in reason


def test_force_dispatches_with_nothing_changed():
    assert decide([run(1)], TIP, GLOBS, lambda s: [], force=True) == ("dispatch", "forced")


def test_globs_parse_and_match():
    yml = "on:\n  push:\n    paths:\n      - 'x/**'\n  pull_request:\n    paths:\n      - 'cli/**'\n      - 'a/*.md'  # c\n  workflow_dispatch:\n"
    globs = relevant_globs(yml)
    assert globs == ["cli/**", "a/*.md"]
    assert path_matches("cli/a/b.swift", globs) and path_matches("a/b.md", globs)
    assert not path_matches("a/b/c.md", globs) and not path_matches("x/y", globs)


def test_missing_globs_raise():
    with pytest.raises(ValueError):
        relevant_globs("on:\n  push:\n")
