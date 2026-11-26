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


def test_mac_gui_failure_evidence_step_is_last() -> None:
    body = job_text("mac-gui")
    names = list(re.finditer(r"^      - name: (.*)$", body, re.MULTILINE))
    last = names[-1]
    assert last.group(1).startswith("Failure evidence")
    step = body[last.start() :]
    assert re.search(r"^        if: failure\(\)", step, re.MULTILINE)
    assert "gui-prove.txt" in body and "gui-xcresult-summary.txt" in body


def test_mac_gui_xcodebuild_step_ends_with_the_failed_tests() -> None:
    body = job_text("mac-gui")
    start = body.index("      - name: Run the Gherkin features in Star.app (XCUITest)")
    step = body[start : body.index("      - name: ", start + 1)]
    trap = (
        """trap 'rc=$?; if [ "$rc" != 0 ]; then gherkin/summarize-xctest-failures.sh gherkin-gui.log || true; fi; """
        """exit "$rc"' EXIT"""
    )
    assert trap in step
    assert step.index(trap) < step.index("run_xcodebuild gherkin-gui.log")


def test_desktop_linux_failure_evidence_step_is_last():
    body = job_text("desktop-linux")
    names = re.findall(r"^      - name: (.+)$", body, re.MULTILINE)
    assert names[-1].startswith("Failure evidence")
    step = body[body.index("      - name: Failure evidence") :]
    assert "if: failure() || cancelled()" in step
    assert "continue-on-error: true" in step
    assert "actions: read" in body
    smoke = (WORKFLOW.parent / "gherkin-smoke.yml").read_text()
    callers = re.findall(r"^    permissions:\n((?:      .+\n)+)    uses: \./\.github/workflows/gherkin\.yml", smoke, re.MULTILINE)
    assert len(callers) == 2
    for perms in callers:
        assert "actions: read" in perms
