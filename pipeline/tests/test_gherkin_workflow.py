"""Static checks on .github/workflows/gherkin.yml (read as text: the pipeline has no YAML dependency)."""

from __future__ import annotations

import re
from pathlib import Path

import pytest

WORKFLOW = Path(__file__).resolve().parents[2] / ".github" / "workflows" / "gherkin.yml"


def job_text(name: str) -> str:
    """The text of one top-level job, from `  <name>:` to the next job (or the end)."""
    text = WORKFLOW.read_text()
    m = re.search(rf"^  {re.escape(name)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", text, re.MULTILINE | re.DOTALL)
    assert m, f"job {name} not found in {WORKFLOW}"
    return m.group(1)


def job_if(name: str) -> str:
    """The job's `if:` expression, folded onto one line."""
    body = job_text(name)
    m = re.search(r"^    if:", body, re.MULTILINE)
    assert m, f"job {name} has no if:"
    lines = body[m.start() :].splitlines()
    first = lines[0].split("if:", 1)[1].strip()
    parts = [first] if first and first not in (">", ">-") else []
    for line in lines[1:]:
        if line.startswith("      "):
            parts.append(line.strip())
        else:
            break
    return " ".join(parts)


def job_needs(name: str) -> list[str]:
    m = re.search(r"^    needs:\s*\[(.*?)\]", job_text(name), re.MULTILINE)
    assert m, f"job {name} has no needs: [...]"
    return [n.strip() for n in m.group(1).split(",") if n.strip()]


@pytest.mark.parametrize("job", ["cli-macos", "mac-gui", "desktop-macos"])
def test_macos_legs_run_whatever_the_linux_legs_did(job: str) -> None:
    cond = job_if(job)
    # without a status function GitHub ANDs in success(), which a red Linux ancestor makes false
    assert cond.removeprefix("${{").lstrip().startswith("!cancelled()"), cond
    assert "needs.build-macos.result == 'success'" in cond
    for need in job_needs(job):
        assert f"needs.{need}.result == 'success'" in cond, f"{job}: if: does not check {need}"
    # the existing conditions stay
    assert "!inputs.smoke" in cond
    assert "inputs.macos != 'skip'" in cond


def test_smoke_macos_still_waits_for_the_linux_legs() -> None:
    assert "needs.desktop-linux.result" in job_if("smoke-macos")
