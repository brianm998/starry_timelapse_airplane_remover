from __future__ import annotations

import asyncio
import json
from datetime import datetime
from pathlib import Path
from typing import Any

import pytest

from starpipe import gherkin_nightly as gn
from starpipe import nightly, tickets
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
        self.jobs: dict[int, list[dict[str, Any]]] = {}  # the latest attempt's jobs, by run id
        self.second: dict[str, str] = {}  # job name -> its conclusion on attempt 2 (default: failure again)
        self.rerun_started = False

    def workflow_file_runs(self, file: str, branch: str, per_page: int = 50) -> list[dict[str, Any]]:
        return list(reversed(self.runs))

    def dispatch_workflow(self, file: str, ref: str, inputs: dict[str, str]) -> None:
        if self.fail_dispatch:
            raise GitHubError("HTTP 422")
        self.dispatched.append((file, ref, inputs))
        self.runs.append(run(max(r["id"] for r in self.runs) + 1 if self.runs else 1, TIP, "queued", None))

    def run_jobs(self, run_id: int, version: str | None = None) -> list[dict[str, Any]]:
        return self.jobs.get(run_id, [])

    def rerun_failed(self, run_id: int) -> None:
        latest = next(r for r in self.runs if r["id"] == run_id)
        if latest["status"] != "completed" or latest.get("run_attempt", 1) > 1:
            raise GitHubError("HTTP 403: run cannot be rerun")
        self.reruns.append(run_id)
        self.rerun_started = True  # GitHub still says "completed, attempt 1" until the rerun is under way: see finish_rerun

    def finish_rerun(self, run_id: int) -> None:
        """The rerun has run: attempt 2, failed jobs have their second result, the others are untouched."""
        latest = next(r for r in self.runs if r["id"] == run_id)
        latest["run_attempt"] = 2
        for j in self.jobs[run_id]:
            if j["conclusion"] not in ("success", "skipped"):
                j["conclusion"] = self.second.get(j["name"], "failure")

    def failed_log(self, run_id: int, limit: int = 12000) -> str:
        attempt = next(r for r in self.runs if r["id"] == run_id).get("run_attempt", 1)
        return "\n".join(f"{j['name']}\tRun feature\tattempt {attempt}: {j['name']} broke" for j in self.jobs.get(run_id, [])
                         if j["conclusion"] not in ("success", "skipped"))


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
    # the real PR workflow (gherkin-smoke.yml) parses and covers what the ticket says; gherkin.yml no longer starts on a PR or a develop push
    real_full = (REPO_ROOT / ".github" / "workflows" / "gherkin.yml").read_text()
    real = (REPO_ROOT / ".github" / "workflows" / gn.PATHS_FILE).read_text()
    globs = gn.relevant_globs(real)
    assert {"cli/**", "StarCore/**", "gherkin/**"} <= set(globs)
    assert gn.path_matches("cli/Sources/star/main.swift", globs) and not gn.path_matches("docs/a.md", globs)
    assert "branches: [main]\n" in real_full.split("workflow_dispatch:")[0] and "pull_request:" not in real_full.split("workflow_dispatch:")[0]
    assert "run-name:" in real_full and "workflow_dispatch:" in real_full
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
    sh(repo, "git", "config", "user.email", "t@t")
    sh(repo, "git", "config", "user.name", "t")
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
    (wf / gn.PATHS_FILE).write_text(WORKFLOW)
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-q", "-m", "workflow")
    sh(repo, "git", "push", "-q", "origin", "HEAD:develop")
    def fetch(r: Path) -> None:
        sh(r, "git", "fetch", "-q")

    src = gn.git_source(repo, "develop", fetch)
    src.fetch()
    assert src.tip() == sh(repo, "git", "rev-parse", "origin/develop").strip()
    assert gn.relevant_globs(src.workflow_text())[0] == "cli/**"
    assert src.changed(base) == [gn.PATHS_PATH, "cli/b.swift"]
    assert src.changed("f" * 40) is None


# the results of a nightly run ---------------------------------------------------------------------------------------------
LINUX = "desktop (ubuntu-24.04)"
MAC = "desktop (macos-14)"
WIN = "cli (windows-2022)"


def finished_nightly(rig: Rig, first: dict[str, str], second: dict[str, str] | None = None) -> Setup:
    """A nightly dispatched by the daemon and completed with these job conclusions on attempt 1; `second` is what the rerun gives."""
    s = Setup(rig)
    s.gh.runs = [run(1, GREEN)]
    assert s.go().run_id == 2
    s.gh.runs[-1].update(status="completed", conclusion="failure" if set(first.values()) - {"success"} else "success")
    s.gh.jobs[2] = [{"name": n, "status": "completed", "conclusion": c, "completed_at": None} for n, c in first.items()]
    s.gh.second = second or {}
    return s


def follow(s: Setup, config: Config | None = None) -> str | None:
    return gn.follow_once(s.rig.db, s.gh, config or Config(), s.rig.engine.notifier, clock=lambda: 1_700_000_000.0)


def alerts(s: Setup) -> list[str]:
    return [e["data"]["text"] for e in s.rig.db.events_since(0) if e["kind"] == "alert" and e["data"]["key"].startswith("gherkin-nightly")]


def labels(s: Setup, number: int) -> set[str]:
    return {lab["name"] for lab in s.gh.issues[number]["labels"]}


def test_nightly_failed_jobs_are_rerun_once_and_cancelled_never_ticketed(rig: Rig) -> None:
    s = finished_nightly(rig, {f"{LINUX} · hangs": "timed_out", f"{MAC} · hangs": "success", f"{WIN} · runnerLost": "cancelled"})
    assert follow(s) == "rerun"
    assert s.gh.reruns == [2]  # the run, once (GitHub reruns only its failed jobs)
    assert follow(s) is None and follow(s) is None and s.gh.reruns == [2]  # attempt 1 is still what is reported: nothing is read as the rerun
    assert s.gh.issues == {}
    s.gh.finish_rerun(2)  # the cancelled job fails for real on the rerun: still the runner's job on attempt 1, never ticketed
    assert follow(s) == "done"
    assert [i["title"] for i in s.gh.issues.values()] == ["Gherkin nightly red: hangs"]  # timed_out is a failure
    assert s.gh.reruns == [2] and rig.db.get(gn.FOLLOW_KEY) is None
    assert "1 job(s) cancelled" in alerts(s)[0]
    assert follow(s) is None  # finished: nothing more to do

    # a refused rerun is retried next tick instead of being lost
    s = finished_nightly(rig, {f"{LINUX} · a": "failure"})
    s.gh.runs[-1]["run_attempt"] = 1
    original = s.gh.rerun_failed
    s.gh.rerun_failed = lambda _id: (_ for _ in ()).throw(GitHubError("HTTP 502"))  # type: ignore[method-assign]
    assert follow(s) is None and s.gh.reruns == []
    s.gh.rerun_failed = original  # type: ignore[method-assign]
    assert follow(s) == "rerun" and s.gh.reruns == [2]


def test_red_on_both_attempts_files_one_lint_clean_ticket_per_feature_across_legs(rig: Rig) -> None:
    s = finished_nightly(rig, {f"{LINUX} · removeAirplanes": "failure", f"{MAC} · removeAirplanes": "failure",
                               f"{WIN} · removeAirplanes": "failure", f"{LINUX} · shard 3: autoHorizon, autoMovingTiff16": "failure",
                               f"{LINUX} · ok": "success"})
    follow(s)
    s.gh.finish_rerun(2)
    assert follow(s) == "done"
    titles = {i["title"]: n for n, i in s.gh.issues.items()}
    assert set(titles) == {"Gherkin nightly red: removeAirplanes", "Gherkin nightly red: autoHorizon, autoMovingTiff16"}
    n = titles["Gherkin nightly red: removeAirplanes"]
    assert labels(s, n) == {"pipeline", "p1", "pipe:filed-by-pipeline"}
    body = s.gh.issues[n]["body"]
    assert tickets.lint(body, "Gherkin nightly red: removeAirplanes").ok, tickets.lint(body).errors
    assert tickets.parse_pipeline(body)["gherkin"] == "removeAirplanes"
    for leg in (LINUX, MAC, WIN):  # one ticket, every leg listed with its own log tail (of the rerun)
        assert f"### {leg}\n```\nattempt 2: {leg} · removeAirplanes broke" in body
    assert "A1: `removeAirplanes` passes on every listed leg" in body
    assert "filed-by:pipeline" in body
    assert "2 red (#" in alerts(s)[0]


def test_red_then_green_is_recorded_as_flaky_and_files_a_flaky_ticket(rig: Rig) -> None:
    rig.db.add_flake("autoMovingTiff16", MAC, 1, "2026-10-29")  # an earlier night
    s = finished_nightly(rig, {f"{LINUX} · autoMovingTiff16": "failure", f"{MAC} · autoMovingTiff16": "failure"},
                         {f"{LINUX} · autoMovingTiff16": "success", f"{MAC} · autoMovingTiff16": "success"})
    follow(s)
    s.gh.finish_rerun(2)
    assert follow(s) == "done"
    hist = rig.db.flake_history("autoMovingTiff16")
    assert [(h["leg"], h["run_id"], h["day"]) for h in hist][1:] == [(LINUX, "2", "2023-11-14"), (MAC, "2", "2023-11-14")]
    (n, issue), = s.gh.issues.items()
    assert issue["title"] == f"Gherkin flaky: autoMovingTiff16 ({LINUX}, {MAC})"
    assert labels(s, n) == {"pipeline", "p2", "pipe:filed-by-pipeline"}
    body = issue["body"]
    assert tickets.lint(body, issue["title"]).ok
    assert "fails intermittently" in body and "A retry or a longer timeout alone is not a fix" in body
    assert "attempt 1: " + f"{LINUX} · autoMovingTiff16 broke" in body and "2026-10-29" in body  # the log tail and the history
    assert "1 flaky (#" in alerts(s)[0] and "red" not in alerts(s)[0]
    # a flake is recorded once per run, however often it is processed
    rig.db.add_flake("autoMovingTiff16", LINUX, 2, "2023-11-14")
    assert len(rig.db.flake_history("autoMovingTiff16")) == 3


def test_an_open_issue_naming_the_feature_gets_a_comment_instead_of_a_ticket(rig: Rig) -> None:
    s = finished_nightly(rig, {f"{LINUX} · autoMovingTiff16": "failure", f"{LINUX} · removeAirplanes": "failure"},
                         {f"{LINUX} · autoMovingTiff16": "success"})
    s.gh.add_issue(53, "stard stalls on the desktop Linux leg", "autoMovingTiff16 hangs in the stard handshake")
    s.gh.add_issue(54, "autoMovingTiff1 is slow", "unrelated: a longer name must not match a prefix of it")
    follow(s)
    s.gh.finish_rerun(2)
    assert follow(s) == "done"
    assert sorted(s.gh.issues) == [53, 54, 55]  # only removeAirplanes (red, nothing covers it) got a ticket
    assert s.gh.issues[55]["title"] == "Gherkin nightly red: removeAirplanes"
    (comment,) = s.gh.comment_list[53]
    assert "actions/runs/2" in comment["body"] and "autoMovingTiff16" in comment["body"] and "flaky" in comment["body"]
    assert "broke" in comment["body"] and s.gh.comment_list[54] == []
    assert len(rig.db.flake_history("autoMovingTiff16")) == 1  # recorded even though no ticket was filed
    assert "#53" in alerts(s)[0]
    # the same title on a later night is the same issue
    s.gh.issues[55]["state"] = "open"
    item = gn.Item("red", "removeAirplanes", {LINUX: "x"}, {LINUX: "y"})
    covering = gn.covering_issue(s.gh, item)
    assert covering is not None and covering["number"] == 55


def test_per_night_cap_files_only_n_tickets_red_before_flaky(rig: Rig, tmp_path: Path) -> None:
    first = {f"{LINUX} · flakyA": "failure", f"{LINUX} · flakyB": "failure", f"{LINUX} · redA": "failure", f"{LINUX} · redB": "failure"}
    s = finished_nightly(rig, first, {f"{LINUX} · flakyA": "success", f"{LINUX} · flakyB": "success"})
    follow(s, Config(gherkin_nightly_max_tickets=3))
    s.gh.finish_rerun(2)
    assert follow(s, Config(gherkin_nightly_max_tickets=3)) == "done"
    assert [i["title"] for i in s.gh.issues.values()] == ["Gherkin nightly red: redA", "Gherkin nightly red: redB",
                                                          f"Gherkin flaky: flakyA ({LINUX})"]
    assert "left unfiled: flakyB" in alerts(s)[0]
    assert len(rig.db.flake_history("flakyB")) == 1  # still recorded: the next night files it if it is still failing

    # never past max_open_tickets, whatever the nightly cap
    (tmp_path / "second").mkdir()
    rig2 = Rig(tmp_path / "second")
    s = finished_nightly(rig2, {f"{LINUX} · redA": "failure", f"{LINUX} · redB": "failure"})
    s.gh.add_issue(7, "something else", labels=("pipeline",))
    cfg = Config(max_open_tickets=2, gherkin_nightly_max_tickets=6)
    follow(s, cfg)
    s.gh.finish_rerun(2)
    follow(s, cfg)
    assert [i["title"] for n, i in s.gh.issues.items() if n != 7] == ["Gherkin nightly red: redA"]
    assert "left unfiled: redB" in alerts(s)[0]


def test_green_nightly_files_nothing_and_next_night_is_skipped(rig: Rig) -> None:
    s = finished_nightly(rig, {f"{LINUX} · a": "success", f"{MAC} · a": "skipped"})
    assert follow(s) == "green"
    assert s.gh.reruns == [] and s.gh.issues == {} and rig.db.get(gn.FOLLOW_KEY) is None
    assert alerts(s) == ["Gherkin nightly 2: green"]
    assert follow(s) is None
    # the next night: the tip was tested and passed, so nothing is dispatched
    d = s.go()
    assert d.action == "skip" and len(s.gh.dispatched) == 1 and "already tested" in d.reason


def test_split_job_takes_the_leg_and_the_feature_and_drops_the_shard_number() -> None:
    assert gn.split_job("desktop (ubuntu-24.04) · autoMovingTiff16") == ("desktop (ubuntu-24.04)", "autoMovingTiff16")
    assert gn.split_job("cli (windows-2022) · shard 12: a, b") == ("cli (windows-2022)", "a, b")
    assert gn.split_job("gui (macos-14) · ui") == ("gui (macos-14)", "ui")
    assert gn.split_job("lonely") == ("", "lonely")
