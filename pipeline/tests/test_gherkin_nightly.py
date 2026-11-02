from __future__ import annotations

import asyncio
import json
from datetime import datetime
from pathlib import Path
from typing import Any

import pytest

from starpipe import gherkin_nightly as gn
from starpipe import nightly
from starpipe.config import Config
from starpipe.daemon import Daemon
from starpipe.github import GitHubError

from .fakes import FakeGitHub, sh
from .test_engine import Rig

REPO_ROOT = Path(__file__).resolve().parents[2]
TIP = "t" * 40
GREEN = "g" * 40

WORKFLOW = """name: Gherkin
on:
  push:
    branches: [main]
    paths:
      - 'only-for-push/**'
  pull_request:
    branches: [main, develop]
    paths:
      - 'cli/**'
      - 'StarCore/**'   # a comment
      - '.github/workflows/gherkin.yml'
  workflow_dispatch:
    inputs:
      features:
        default: ''
jobs:
  x:
    steps:
      - run: echo hi
"""


def run(rid: int, sha: str, status: str = "completed", conclusion: str | None = "success", title: str = gn.FULL_TITLE,
        event: str = "workflow_dispatch") -> dict[str, Any]:
    return {"id": rid, "head_sha": sha, "status": status, "conclusion": conclusion, "display_title": title, "event": event,
            "created_at": "2026-10-30T23:00:10Z"}


class GH(FakeGitHub):
    """Runs of the Gherkin workflow on develop, and the dispatches asked for."""

    def __init__(self) -> None:
        super().__init__()
        self.runs: list[dict[str, Any]] = []
        self.dispatched: list[tuple[str, str, dict[str, str]]] = []
        self.fail_dispatch = False

    def workflow_file_runs(self, file: str, branch: str, per_page: int = 50) -> list[dict[str, Any]]:
        return list(reversed(self.runs))

    def dispatch_workflow(self, file: str, ref: str, inputs: dict[str, str]) -> None:
        if self.fail_dispatch:
            raise GitHubError("HTTP 422")
        self.dispatched.append((file, ref, inputs))
        self.runs.append(run(max(r["id"] for r in self.runs) + 1 if self.runs else 1, TIP, "queued", None))


class Setup:
    def __init__(self, rig: Rig, changed: dict[str, list[str]] | None = None, text: str = WORKFLOW) -> None:
        self.rig = rig
        self.gh = GH()
        self.changed = changed if changed is not None else {GREEN: ["cli/Sources/main.swift"]}
        self.text = text
        self.source = gn.Source(lambda: None, lambda: TIP, lambda: self.text, lambda sha: self.changed.get(sha))

    def go(self, force: bool = False) -> gn.Decision:
        return gn.run_once(self.rig.db, self.gh, Config(), self.source, force, sleep=lambda _s: None)

    def events(self) -> list[dict[str, Any]]:
        return [e["data"] for e in self.rig.db.events_since(0) if e["kind"] == "gherkin-nightly"]


@pytest.fixture
def rig(tmp_path: Path) -> Rig:
    return Rig(tmp_path)


def test_testDueAroundTwentyThreeHundredAtMostOncePerDay(rig: Rig, monkeypatch: pytest.MonkeyPatch) -> None:
    assert not nightly.due(datetime(2026, 11, 1, 22, 59), None, "23:00")
    assert nightly.due(datetime(2026, 11, 1, 23, 0), None, "23:00")
    assert nightly.due(datetime(2026, 11, 1, 23, 40), "2026-10-31", "23:00")
    assert not nightly.due(datetime(2026, 11, 1, 23, 40), "2026-11-01", "23:00")
    assert Config().gherkin_nightly_start == "23:00" and Config().gherkin_nightly_enabled

    # the daemon's loop: always due (start 00:00), three ticks, one decision; an error does not finish the day and is not retried
    # on the very next tick either
    class Stop(Exception):
        pass

    for action, days in (("skip", "set"), ("error", None)):
        rig.db.put("gherkin_nightly_last_day", None)
        d = Daemon(rig.engine, Config(gherkin_nightly_start="00:00"), token="tok")
        calls: list[bool] = []
        ticks = 0

        def decision(force: bool = False, action: str = action, calls: list[bool] = calls) -> gn.Decision:
            calls.append(force)
            return gn.Decision(action, "x")

        async def tick(_s: float) -> None:
            nonlocal ticks
            ticks += 1
            if ticks == 3:
                raise Stop

        monkeypatch.setattr(d, "gherkin_run", decision)
        monkeypatch.setattr("starpipe.daemon.asyncio.sleep", tick)
        with pytest.raises(Stop):
            asyncio.run(d.gherkin_nightly_loop())
        assert calls == [False], action
        assert (rig.db.get("gherkin_nightly_last_day") is not None) == (days == "set")


def test_testRelevantChangeSinceLastGreenFullRunDispatchesExactlyOne(rig: Rig) -> None:
    s = Setup(rig)
    s.gh.runs = [run(1, GREEN)]
    d = s.go()
    assert d.action == "dispatch" and d.base_sha == GREEN
    assert s.gh.dispatched == [("gherkin.yml", "develop", {"features": ""})]
    assert d.run_id == 2  # the run the dispatch created
    [ev] = s.events()
    assert ev["action"] == "dispatch" and ev["base_sha"] == GREEN and ev["run_id"] == 2 and "cli/Sources/main.swift" in ev["reason"]
    # the status line the daemon shows is built from the same record
    last = json.loads(rig.db.get("gherkin_nightly_last") or "{}")
    assert "last green full" in gn.summary_line(last) and "run 2" in gn.summary_line(last)
    # a second decision right after sees the run it started in flight
    assert s.go().action == "skip" and len(s.gh.dispatched) == 1


@pytest.mark.parametrize("files", [["docs/a.md", "pipeline/src/x.py", "plans/PLAN.md"], []])
def test_testIrrelevantOnlyChangesDoNotDispatchAndRecordWhy(rig: Rig, files: list[str]) -> None:
    s = Setup(rig, {GREEN: files})
    s.gh.runs = [run(1, GREEN)]
    d = s.go()
    assert d.action == "skip" and not s.gh.dispatched
    [ev] = s.events()
    assert ev["action"] == "skip" and "nothing relevant changed" in ev["reason"] and ev["base_sha"] == GREEN


def test_testFullRunInFlightSkips(rig: Rig) -> None:
    for status in ("queued", "in_progress"):
        s = Setup(rig)
        s.gh.runs = [run(1, GREEN), run(2, TIP, status, None)]
        d = s.go()
        assert d.action == "skip" and d.run_id == 2 and not s.gh.dispatched
        assert "in flight" in s.events()[-1]["reason"]
    # a subset run in flight is not a full run in flight
    s = Setup(rig)
    s.gh.runs = [run(1, GREEN), run(2, TIP, "in_progress", None, title="Gherkin: autoHorizonJpeg")]
    assert s.go().action == "dispatch"


def test_testTipAlreadyTestedSkipsEvenWhenThatRunFailed(rig: Rig) -> None:
    s = Setup(rig)
    s.gh.runs = [run(1, GREEN), run(2, TIP, conclusion="failure")]
    d = s.go()
    assert d.action == "skip" and not s.gh.dispatched
    assert "already tested" in s.events()[-1]["reason"]
    # a cancelled run tested nothing
    s = Setup(rig)
    s.gh.runs = [run(1, GREEN), run(2, TIP, conclusion="cancelled")]
    assert s.go().action == "dispatch"


def test_testNoGreenFullRunEverDispatches(rig: Rig) -> None:
    s = Setup(rig, {})
    s.gh.runs = []
    d = s.go()
    assert d.action == "dispatch" and d.base_sha is None and len(s.gh.dispatched) == 1
    assert "no green full run" in s.events()[-1]["reason"]
    # a base sha missing from the local repo cannot be diffed: dispatch rather than guess
    s = Setup(rig, {})
    s.gh.runs = [run(1, GREEN)]
    d = s.go()
    assert d.action == "dispatch" and "not in the repo" in d.reason


def test_testGreenSubsetRunIsNotTheLastGreenFullRun() -> None:
    runs = [run(1, "old" * 13, event="push", title="Fix the thing"), run(2, GREEN), run(3, TIP, title="Gherkin: autoHorizonJpeg,x"),
            run(4, TIP, conclusion="failure"), run(5, TIP, status="in_progress", conclusion=None)]
    assert gn.last_green_full(runs)["id"] == 2  # type: ignore[index]
    assert gn.last_green_full([r for r in runs if r["id"] != 2])["id"] == 1  # type: ignore[index]  # an old develop push run was full
    assert gn.last_green_full([run(3, TIP, title="Gherkin: a")]) is None


def test_testSubsetGreenDoesNotHideARelevantChange(rig: Rig) -> None:
    s = Setup(rig, {GREEN: ["StarCore/x.swift"]})
    s.gh.runs = [run(1, GREEN), run(2, TIP, title="Gherkin: a")]  # the subset ran at the tip and passed
    d = s.go()
    assert d.action == "dispatch" and d.base_sha == GREEN


def test_testPathListComesFromTheWorkflowFile(rig: Rig) -> None:
    changed = {GREEN: ["docs/guide.md"]}
    narrow = Setup(rig, changed)
    narrow.gh.runs = [run(1, GREEN)]
    assert narrow.go().action == "skip"
    wide = Setup(rig, changed, WORKFLOW.replace("'cli/**'", "'docs/**'"))
    wide.gh.runs = [run(1, GREEN)]
    assert wide.go().action == "dispatch"
    assert gn.relevant_globs(WORKFLOW) == ["cli/**", "StarCore/**", ".github/workflows/gherkin.yml"]  # not the push list
    # the real workflow parses, covers what the ticket says, and no longer starts on a develop push
    real = (REPO_ROOT / ".github" / "workflows" / "gherkin.yml").read_text()
    globs = gn.relevant_globs(real)
    assert {"cli/**", "StarCore/**", "gherkin/**"} <= set(globs)
    assert gn.path_matches("cli/Sources/star/main.swift", globs) and not gn.path_matches("docs/a.md", globs)
    assert "branches: [main]\n" in real.split("pull_request:")[0] and "run-name:" in real and "workflow_dispatch:" in real
    # a workflow with no list must fail loudly, not mean "everything"
    broken = Setup(rig, changed, "on:\n  push:\n    branches: [main]\n")
    broken.gh.runs = [run(1, GREEN)]
    assert broken.go().action == "error" and not broken.gh.dispatched


def test_path_globs_follow_github_semantics() -> None:
    assert gn.path_matches("cli/a/b.swift", ["cli/**"]) and not gn.path_matches("cli", ["cli/**"])
    assert gn.path_matches("a.json", ["*.json"]) and not gn.path_matches("d/a.json", ["*.json"])
    assert gn.path_matches("a/b", ["a/**/b"]) and gn.path_matches("a/x/y/b", ["a/**/b"])
    assert not gn.path_matches("clix/a", ["cli/**"])


def test_testForceSkipsTheChangeGateButNotInFlight(rig: Rig) -> None:
    s = Setup(rig, {GREEN: ["docs/a.md"]})
    s.gh.runs = [run(1, GREEN), run(2, TIP, conclusion="failure")]  # nothing relevant AND the tip was tested
    assert s.go().action == "skip"
    d = s.go(force=True)
    assert d.action == "dispatch" and len(s.gh.dispatched) == 1
    assert s.events()[-1]["forced"] is True
    assert s.go(force=True).action == "skip" and len(s.gh.dispatched) == 1  # the run just started is in flight


def test_a_github_error_is_recorded_and_dispatches_nothing(rig: Rig) -> None:
    s = Setup(rig)
    s.gh.runs = [run(1, GREEN)]
    s.gh.fail_dispatch = True
    d = s.go()
    assert d.action == "error" and "422" in d.reason
    assert s.events()[-1]["action"] == "error"


def test_the_status_carries_the_line_and_the_snapshot_does_not(rig: Rig) -> None:
    d = Daemon(rig.engine, Config(), token="tok")
    assert d.status()["gherkin_nightly"] is None
    s = Setup(rig)
    s.gh.runs = [run(1, GREEN)]
    s.go()
    info: Any = d.status()["gherkin_nightly"]
    assert info["line"].startswith("gherkin nightly: dispatch") and info["base_sha"] == GREEN
    assert "gherkin_nightly" not in d.snapshot()  # the monitor's contract fixture is pinned


def test_git_source_diffs_against_the_tip_and_notices_a_missing_sha(tmp_path: Path) -> None:
    origin, repo = tmp_path / "origin.git", tmp_path / "repo"
    sh(tmp_path, "git", "init", "-q", "--bare", "-b", "develop", str(origin))
    sh(tmp_path, "git", "clone", "-q", str(origin), str(repo))
    base = ""
    for name, text in (("docs/a.md", "1"), ("cli/b.swift", "1")):
        (repo / name).parent.mkdir(exist_ok=True)
        (repo / name).write_text(text)
        sh(repo, "git", "add", "-A")
        sh(repo, "git", "commit", "-q", "-m", name)
        sh(repo, "git", "push", "-q", "origin", "HEAD:develop")
        sh(repo, "git", "fetch", "-q")
        if name == "docs/a.md":
            base = sh(repo, "git", "rev-parse", "HEAD").strip()
    wf = repo / ".github" / "workflows"
    wf.mkdir(parents=True)
    (wf / "gherkin.yml").write_text(WORKFLOW)
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-q", "-m", "workflow")
    sh(repo, "git", "push", "-q", "origin", "HEAD:develop")
    def fetch(r: Path) -> None:
        sh(r, "git", "fetch", "-q")

    src = gn.git_source(repo, "develop", fetch)
    src.fetch()
    assert src.tip() == sh(repo, "git", "rev-parse", "origin/develop").strip()
    assert gn.relevant_globs(src.workflow_text())[0] == "cli/**"
    assert src.changed(base) == [".github/workflows/gherkin.yml", "cli/b.swift"]
    assert src.changed("f" * 40) is None
