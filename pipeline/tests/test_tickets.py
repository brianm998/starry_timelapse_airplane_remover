from __future__ import annotations

import json
from collections.abc import Sequence
from pathlib import Path

import pytest
from click.testing import CliRunner

from starpipe import cli, tickets
from starpipe.config import Config
from starpipe.github import GitHub, GitHubError

GOOD = """## Goal
Make the thing work.

## Context
See StarCore/Foo.swift.

## Acceptance criteria
- A1: it works — check: FooTests/testWorks
- A2: docs updated — check: review: README

## Tests
- FooTests.testWorks: fails without the fix

## Out of scope
Anything else.

## Pipeline
model_develop: opus · effort_develop: high
"""


def test_good_body_lints_clean() -> None:
    result = tickets.lint(GOOD)
    assert result.ok and not result.warnings


def test_missing_section_and_check_are_errors() -> None:
    body = GOOD.replace("## Out of scope\nAnything else.\n\n", "").replace(" — check: review: README", "")
    errors = tickets.lint(body).errors
    assert any("Out of scope" in e for e in errors)
    assert any("A2 has no 'check:'" in e for e in errors)


def test_unknown_pipeline_key_and_too_many_criteria() -> None:
    body = GOOD.replace("model_develop: opus", "bogus: 1")
    assert any("bogus" in e for e in tickets.lint(body).errors)
    many = GOOD.replace("- A2:", "\n".join(f"- A{i}: x — check: y" for i in range(3, 9)) + "\n- A2:")
    assert any("acceptance criteria" in w for w in tickets.lint(many).warnings)


def test_bug_ticket_needs_a_real_none_reason() -> None:
    body = GOOD.replace("- FooTests.testWorks: fails without the fix", "none: visual")
    assert not tickets.lint(body, title="Fix crash on open").ok
    assert tickets.lint(body, title="Add a button").ok
    reasoned = GOOD.replace("- FooTests.testWorks: fails without the fix", "none: pure doc change")
    assert tickets.lint(reasoned, title="Fix typo").ok


def test_headers_inside_code_fences_are_not_sections() -> None:
    body = GOOD.replace("See StarCore/Foo.swift.", "```\n## Tests\nnone: x\n```")
    assert tickets.lint(body).ok


class Fake:
    """Records gh calls and answers them like the API would."""

    def __init__(self, fail_on: str | None = None) -> None:
        self.calls: list[tuple[str, str, dict[str, object]]] = []
        self.fail_on = fail_on

    def __call__(self, args: Sequence[str], stdin: str | None) -> str:
        if "--paginate" in args:  # the duplicate and cap checks list open issues: there are none
            return "[[]]"
        method, path = args[args.index("-X") + 1], args[-3] if "--input" in args else args[-1]
        body: dict[str, object] = json.loads(stdin) if stdin else {}
        if self.fail_on and self.fail_on in path:
            raise GitHubError("boom")
        self.calls.append((method, path.split("/", 3)[3], body))
        if path.endswith("/issues") and method == "POST":
            return json.dumps({"number": 50 + sum(1 for c in self.calls if c[1] == "issues")})
        if method == "GET":
            return json.dumps({"id": 9000 + int(path.rsplit("/", 1)[1])})
        return "{}"


def test_file_ticket_creates_labels_and_links() -> None:
    fake = Fake()
    number = tickets.file_ticket(GitHub(Config(), fake), "T", GOOD, blocked_by=[41, 42], priority="p1")
    assert number == 51
    kinds = [(m, p) for m, p, _ in fake.calls]
    assert ("POST", "issues/51/labels") in kinds
    labels = next(b for _, p, b in fake.calls if p == "issues/51/labels")
    assert labels == {"labels": ["pipeline", "p1"]}
    links = [b for _, p, b in fake.calls if p.endswith("dependencies/blocked_by")]
    assert links == [{"issue_id": 9041}, {"issue_id": 9042}]


def test_failure_after_create_closes_the_issue() -> None:
    fake = Fake(fail_on="dependencies")
    with pytest.raises(tickets.FilingError, match="closed #51"):
        tickets.file_ticket(GitHub(Config(), fake), "T", GOOD, blocked_by=[41])
    assert fake.calls[-1] == ("PATCH", "issues/51", {"state": "closed", "state_reason": "not_planned"})


def test_lint_failure_creates_nothing() -> None:
    fake = Fake()
    with pytest.raises(tickets.FilingError, match="lint failed"):
        tickets.file_ticket(GitHub(Config(), fake), "T", "## Goal\nx\n")
    assert fake.calls == []


def test_ticket_lint_cli(tmp_path: Path) -> None:
    good = tmp_path / "good.md"
    good.write_text(GOOD)
    bad = tmp_path / "bad.md"
    bad.write_text("## Goal\nx\n")
    runner = CliRunner()
    assert runner.invoke(cli.main, ["ticket", "lint", str(good)]).exit_code == 0
    out = runner.invoke(cli.main, ["ticket", "lint", str(bad)])
    assert out.exit_code == 1 and "missing section" in out.output


def test_ensure_labels_is_idempotent() -> None:
    created_names: list[str] = []

    def runner(args: Sequence[str], stdin: str | None) -> str:
        if "--paginate" in args:
            return json.dumps([[{"name": "pipeline"}, {"name": "p2"}]])
        created_names.append(json.loads(stdin or "{}")["name"])
        return "{}"

    created, present = GitHub(Config(), runner).ensure_labels()
    assert "pipeline" not in created and "pipe:queued" in created and present == ["p2", "pipeline"]
    assert created == created_names
