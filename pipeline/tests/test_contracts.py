from __future__ import annotations

from pathlib import Path

import pytest

from starpipe import worktrees
from starpipe.contracts import Contract
from starpipe.db import Database

from .fakes import GOOD_BODY, green_runner, make_repo, plan_args, sh


def contract(tmp: Path, title: str = "Tidy docs", body: str = GOOD_BODY) -> Contract:
    repo = make_repo(tmp)
    db = Database(tmp / "s.db")
    db.upsert_ticket(7, title, body, "brianm998", 2, [])
    wt, branch = worktrees.create(repo, 7, title, "origin/develop")
    db.set_fields(7, worktree=str(wt), branch=branch)
    t = db.ticket(7)
    assert t
    return Contract(t, wt, "origin/develop", db, check_runner=green_runner)


def test_plan_must_map_every_criterion_and_name_real_files(tmp_path: Path) -> None:
    c = contract(tmp_path)
    out = c.submit_plan(plan_args(acceptance=[{"id": "A2", "check": "x"}],
                                  findings=[{"file": "nope.md", "line": 1, "claim": "c"},
                                            {"file": "docs/a.md", "line": 99, "claim": "c"}]))
    assert "A1 is not mapped" in out and "A2 is not in the ticket" in out
    assert "nope.md does not exist" in out and "fewer than 99 lines" in out
    assert c.result is None
    assert "accepted" in c.submit_plan(plan_args(findings=[{"file": "docs/a.md", "line": 1, "claim": "c"}]))
    assert c.result and c.result[0] == "plan"


def test_a_bug_plan_needs_a_regression_test(tmp_path: Path) -> None:
    c = contract(tmp_path, title="Fix crash on open")
    assert "give new tests" in c.submit_plan(plan_args(tests={"none_reason": ""}))
    out = c.submit_plan(plan_args(tests={"new": [{"target": "T", "name": "n", "kind": "unit", "shows": "A1"}]}))
    assert "fails_before_fix" in out


def test_one_sided_parity_needs_a_reason(tmp_path: Path) -> None:
    c = contract(tmp_path)
    assert "parity_reason" in c.submit_plan(plan_args(parity="gui-only"))


def test_submit_change_needs_commits_clean_tree_and_green_checks(tmp_path: Path) -> None:
    c = contract(tmp_path)
    assert "no commits" in c.submit_change({"summary": "x"})
    commit_change_for(c)
    assert "no green result" in c.submit_change({"summary": "x"})
    (c.worktree / "stray.txt").write_text("x")
    assert "not clean" in c.submit_change({"summary": "x"})
    (c.worktree / "stray.txt").unlink()
    assert c.run_checks({})
    assert "accepted" in c.submit_change({"summary": "x"})


def commit_change_for(c: Contract) -> None:
    (c.worktree / "docs" / "a.md").write_text("changed\n")
    sh(c.worktree, "git", "add", "-A")
    sh(c.worktree, "git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "c")


def test_a_planned_test_must_appear_in_the_diff(tmp_path: Path) -> None:
    c = contract(tmp_path)
    c.ticket.plan_json = '{"tests": {"new": [{"name": "testTheThing"}]}}'
    commit_change_for(c)
    c.run_checks({})
    assert "testTheThing" in c.submit_change({"summary": "x"})


def test_review_verdict_rules(tmp_path: Path) -> None:
    c = contract(tmp_path)
    assert "at least one finding" in c.submit_review({"verdict": "changes"})
    blocker = {"file": "a", "line": 1, "severity": "blocker", "issue": "bad"}
    assert "blocker" in c.submit_review({"verdict": "approve", "findings": [blocker]})
    assert "accepted" in c.submit_review({"verdict": "approve", "findings": [{**blocker, "severity": "minor"}]})


def test_close_needs_verifiable_evidence(tmp_path: Path) -> None:
    c = contract(tmp_path)
    assert "reason must be" in c.close_ticket({"reason": "because", "evidence": ["docs/a.md:1"]})
    assert "evidence is required" in c.close_ticket({"reason": "no-defect", "evidence": []})
    assert "not verifiable" in c.close_ticket({"reason": "no-defect", "evidence": ["deadbeef", "docs/a.md:50"]})
    assert "accepted" in c.close_ticket({"reason": "no-defect", "evidence": ["docs/a.md:1"]})


def test_resolution_answer_must_cite(tmp_path: Path) -> None:
    c = contract(tmp_path)
    assert "cite" in c.submit_resolution({"kind": "answer", "text": "yes"})
    assert "accepted" in c.submit_resolution({"kind": "escalate", "text": "owner's call"})


def test_followups_are_deduplicated_against_open_issues(tmp_path: Path) -> None:
    from .fakes import FakeGitHub

    c = contract(tmp_path)
    gh = FakeGitHub()
    gh.add_issue(3, "Speed up the merge step")
    c.gh = gh
    assert "duplicate of open issue #3" in c.file_followup({"title": "Speed up the merge step.", "body": "b"})
    assert "recorded" in c.file_followup({"title": "Rename the config key", "body": "b"})
    assert len(c.followups) == 1


def test_the_database_migrates_once_and_survives_reopening(tmp_path: Path) -> None:
    Database(tmp_path / "m.db").close()
    db = Database(tmp_path / "m.db")
    assert db.upsert_ticket(1, "a", "b", "x", 2, []) is True
    assert db.upsert_ticket(1, "a2", "b", "x", 1, [5]) is False
    t = db.ticket(1)
    assert t and t.title == "a2" and t.priority == 1 and t.blocked_by == [5]
    assert db.open_blockers(1) == [5]


def test_planned_test_names_must_be_identifiers_not_prose(tmp_path: Path) -> None:
    c = contract(tmp_path)
    prose = {"target": "T", "name": "theThing (flipped from before, assertFalse)", "kind": "unit", "shows": "A1"}
    out = c.submit_plan(plan_args(tests={"new": [prose]}))
    assert "identifier" in out and c.result is None
    ok = {"target": "T", "name": "ProcessingTests.theThing", "kind": "unit", "shows": "A1"}
    assert "accepted" in c.submit_plan(plan_args(tests={"new": [ok]}))


def test_the_diff_gate_matches_the_method_not_the_qualified_name(tmp_path: Path) -> None:
    from starpipe import plan as planmod

    assert planmod.method_of("Class.testFoo") == "testFoo" and planmod.method_of("Suite/testBar") == "testBar"
    c = contract(tmp_path)
    c.ticket.plan_json = '{"tests": {"new": [{"name": "SomeTests.testTheThing"}]}}'
    (c.worktree / "docs" / "t.md").write_text("func testTheThing() {}\n")
    sh(c.worktree, "git", "add", "-A")
    sh(c.worktree, "git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "c")
    c.run_checks({})
    assert "accepted" in c.submit_change({"summary": "x"})


def test_java_home_is_resolved_from_config_then_environment(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from starpipe.config import Config
    from starpipe.daemon import resolve_java_home

    jdk = tmp_path / "jdk"
    (jdk / "bin").mkdir(parents=True)
    (jdk / "bin" / "java").write_text("")
    monkeypatch.delenv("JAVA_HOME", raising=False)
    assert resolve_java_home(Config(java_home=str(jdk))) == str(jdk)
    monkeypatch.setenv("JAVA_HOME", str(jdk))
    assert resolve_java_home(Config()) == str(jdk)
    monkeypatch.setenv("JAVA_HOME", "/nonexistent")
    assert resolve_java_home(Config()) != "/nonexistent"
