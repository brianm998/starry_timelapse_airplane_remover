"""The plan an EXPLORE session submits (plan §7.3), validated against the worktree."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


class Finding(BaseModel):
    file: str
    line: int = Field(ge=1)
    claim: str


IDENTIFIER = re.compile(r"[A-Za-z_]\w*(?:[./#][A-Za-z_]\w*)*")


def method_of(name: str) -> str:
    """The test method a planned name stands for: the last segment of `Class.method` / `Class/method`."""
    return re.split(r"[./#]", name.strip())[-1]


class NewTest(BaseModel):
    target: str
    name: str  # the test method as written in the source (`Class.method` allowed); no prose, no spaces
    kind: Literal["unit", "daemon", "cli-gherkin", "ui"]
    shows: str = Field(pattern=r"^A\d+$")
    fails_before_fix: bool = False

    @field_validator("name")
    @classmethod
    def _identifier(cls, value: str) -> str:
        if not IDENTIFIER.fullmatch(value.strip()):
            raise ValueError("name must be the test method's identifier as it appears in the source (optionally "
                             "`Class.method`), with no spaces or explanation; put explanations in the plan's summary")
        return value.strip()


class Tests(BaseModel):
    new: list[NewTest] = []
    existing_to_extend: list[str] = []
    none_reason: str = ""


class AcceptanceMap(BaseModel):
    id: str = Field(pattern=r"^A\d+$")
    check: str


class Plan(BaseModel):
    model_config = ConfigDict(extra="forbid")

    summary: str = Field(min_length=10)
    findings: list[Finding] = []
    approach: list[str] = Field(min_length=1)
    tests: Tests
    gherkin_features_to_run: list[str] = []
    acceptance: list[AcceptanceMap] = Field(min_length=1)
    parity: Literal["both", "gui-only", "desktop-only", "neither"] = "neither"
    parity_reason: str = ""
    touches_localization: bool = False
    risks: list[str] = []


def ticket_criteria(body: str) -> list[str]:
    return re.findall(r"^\s*[-*]\s*(A\d+):", body, re.MULTILINE)


def validate(plan: Plan, worktree: Path, body: str, is_bug: bool) -> list[str]:
    """Everything wrong with `plan`, empty when it is acceptable."""
    errors: list[str] = []
    for f in plan.findings:
        path = worktree / f.file
        if not path.is_file():
            errors.append(f"finding: {f.file} does not exist")
        elif f.line > len(path.read_text(errors="replace").splitlines()):
            errors.append(f"finding: {f.file} has fewer than {f.line} lines")
    for feature in plan.gherkin_features_to_run:
        if not (worktree / "gherkin" / "features" / f"{feature}.feature").is_file():
            errors.append(f"gherkin feature '{feature}' not found under gherkin/features/")
    wanted = set(ticket_criteria(body))
    mapped = {a.id for a in plan.acceptance}
    for missing in sorted(wanted - mapped):
        errors.append(f"acceptance criterion {missing} is not mapped to a test or check")
    for extra in sorted(mapped - wanted):
        errors.append(f"acceptance {extra} is not in the ticket")
    if not plan.tests.new and not plan.tests.none_reason:
        errors.append("tests: give new tests, or none_reason")
    if is_bug and not plan.tests.new and not plan.tests.none_reason.strip():
        errors.append("a bug needs a regression test that fails before the fix")
    if is_bug and any(not t.fails_before_fix for t in plan.tests.new) and plan.tests.new:
        errors.append("a bug's new tests must have fails_before_fix=true")
    if plan.parity in ("gui-only", "desktop-only") and not plan.parity_reason.strip():
        errors.append("a one-sided parity needs parity_reason")
    return errors
