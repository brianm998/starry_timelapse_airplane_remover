from __future__ import annotations

import json
import time
from datetime import datetime
from pathlib import Path

import pytest
from aiohttp.test_utils import TestClient, TestServer

from starpipe import adapter_star as star
from starpipe import digest, gitutil, nightly
from starpipe.checks import ledger
from starpipe.config import Config
from starpipe.daemon import Daemon

from .fakes import sh
from .test_engine import Rig

REPO_ROOT = Path(__file__).resolve().parents[2]


def commit_gherkin(repo: Path) -> None:
    """Give origin/develop the generated feature lists the nightly reads."""
    gen = repo / "gherkin" / "generated"
    gen.mkdir(parents=True)
    (gen / "features-cli.json").write_text(json.dumps(["alpha", "beta"]))
    (gen / "features-mac-gui.json").write_text(json.dumps(["uiOne", "uiTwo", "alpha"]))
    (gen / "datasets-cli.txt").write_text("a7sii_10\nmoving\n")
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-q", "-m", "feature lists")
    sh(repo, "git", "push", "-q", "origin", "HEAD:develop")
    sh(repo, "git", "fetch", "-q")


class Harness:
    def __init__(self, rig: Rig, max_auto: int = 2) -> None:
        commit_gherkin(rig.engine.repo)
        self.rig = rig
        self.red: set[str] = set()
        self.ran: list[str] = []
        self.fetch_ok = True
        self.fetched: list[list[str]] = []
        cfg = Config(remote="origin", max_auto_tickets=max_auto)

        def fake_exec(check_id: str, spec: star.CheckSpec | None, root: Path) -> ledger.Result:
            self.ran.append(check_id)
            return ledger.Result(check_id, "fail" if check_id in self.red else "pass", "sha", 1.0, executed=1,
                                 failed=1 if check_id in self.red else 0, log="/nonexistent.log")

        def fake_fetch(root: Path, names: list[str], test_data: str) -> tuple[bool, str]:
            self.fetched.append(names)
            return self.fetch_ok, "" if self.fetch_ok else "no network"

        self.n = nightly.Nightly(rig.db, cfg, rig.gh, rig.engine.notifier, rig.engine.repo, exec=fake_exec, fetch=fake_fetch)


@pytest.fixture
def rig(tmp_path: Path) -> Rig:
    return Rig(tmp_path)


def test_the_nightly_is_due_once_a_day_after_its_start_time() -> None:
    def at(h: int, m: int, d: int = 31) -> datetime:
        return datetime(2026, 10, d, h, m)

    assert not nightly.due(at(2, 59), None, "03:00")
    assert nightly.due(at(3, 0), None, "03:00")
    assert nightly.due(at(14, 0), "2026-10-30", "03:00")
    assert not nightly.due(at(14, 0), "2026-10-31", "03:00")  # already ran today
    assert nightly.due(at(3, 1, 1), "2026-10-31", "03:00")  # tomorrow is another night


def test_suite_filters_match_ids_and_prefixes() -> None:
    assert nightly.wanted("test:logging", [])
    assert nightly.wanted("gherkin:cli/alpha", ["gherkin:cli/"])
    assert nightly.wanted("test:logging", ["test:logging"])
    assert not nightly.wanted("test:StarCore", ["test:logging", "gherkin:"])


def test_the_plan_for_this_repos_real_feature_lists() -> None:
    plan = nightly.build_plan(REPO_ROOT, nightly.Options(ui=True), "/data")
    cli_features = json.loads((REPO_ROOT / "gherkin/generated/features-cli.json").read_text())
    assert len(plan.gherkin_cli) == len(cli_features) >= 10
    first = plan.gherkin_cli[0]
    assert first.id == f"gherkin:cli/{cli_features[0]}" and first.expect == 1 and first.parser == "xctest"
    assert first.argv[-1] == f"GherkinTests.GeneratedFeatureTests/{star.gherkin_test_name(cli_features[0])}"
    assert dict(first.env)["STAR_TEST_DATA"] == "/data" and "{root}" in dict(first.env)["STAR_FFMPEG_DIR"]
    ui = plan.gherkin_ui
    assert ui is not None and ui.ui and ui.expect and ui.expect >= 20
    assert sum(1 for a in ui.argv if a.startswith("-only-testing:starUITests/GeneratedFeatureUITests/testUi")) == ui.expect
    assert set(plan.local) == set(star.nightly_local_checks()) and "test:StarCore" in plan.local
    assert nightly.build_plan(REPO_ROOT, nightly.Options(), "/d").gherkin_ui is None  # opt-in


def test_a_green_first_night_is_a_baseline_and_a_new_red_files_one_ticket(rig: Rig) -> None:
    h = Harness(rig)
    h.red = {"test:logging"}
    first = h.n.run(nightly.Options(suites=["test:logging", "gherkin:cli/"]))
    run = rig.db.nightly_run(first)
    assert run and run["status"] == "done" and run["summary"]["reds"] == ["test:logging"]
    assert run["summary"]["new_reds"] == [] and rig.gh.issues == {}, "never seen before: baseline, not news"
    assert h.fetched == [["a7sii_10", "moving"]]
    assert [r["check_id"] for r in run["results"]] == ["test:logging", "setup:removal_tools", "setup:trail_tools",
                                                       "gherkin:cli/alpha", "gherkin:cli/beta"]

    h.red = set()
    h.n.run(nightly.Options(suites=["test:logging", "gherkin:cli/"]))  # green
    h.red = {"gherkin:cli/alpha"}
    third = h.n.run(nightly.Options(suites=["test:logging", "gherkin:cli/"]))
    summary = rig.db.nightly_run(third)["summary"]  # type: ignore[index]
    assert summary["new_reds"] == ["gherkin:cli/alpha"]
    (issue,) = rig.gh.issues.values()
    assert issue["title"] == "nightly red: gherkin:cli/alpha"
    assert {"pipeline", "p1", "pipe:filed-by-pipeline"} <= {x["name"] for x in issue["labels"]}
    assert "passed the last time it ran" in issue["body"]

    h.n.run(nightly.Options(suites=["test:logging", "gherkin:cli/"]))  # still red: not new, no second ticket
    assert len(rig.gh.issues) == 1


def test_a_partial_run_does_not_erase_a_checks_history(rig: Rig) -> None:
    h = Harness(rig)
    h.n.run(nightly.Options(suites=["test:logging", "test:StarCpp"]))  # both green
    h.n.run(nightly.Options(suites=["test:StarCpp"]))  # a partial run: logging is not in it
    h.red = {"test:logging"}
    third = h.n.run(nightly.Options(suites=["test:logging"]))
    assert rig.db.nightly_run(third)["summary"]["new_reds"] == ["test:logging"]  # type: ignore[index]


def test_a_dry_run_says_what_it_would_file_and_files_nothing(rig: Rig) -> None:
    h = Harness(rig)
    h.n.run(nightly.Options(suites=["test:logging"]))
    h.red = {"test:logging"}
    run = h.n.run(nightly.Options(suites=["test:logging"], file_tickets=False))
    assert rig.db.nightly_run(run)["summary"]["filed"] == ["(dry run) nightly red: test:logging"]  # type: ignore[index]
    assert rig.gh.issues == {}


def test_auto_run_tickets_are_capped(rig: Rig) -> None:
    h = Harness(rig, max_auto=1)
    h.n.run(nightly.Options(suites=["test:logging", "test:StarCpp"]))
    h.red = {"test:logging", "test:StarCpp"}
    run = h.n.run(nightly.Options(suites=["test:logging", "test:StarCpp"]))
    assert len(rig.gh.issues) == 1
    assert len(rig.db.nightly_run(run)["summary"]["new_reds"]) == 2  # type: ignore[index]


def test_a_failed_dataset_fetch_marks_the_gherkin_checks_and_still_runs_the_rest(rig: Rig) -> None:
    h = Harness(rig)
    h.fetch_ok = False
    run = rig.db.nightly_run(h.n.run(nightly.Options(suites=["test:logging", "gherkin:cli/"])))
    assert run
    by_id = {r["check_id"]: r for r in run["results"]}
    assert by_id["test:logging"]["status"] == "pass"
    assert by_id["gherkin:cli/alpha"]["status"] == "setup-failed" and "no network" in by_id["gherkin:cli/alpha"]["log"]
    assert "gherkin:cli/alpha" not in h.ran and "setup:removal_tools" not in h.ran
    assert set(run["summary"]["reds"]) == {"gherkin:cli/alpha", "gherkin:cli/beta"}


def test_a_failed_tool_build_stops_the_gherkin_cli_leg(rig: Rig) -> None:
    h = Harness(rig)
    h.red = {"setup:trail_tools"}
    run = rig.db.nightly_run(h.n.run(nightly.Options(suites=["gherkin:cli/"])))
    assert run and all(r["status"] == "setup-failed" for r in run["results"] if r["check_id"].startswith("gherkin:"))
    assert "setup:removal_tools" in h.ran and "gherkin:cli/alpha" not in h.ran


def test_the_ui_leg_runs_only_when_asked_and_needs_no_setup(rig: Rig) -> None:
    h = Harness(rig)
    h.fetch_ok = False
    h.n.run(nightly.Options(suites=["gherkin:"]))
    assert "gherkin:gui-ui" not in h.ran
    h.n.run(nightly.Options(suites=["gherkin:"], ui=True))
    assert "gherkin:gui-ui" in h.ran  # the @ui features need neither datasets nor the verifier builds


def test_a_ref_that_does_not_exist_is_recorded_as_an_error_not_lost(rig: Rig) -> None:
    h = Harness(rig)
    with pytest.raises(RuntimeError):
        h.n.run(nightly.Options(ref="no-such-branch"))  # fails before a run row exists


def test_the_nightly_worktree_is_removed_afterwards(rig: Rig) -> None:
    h = Harness(rig)
    h.n.run(nightly.Options(suites=["test:logging"]))
    assert not (rig.engine.repo / ".claude" / "worktrees" / nightly.WORKTREE_NAME).exists()
    assert "pipe-nightly" not in sh(rig.engine.repo, "git", "worktree", "list")


def test_a_planted_red_on_a_scratch_ref_files_a_ticket(rig: Rig) -> None:
    """The Phase 6 'done when': a scratch branch with a reverted fix, run with --ref, files a ticket."""
    h = Harness(rig)
    h.n.run(nightly.Options(suites=["test:logging"]))  # green on develop
    repo = rig.engine.repo
    sh(repo, "git", "checkout", "-q", "-b", "scratch/reverted-fix")
    (repo / "docs" / "a.md").write_text("regressed\n")
    sh(repo, "git", "commit", "-qam", "revert the fix")
    sha = gitutil.head_sha(repo)
    sh(repo, "git", "checkout", "-q", "develop")
    seen: list[str] = []
    real = h.n.exec

    def red_on_the_scratch_sha(check_id: str, spec: star.CheckSpec | None, root: Path) -> ledger.Result:
        seen.append(gitutil.head_sha(root))
        result = real(check_id, spec, root)
        if gitutil.head_sha(root) == sha:
            result.status, result.failed = "fail", 1
        return result

    h.n.exec = red_on_the_scratch_sha
    h.n.run(nightly.Options(ref="scratch/reverted-fix", suites=["test:logging"]))
    assert seen == [sha], "it tested the scratch ref, not develop"
    assert [i["title"] for i in rig.gh.issues.values()] == ["nightly red: test:logging"]


# digest ------------------------------------------------------------------------------------------------------------
def test_the_digest_reports_what_the_pipeline_did(rig: Rig, tmp_path: Path) -> None:
    now = time.time()
    db = rig.db
    db.clock = lambda: now - 2 * 86400  # events two days ago
    for n in (7, 8):
        rig.gh.add_issue(n, f"t{n}")
    rig.engine.sync_issues()
    db.event("claimed", 7)
    db.clock = lambda: now - 2 * 86400 + 1800
    db.event("landed", 7)
    db.event("claimed", 8)
    db.clock = lambda: now - 86400
    db.event("landed", 8)
    db.event("state", 9, state="failed", reason="CI still red after 2 fix cycles: x")
    db.event("state", 9, state="failed", reason="CI still red after 2 fix cycles: y")
    db.intervention(7, "answer", "explore")
    db.intervention(8, "retry", "ci")
    db.intervention(8, "cancel", "ci")
    q1 = db.add_question(7, "explore", "a?", {})
    q2 = db.add_question(8, "explore", "b?", {})
    db.answer_question(q1, "x", "resolver")
    db.answer_question(q2, "y", "owner")
    path = tmp_path / "results.jsonl"
    ledger_rows = [{"at": now - 3600, "seconds": 36000.0, "lock_wait": 600.0}, {"at": now - 40 * 86400, "seconds": 999999.0}]
    path.write_text("\n".join(json.dumps(r) for r in ledger_rows))
    d = digest.build(db, now, 7, path)
    assert d.landed == [7, 8]
    assert d.median_claim_to_land_s and 1000 < d.median_claim_to_land_s < 90000
    assert d.interventions == {"answer": 1, "cancel": 1, "retry": 1} and d.interventions_per_ticket == 1.5
    assert d.park_reasons == [("CI still red after 2 fix cycles", 2)]
    assert (d.questions, d.resolver_answers) == (2, 1)
    assert d.lock_busy_fraction == pytest.approx(36000 / (7 * 86400)) and d.lock_wait_s == 600
    text = d.render()
    assert "**Landed:** 2 ticket(s) (#7, #8)" in text
    assert "answered by the resolver:** 1 of 2" in text and "CI still red after 2 fix cycles" in text


def test_an_empty_week_renders_without_dividing_by_zero(rig: Rig) -> None:
    text = digest.build(rig.db, time.time()).render()
    assert "**Landed:** 0 ticket(s)" in text and "n/a" in text


# the daemon's endpoints and snapshot ---------------------------------------------------------------------------------
async def test_the_nightly_endpoints_and_the_snapshots_nightly_field(rig: Rig) -> None:
    d = Daemon(rig.engine, Config(), token="tok")
    assert d.snapshot()["nightly"] is None
    run = rig.db.nightly_begin("origin/develop", "a" * 40)
    rig.db.nightly_result(run, "test:logging", "pass", 68, 0, 0, 12.0, 0.0, "/log")
    rig.db.nightly_end(run, "done", {"reds": ["gherkin:cli/alpha"]})
    info = d.snapshot()["nightly"]
    assert info and info["reds"] == 1 and info["running"] is False and str(info["line"]).endswith("1 red")  # type: ignore[union-attr]

    client = TestClient(TestServer(d.app()))
    await client.start_server()
    try:
        auth = {"Authorization": "Bearer tok"}
        data = await (await client.get("/v1/nightly", headers=auth)).json()
        assert data["results"][0]["check_id"] == "test:logging" and data["summary"]["reds"] == ["gherkin:cli/alpha"]
    finally:
        await client.close()


async def test_a_second_nightly_is_refused_while_one_runs(rig: Rig) -> None:
    import asyncio

    d = Daemon(rig.engine, Config(), token="tok")
    gate = asyncio.Event()

    async def hold() -> int:
        await gate.wait()
        return 1

    d.nightly_task = asyncio.create_task(hold())
    assert d.start_nightly(nightly.Options()) is None
    gate.set()
    await d.nightly_task
    assert d.nightly_task.done()


def test_the_weekly_digest_is_written_to_a_file(rig: Rig) -> None:
    d = Daemon(rig.engine, Config(), token="tok")
    path = d.write_digest(time.time())
    assert path.exists() and path.read_text().startswith("# Star pipeline digest")
    assert any(e["kind"] == "digest" for e in rig.db.events_since(0))
