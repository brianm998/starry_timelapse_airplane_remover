from __future__ import annotations

import asyncio
import json
import shutil
import time
from pathlib import Path
from typing import Any

import pytest
from aiohttp.test_utils import TestClient, TestServer

from starpipe import selfupdate
from starpipe.agent import StageOutcome, StageRequest
from starpipe.config import Config
from starpipe.daemon import Daemon, activity
from starpipe.github import GitHubError
from starpipe.tickets import lint, parse_pipeline

from .fakes import GOOD_BODY, accepted, plan_args, sh
from .test_engine import Rig, explore_ok
from .test_selfupdate import Launchctl, fake_plist, noop_sync, ok_test


@pytest.fixture
def rig(tmp_path: Path) -> Rig:
    return Rig(tmp_path)


async def api(rig: Rig) -> tuple[TestClient[Any, Any], Daemon]:
    d = Daemon(rig.engine, Config(), token="tok")
    client = TestClient(TestServer(d.app()))
    await client.start_server()
    return client, d


AUTH = {"Authorization": "Bearer tok"}


async def test_the_api_requires_the_token(rig: Rig) -> None:
    client, _ = await api(rig)
    try:
        assert (await client.get("/v1/status")).status == 401
        assert (await client.get("/v1/status", headers={"Authorization": "Bearer nope"})).status == 401
        assert (await client.get("/v1/status", headers=AUTH)).status == 200
    finally:
        await client.close()


async def test_status_and_show_report_the_ticket_and_its_activity(rig: Rig) -> None:
    rig.gh.add_issue(7, "Tidy the docs")
    rig.engine.sync_issues()
    client, _ = await api(rig)
    try:
        data = await (await client.get("/v1/status", headers=AUTH)).json()
        assert data["tickets"][0]["number"] == 7 and data["tickets"][0]["activity"] == "queued"
        shown = await (await client.get("/v1/tickets/7", headers=AUTH)).json()
        assert shown["title"] == "Tidy the docs" and shown["stages"] == []
        assert (await client.get("/v1/tickets/99", headers=AUTH)).status == 404
    finally:
        await client.close()


async def test_retry_and_answer_ask_for_a_catch_up(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    rig.db.add_question(7, "develop", "which?", {})
    rig.db.set_state(7, "needs-input", "waiting")
    client, _ = await api(rig)
    try:
        assert rig.db.get("catch_up:7") is None
        assert (await client.post("/v1/tickets/7/answer", json={"text": "the first"}, headers=AUTH)).status == 200
        assert rig.db.get("catch_up:7") == "1", "answer: develop is merged in before the stage resumes"
        rig.db.put("catch_up:7", None)
        assert (await client.post("/v1/tickets/7/retry", json={"stage": "review"}, headers=AUTH)).status == 200
        assert rig.db.get("catch_up:7") == "1", "retry: the same"
    finally:
        await client.close()


async def test_retry_when_unblocked_records_instead_of_retrying(rig: Rig) -> None:
    rig.gh.add_issue(7, "failed one")
    rig.gh.add_issue(174, "first blocker")
    rig.gh.add_issue(199, "second blocker")
    rig.gh.deps[7] = [174, 199]
    rig.engine.sync_issues()
    rig.db.set_state(7, "failed", "CI still red after 2 fix cycles")
    client, _ = await api(rig)
    try:
        r = await client.post("/v1/tickets/7/retry", json={"stage": "ci", "when_unblocked": True}, headers=AUTH)
        assert r.status == 200 and "waiting for #174, #199" in (await r.json())["result"]
        assert rig.state(7) == "failed" and rig.db.get("held_retry:7") == "ci"
        shown = await (await client.get("/v1/tickets/7", headers=AUTH)).json()
        assert shown["held_retry"] == "retry from ci when unblocked"
        assert shown["activity"] == "failed · waiting for #174, #199 → retry from ci"
        assert [r["kind"] for r in rig.db._all("SELECT kind FROM interventions")] == ["hold-retry"]  # pyright: ignore[reportPrivateUsage]

        rig.db.set_state(174, "landed")  # a blocker landing is reflected at once
        assert activity(rig.db, rig.db.ticket(7)) == "failed · waiting for #199 → retry from ci"  # type: ignore[arg-type]

        rig.db.set_state(7, "developing")  # only a failed or cancelled ticket can hold a retry
        r = await client.post("/v1/tickets/7/retry", json={"stage": "ci", "when_unblocked": True}, headers=AUTH)
        assert r.status == 409
        rig.db.set_state(7, "failed")
        await client.post("/v1/tickets/7/cancel", json={}, headers=AUTH)
        assert rig.db.get("held_retry:7") is None, "cancelling drops the hold"
    finally:
        await client.close()


async def test_activity_lists_open_blockers_of_a_queued_ticket(rig: Rig) -> None:
    for n, title in [(7, "blocked"), (8, "free"), (84, "first blocker"), (85, "second blocker")]:
        rig.gh.add_issue(n, title)
    rig.gh.deps[7] = [84, 85]
    rig.engine.sync_issues()
    t7, t8 = rig.db.ticket(7), rig.db.ticket(8)
    assert t7 and t8
    assert activity(rig.db, t7) == "queued: #84, #85"
    assert activity(rig.db, t8) == "queued"
    rig.db.set_state(84, "landed")
    assert activity(rig.db, t7) == "queued: #85"
    rig.db.set_state(85, "closed")
    assert activity(rig.db, t7) == "queued"


async def test_show_lists_blockers_with_titles_and_caches_github_lookups(rig: Rig) -> None:
    rig.gh.add_issue(7, "blocked")
    rig.gh.add_issue(84, "a pipeline blocker")
    rig.gh.add_issue(85, "an ordinary issue", labels=())  # not a pipeline ticket: its title comes from GitHub
    rig.gh.add_issue(86, "already landed")
    rig.gh.deps[7] = [84, 85, 86]
    rig.engine.sync_issues()
    assert rig.db.ticket(85) is None
    rig.db.set_state(86, "landed")
    asked: list[int] = []
    real_issue = rig.gh.issue

    def counting_issue(n: int) -> dict[str, Any]:
        asked.append(n)
        return real_issue(n)

    rig.gh.issue = counting_issue  # type: ignore[method-assign]
    client, _ = await api(rig)
    try:
        for _ in range(2):
            shown = await (await client.get("/v1/tickets/7", headers=AUTH)).json()
            assert shown["blockers"] == [{"number": 84, "title": "a pipeline blocker"},
                                         {"number": 85, "title": "an ordinary issue"}]
        assert asked == [85], "the non-pipeline title is fetched once, the pipeline one never"
        assert (await (await client.get("/v1/tickets/84", headers=AUTH)).json())["blockers"] == []
    finally:
        await client.close()


async def test_show_returns_the_open_questions_options_and_why(rig: Rig) -> None:
    for n in (7, 8, 9):
        rig.gh.add_issue(n, f"t{n}")
    rig.engine.sync_issues()
    rig.db.add_question(7, "explore", "which way?", {"question": "which way?", "why": "the repo is silent",
                                                     "options": ["left", " right ", "", 3, None], "recommendation": "right"})
    rig.db.add_question(8, "explore", "anything?", {})
    rig.db.add_question(9, "explore", "odd", {"options": "left", "why": None})
    client, _ = await api(rig)
    try:
        q = (await (await client.get("/v1/tickets/7", headers=AUTH)).json())["question"]
        assert q == {"text": "which way?", "why": "the repo is silent", "options": ["left", "right", "3"],
                     "recommendation": "right"}
        q = (await (await client.get("/v1/tickets/8", headers=AUTH)).json())["question"]
        assert q == {"text": "anything?", "why": "", "options": [], "recommendation": ""}
        q = (await (await client.get("/v1/tickets/9", headers=AUTH)).json())["question"]
        assert q["options"] == [] and q["why"] == ""
    finally:
        await client.close()


async def test_answer_retry_cancel_prio_and_pause(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    qid = rig.db.add_question(7, "explore", "which?", {})
    rig.db.set_state(7, "needs-input", "waiting")
    client, d = await api(rig)
    try:
        r = await client.post("/v1/tickets/7/answer", json={"text": "the first"}, headers=AUTH)
        assert r.status == 200 and rig.state(7) == "exploring"
        assert rig.db.open_question(7) is None and qid
        assert (await client.post("/v1/tickets/7/answer", json={"text": "x"}, headers=AUTH)).status == 409

        await client.post("/v1/tickets/7/retry", json={"stage": "develop"}, headers=AUTH)
        assert rig.state(7) == "developing"
        assert (await client.post("/v1/tickets/7/retry", json={"stage": "nope"}, headers=AUTH)).status == 400

        await client.post("/v1/tickets/7/prio", json={"priority": 0}, headers=AUTH)
        t = rig.db.ticket(7)
        assert t and t.priority == 0

        await client.post("/v1/pause", json={"scope": "claims"}, headers=AUTH)
        rig.db.set_state(7, "queued")
        assert rig.engine.claimable() is None
        await client.post("/v1/resume", headers=AUTH)
        assert rig.engine.claimable() is not None

        await client.post("/v1/tickets/7/cancel", json={"reason": "no"}, headers=AUTH)
        assert rig.state(7) == "cancelled"
        kinds = [r["kind"] for r in rig.db._all("SELECT kind FROM interventions")]  # pyright: ignore[reportPrivateUsage]
        assert kinds == ["answer", "retry", "cancel"]
        assert d
    finally:
        await client.close()


async def test_settings_stores_max_active_and_snapshot_reports_it(rig: Rig) -> None:
    client, _ = await api(rig)
    try:
        snap = await (await client.get("/v1/snapshot", headers=AUTH)).json()
        assert snap["max_active"] == rig.engine.config.max_llm_sessions
        assert (await client.post("/v1/settings", json={"max_active": 4}, headers=AUTH)).status == 200
        assert rig.db.get("max_active") == "4" and rig.engine.max_active() == 4
        snap = await (await client.get("/v1/snapshot", headers=AUTH)).json()
        assert snap["max_active"] == 4
        for bad in (0, 7, -1, "3", 2.5, True, None):
            r = await client.post("/v1/settings", json={"max_active": bad}, headers=AUTH)
            assert r.status == 400, bad
        assert (await client.post("/v1/settings", json={}, headers=AUTH)).status == 400
        assert rig.db.get("max_active") == "4"
        assert (await client.post("/v1/settings", json={"max_active": 6}, headers=AUTH)).status == 200
        assert (await client.post("/v1/settings", json={"max_active": 1}, headers=AUTH)).status == 200
        assert rig.engine.max_active() == 1
    finally:
        await client.close()


async def test_land_now_is_refused_outside_ready_ci_landing(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    client, _ = await api(rig)
    try:
        for state in ("queued", "exploring", "developing", "review", "needs-input", "failed", "landed", "cancelled"):
            rig.db.set_state(7, state)
            assert (await client.post("/v1/tickets/7/land-now", headers=AUTH)).status == 409, state
        assert rig.db.get("land_now:7") is None
        assert rig.db._all("SELECT kind FROM interventions") == []  # pyright: ignore[reportPrivateUsage]
        for state in ("ready", "ci", "landing"):
            rig.db.set_state(7, state)
            assert (await client.post("/v1/tickets/7/land-now", headers=AUTH)).status == 200, state
        assert (await client.post("/v1/tickets/99/land-now", headers=AUTH)).status == 404
    finally:
        await client.close()


async def test_land_now_records_an_intervention(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    rig.db.set_state(7, "landing")
    client, _ = await api(rig)
    try:
        assert (await client.post("/v1/tickets/7/land-now", headers=AUTH)).status == 200
        rows = rig.db._all("SELECT ticket, kind, stage FROM interventions")  # pyright: ignore[reportPrivateUsage]
        assert [(r["ticket"], r["kind"], r["stage"]) for r in rows] == [(7, "land-now", "landing")]
        assert rig.db.get("land_now:7") == "1"
        await client.post("/v1/tickets/7/retry", json={"stage": "develop"}, headers=AUTH)
        assert rig.db.get("land_now:7") is None  # a retried ticket is tested again
    finally:
        await client.close()


async def test_restart_resumes_an_interrupted_stage_by_session_id(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    t = rig.engine.claim(rig.engine.claimable() or rig.db.tickets()[0])
    sid = rig.db.begin_stage(7, "explore", 1, "opus")
    rig.db.set_session(sid, "S-old")  # the daemon died here: the stage row never ended
    daemon = Daemon(rig.engine, Config(), token="tok")
    daemon.reconcile()
    assert rig.db.running_stages() == []
    assert rig.db.stages(7)[0]["outcome"] == "interrupted"

    seen: list[StageRequest] = []

    def explore(req: StageRequest) -> StageOutcome:
        seen.append(req)
        req.contract.submit_plan(plan_args())
        return accepted(req, "S-old")

    rig.agent.on("explore", explore)
    rig.agent.on("develop", lambda r: StageOutcome("no-result"))
    await rig.engine.drive(t.number)
    assert seen[0].resume == "S-old"


async def test_a_task_that_dies_is_restarted(rig: Rig) -> None:
    d = Daemon(rig.engine, Config(), token="tok")
    calls = {"n": 0}

    async def flaky() -> None:
        calls["n"] += 1
        if calls["n"] < 3:
            raise RuntimeError("boom")

    await d.supervise("flaky", flaky, delay=0.0)
    assert calls["n"] == 3 and "flaky died" in d.last_error


async def test_schedule_once_claims_one_ticket_and_runs_it(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    rig.agent.on("explore", explore_ok)
    rig.agent.on("develop", lambda r: StageOutcome("no-result"))
    d = Daemon(rig.engine, Config(), token="tok")
    d.schedule_once()
    await asyncio.gather(*d.tasks.values())
    assert rig.db.stages(7)[0]["stage"] == "explore"


def test_activity_line(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    t = rig.db.ticket(7)
    assert t
    rig.db.begin_stage(7, "develop", 2, "opus")
    t = rig.engine.claim(t)
    rig.db.set_state(7, "developing")
    t = rig.db.ticket(7)
    assert t and activity(rig.db, t, rig.now + 600).startswith("developing · attempt 2/3 · 10m")


async def test_the_session_id_is_recorded_as_soon_as_it_is_known_so_a_kill_can_resume(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    seen: list[StageRequest] = []

    def killed_mid_stage(req: StageRequest) -> StageOutcome:
        seen.append(req)
        req.on_session("S-early")  # the SDK reported the id; the run then died without a result message
        return StageOutcome("crash")

    def resumed(req: StageRequest) -> StageOutcome:
        seen.append(req)
        req.contract.submit_plan(plan_args())
        return accepted(req, "S-early")

    rig.agent.on("explore", killed_mid_stage, resumed)
    rig.agent.on("develop", lambda r: StageOutcome("no-result"))
    await rig.engine.drive(7)
    assert seen[1].resume == "S-early"
    assert rig.db.stages(7, "explore")[0]["session_id"] == "S-early"


async def test_requeue_moves_a_ticket_in_its_own_ci_onto_the_train(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    rig.db.set_state(7, "ci")
    rig.db.set_fields(7, pr_number=101)
    rig.gh.prs[101] = {"number": 101, "title": "t", "body": "", "branch": "pipe/7-t", "merged": False, "mergeable": True,
                       "merge_commit_sha": None}
    client, _ = await api(rig)
    try:
        r = await client.post("/v1/tickets/7/requeue", json={}, headers=AUTH)
        assert r.status == 200 and rig.state(7) == "ready"
        t = rig.db.ticket(7)
        assert t and t.pr_number is None
        assert rig.gh.closed_prs and "landing train" in rig.gh.closed_prs[0][1]
        assert [r["kind"] for r in rig.db._all("SELECT kind FROM interventions")] == ["requeue"]  # pyright: ignore[reportPrivateUsage]
        assert (await client.post("/v1/tickets/7/requeue", json={}, headers=AUTH)).status == 409, "it is ready now, not in CI"
    finally:
        await client.close()


def commit_under(repo: Path, rel: str, text: str) -> str:
    """Commit one file to the working clone's develop and publish it to the bare origin; return the new sha."""
    (repo / rel).parent.mkdir(parents=True, exist_ok=True)
    (repo / rel).write_text(text)
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-q", "-m", f"edit {rel}")
    sh(repo, "git", "push", "-q", "origin", "HEAD:develop")
    sh(repo, "git", "fetch", "-q")
    return sh(repo, "git", "rev-parse", "HEAD").strip()


async def monitor_update(client: TestClient[Any, Any], sha: str) -> dict[str, Any]:
    resp = await client.get("/v1/monitor-update", params={"sha": sha}, headers=AUTH)
    assert resp.status == 200
    return await resp.json()  # type: ignore[no-any-return]


async def test_monitor_update_reports_commits_behind_under_pipeline_monitor_and_the_latest_sha(rig: Rig) -> None:
    repo = rig.engine.repo
    built = commit_under(repo, "pipeline/monitor/a.swift", "one\n")
    commit_under(repo, "pipeline/monitor/a.swift", "two\n")
    newest = commit_under(repo, "pipeline/monitor/b.swift", "three\n")
    assert sh(repo, "git", "rev-parse", "origin/develop").strip() == newest
    client, _ = await api(rig)
    try:
        assert await monitor_update(client, built) == {"behind": 2, "latest": newest}
    finally:
        await client.close()


async def test_requeue_refuses_a_ticket_that_is_already_in_a_batch(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    rig.db.set_state(7, "ci")
    bid = rig.db.batch_create("0" * 40)
    rig.db.batch_add(bid, 7, 0)
    client, _ = await api(rig)
    try:
        assert (await client.post("/v1/tickets/7/requeue", json={}, headers=AUTH)).status == 409
        assert rig.state(7) == "ci" and rig.gh.closed_prs == []
    finally:
        await client.close()


async def test_monitor_update_is_zero_behind_when_up_to_date_and_ignores_other_paths(rig: Rig) -> None:
    repo = rig.engine.repo
    built = commit_under(repo, "pipeline/monitor/a.swift", "one\n")
    commit_under(repo, "docs/b.md", "elsewhere\n")
    commit_under(repo, "pipeline/src/x.py", "daemon only\n")
    client, _ = await api(rig)
    try:
        assert await monitor_update(client, built) == {"behind": 0, "latest": built}
    finally:
        await client.close()


async def test_requeue_also_cancels_the_ci_runs_of_the_pr_it_closes(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    rig.db.set_state(7, "ci")
    rig.db.set_fields(7, pr_number=101, branch="pipe/7-t")
    rig.gh.prs[101] = {"number": 101, "title": "t", "body": "", "branch": "pipe/7-t", "merged": False, "mergeable": True,
                       "merge_commit_sha": None}
    client, _ = await api(rig)
    try:
        assert (await client.post("/v1/tickets/7/requeue", json={}, headers=AUTH)).status == 200
        assert rig.gh.cancelled_branches == ["pipe/7-t"]
    finally:
        await client.close()


async def test_monitor_update_for_an_unknown_sha_is_behind_null_not_an_error(rig: Rig) -> None:
    latest = commit_under(rig.engine.repo, "pipeline/monitor/a.swift", "one\n")
    client, _ = await api(rig)
    try:
        for sha in ("deadbeef" * 5, "", "--output=x", "HEAD"):
            assert await monitor_update(client, sha) == {"behind": None, "latest": latest}
    finally:
        await client.close()


ISSUES = "https://github.com/brianm998/starry_timelapse_airplane_remover/issues"


async def test_resolve_reports_number_title_state_and_queued_for_an_issue_in_this_repo(rig: Rig) -> None:
    rig.gh.add_issue(8, "Fix the sky", author="someone", labels=())
    rig.gh.add_issue(9, "Already approved")
    client, _ = await api(rig)
    try:
        r = await client.get("/v1/issues/resolve", params={"url": f"{ISSUES}/8"}, headers=AUTH)
        assert r.status == 200
        assert await r.json() == {"number": 8, "title": "Fix the sky", "state": "open", "queued": False,
                                  "models": ["opus", "sonnet", "haiku"],
                                  "stages": ["explore", "develop", "fix", "review", "resolve", "ci_fix", "conflict"]}
        r = await client.get("/v1/issues/resolve", params={"url": f" {ISSUES}/9#issuecomment-1\n"}, headers=AUTH)
        assert (await r.json())["queued"] is True
    finally:
        await client.close()


async def test_resolve_rejects_another_repo_a_pull_request_a_closed_issue_and_a_malformed_url(rig: Rig) -> None:
    rig.gh.add_issue(10, "a PR in disguise", labels=())
    rig.gh.issues[10]["pull_request"] = {"url": "x"}
    rig.gh.add_issue(11, "done", labels=())
    rig.gh.issues[11]["state"] = "closed"
    client, _ = await api(rig)
    try:
        for url in ("https://github.com/someone/else/issues/8",
                    "https://github.com/brianm998/starry_timelapse_airplane_remover/pull/8",
                    f"{ISSUES}/10", f"{ISSUES}/11", f"{ISSUES}/99", "not a url"):
            r = await client.get("/v1/issues/resolve", params={"url": url}, headers=AUTH)
            assert 400 <= r.status < 500, url
            assert (await r.text()).strip(), url
        assert (await client.get("/v1/issues/resolve", headers=AUTH)).status == 400
    finally:
        await client.close()


async def test_enqueue_labels_unlabelled_issues_skips_labelled_ones_and_sync_issues_queues_them(rig: Rig) -> None:
    rig.gh.add_issue(8, "Fix the sky", author="someone", labels=())
    rig.gh.timelines[8] = []
    rig.gh.add_issue(9, "Already approved")
    rig.engine.sync_issues()
    assert rig.db.ticket(8) is None
    client, _ = await api(rig)
    try:
        r = await client.post("/v1/enqueue", json={"numbers": [8, 9]}, headers=AUTH)
        assert r.status == 200
        assert (await r.json())["results"] == [{"number": 8, "result": "labelled"},
                                               {"number": 9, "result": "already queued"}]
        assert [lab["name"] for lab in rig.gh.issues[8]["labels"]] == ["pipeline"]
        assert [lab["name"] for lab in rig.gh.issues[9]["labels"]].count("pipeline") == 1
        assert (await client.post("/v1/enqueue", json={"numbers": []}, headers=AUTH)).status == 400
    finally:
        await client.close()
    rig.engine.sync_issues()
    assert rig.state(8) == "queued"


async def test_enqueue_with_models_adds_replaces_keeps_and_creates_the_pipeline_section(rig: Rig) -> None:
    with_section = GOOD_BODY + "\n## Pipeline\ngherkin: no · model_develop: haiku · effort_fix: high · model_review: opus\n"
    fenced = "```\n## Pipeline\nmodel_fix: haiku\n```\n\n" + GOOD_BODY
    rig.gh.add_issue(8, "No section", author="someone", labels=())
    rig.gh.add_issue(9, "Has a section", author="someone", labels=())
    rig.gh.issues[9]["body"] = with_section + "\n## Notes\nlater\n"
    rig.gh.add_issue(10, "Heading in a fence", author="someone", labels=())
    rig.gh.issues[10]["body"] = fenced
    client, _ = await api(rig)
    try:
        r = await client.post("/v1/enqueue", json={"numbers": [8, 9, 10],
                                                   "models": {"develop": "sonnet", "ci_fix": "opus"}}, headers=AUTH)
        assert r.status == 200
        assert [x["result"] for x in (await r.json())["results"]] == ["labelled"] * 3
    finally:
        await client.close()
    bodies = {n: rig.gh.issues[n]["body"] for n in (8, 9, 10)}
    chosen = "model_develop: sonnet · model_ci_fix: opus"
    assert bodies[8] == GOOD_BODY.rstrip("\n") + f"\n\n## Pipeline\n{chosen}\n"
    assert parse_pipeline(bodies[9]) == {"gherkin": "no", "model_develop": "sonnet", "effort_fix": "high",
                                         "model_review": "opus", "model_ci_fix": "opus"}
    assert "gherkin: no · model_develop: sonnet · effort_fix: high · model_review: opus · model_ci_fix: opus\n\n## Notes\nlater" in bodies[9]
    assert bodies[9].count("## Pipeline") == 1
    assert bodies[10].startswith(fenced) and bodies[10].endswith(f"## Pipeline\n{chosen}\n")
    assert parse_pipeline(bodies[10]) == {"model_develop": "sonnet", "model_ci_fix": "opus"}
    assert all(lint(b).ok for b in bodies.values())
    assert all("pipeline" in {lab["name"] for lab in rig.gh.issues[n]["labels"]} for n in (8, 9, 10))


async def test_enqueue_without_models_leaves_the_body_alone(rig: Rig) -> None:
    rig.gh.add_issue(8, "Fix the sky", author="someone", labels=())
    client, _ = await api(rig)
    try:
        r = await client.post("/v1/enqueue", json={"numbers": [8], "models": {}}, headers=AUTH)
        assert r.status == 200
    finally:
        await client.close()
    assert rig.gh.issues[8]["body"] == GOOD_BODY


async def test_enqueue_rejects_unknown_stages_and_disallowed_models_without_touching_any_issue(rig: Rig) -> None:
    rig.gh.add_issue(8, "Fix the sky", author="someone", labels=())
    rig.gh.add_issue(9, "Also", author="someone", labels=())
    client, _ = await api(rig)
    try:
        for models in ({"nonsense": "opus"}, {"ci-fix": "opus"}, {"develop": "fable"}, {"develop": "gpt"},
                       {"develop": "sonnet", "review": "fable"}, {"develop": 3}, ["develop"]):
            r = await client.post("/v1/enqueue", json={"numbers": [8, 9], "models": models}, headers=AUTH)
            assert r.status == 400, models
            assert (await r.text()).strip(), models
    finally:
        await client.close()
    assert [rig.gh.issues[n]["body"] for n in (8, 9)] == [GOOD_BODY, GOOD_BODY]
    assert [rig.gh.issues[n]["labels"] for n in (8, 9)] == [[], []]


async def test_enqueue_allows_fable_when_the_config_does(rig: Rig) -> None:
    rig.gh.add_issue(8, "Fix the sky", author="someone", labels=())
    d = Daemon(rig.engine, Config(allow_fable=True), token="tok")
    client = TestClient(TestServer(d.app()))
    await client.start_server()
    try:
        r = await client.post("/v1/enqueue", json={"numbers": [8], "models": {"review": "fable"}}, headers=AUTH)
        assert r.status == 200
        resolved = await client.get("/v1/issues/resolve", params={"url": f"{ISSUES}/8"}, headers=AUTH)
        assert (await resolved.json())["models"] == ["opus", "sonnet", "haiku", "fable"]
    finally:
        await client.close()
    assert parse_pipeline(rig.gh.issues[8]["body"]) == {"model_review": "fable"}


# self-update ---------------------------------------------------------------------------------------------------------
def commit_to_origin(repo: Path, rel: str, text: str) -> str:
    """A commit on develop in the working clone, sent to the (local, bare) origin. Returns its sha."""
    path = repo / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-q", "-m", f"change {rel}")
    sh(repo, "git", "push", "-q", "origin", "HEAD:develop")
    return sh(repo, "git", "rev-parse", "HEAD").strip()


class Pinned:
    """A daemon running from a pinned runtime built at origin/develop's tip, with origin free to move on."""

    def __init__(self, rig: Rig, tmp: Path) -> None:
        self.rig, self.repo = rig, rig.engine.repo
        self.base = commit_to_origin(self.repo, "pipeline/bin/starpipe", "#!/bin/bash\necho starpipe\n")
        self.plist = fake_plist(tmp)
        selfupdate.switch(selfupdate.build(self.repo, self.base, noop_sync), self.plist, Launchctl(), now=1.0, restart=False)
        self.daemon = Daemon(rig.engine, Config(remote="origin"), token="t")
        self.exits: list[int] = []
        self.daemon.exit = self.exits.append
        self.built: list[Path] = []
        self.tested: list[Path] = []

    def sync(self, rt: Path) -> None:
        self.built.append(rt)
        noop_sync(rt)

    def check(self, rt: Path) -> tuple[bool, str]:
        self.tested.append(rt)
        return ok_test(rt)

    def once(self, test: Any = None) -> str | None:
        return self.daemon.self_update_once(self.plist, sync=self.sync, test=test or self.check)

    def current_sha(self) -> str | None:
        cur = selfupdate.link("current")
        return selfupdate.runtime_sha(cur) if cur else None


async def test_a_passing_smoke_check_holds_new_work_and_swaps_only_when_idle(rig: Rig, tmp_path: Path) -> None:
    pin = Pinned(rig, tmp_path)
    rig.gh.add_issue(1, "running")
    rig.gh.add_issue(2, "waiting")
    rig.engine.sync_issues()
    assert rig.engine.claimable() is not None
    rig.db.begin_stage(1, "develop", 1, "sonnet")  # a stage is mid-session
    target = commit_to_origin(pin.repo, "pipeline/src/new.py", "x = 1\n")

    assert pin.once() == "pending"
    assert rig.db.get("self_update_pending") == target and len(pin.tested) == 1, "staged and smoke-checked"
    assert pin.current_sha() == pin.base and not pin.exits, "the swap waits for the running stage"
    assert rig.db.get("pause") is None, "the hold is not the owner's pause flag"
    assert rig.engine.claimable() is None, "no claims while an update is pending"
    assert pin.once() == "pending" and len(pin.tested) == 1, "still waiting, and not smoke-checked again"

    await pin.daemon.update_step(pin.plist, pin.sync, pin.check)
    assert pin.exits == [] and pin.current_sha() == pin.base

    rig.db.end_stage(rig.db.running_stages()[0]["id"], "accepted")
    await pin.daemon.update_step(pin.plist, pin.sync, pin.check)
    assert pin.exits == [0], "the daemon exits 0 for launchd to restart it"
    assert pin.current_sha() == target and selfupdate.link("previous") == selfupdate.runtime_dir(pin.base).resolve()
    events = [e for e in rig.db.events_since() if e["kind"] == "self-update"]
    assert len(events) == 1 and events[0]["data"] == {"old": pin.base, "new": target}

    pin.daemon.reconcile()  # the restarted process: no hold, claims resume
    assert rig.db.get("self_update_pending") is None and rig.engine.claimable() is not None


async def test_the_swap_does_not_prune(rig: Rig, tmp_path: Path) -> None:
    pin = Pinned(rig, tmp_path)
    stray = selfupdate.runtime_root() / "runtime-stray"
    stray.mkdir()
    target = commit_to_origin(pin.repo, "pipeline/src/new.py", "x = 1\n")
    await pin.daemon.update_step(pin.plist, pin.sync, pin.check)
    assert pin.exits == [0] and pin.current_sha() == target
    assert selfupdate.link("previous") == selfupdate.runtime_dir(pin.base).resolve() and selfupdate.runtime_dir(pin.base).is_dir()
    assert stray.is_dir(), "nothing is pruned in the swap, so a rollback still has its runtime"


async def test_prune_runs_once_the_runtime_has_settled(rig: Rig, tmp_path: Path) -> None:
    pin = Pinned(rig, tmp_path)
    target = commit_to_origin(pin.repo, "pipeline/src/new.py", "x = 1\n")
    assert pin.once() == "swapped"
    stray = selfupdate.runtime_root() / "runtime-stray"
    stray.mkdir()
    await pin.daemon.update_step(pin.plist, pin.sync, pin.check)
    assert stray.is_dir(), "inside the crash-loop window nothing is pruned"
    (selfupdate.runtime_root() / "switched_at").write_text(str(time.time() - selfupdate.CRASH_WINDOW_S - 1))
    await pin.daemon.update_step(pin.plist, pin.sync, pin.check)
    assert not stray.exists(), "an unlinked runtime goes once the current one has settled"
    assert pin.current_sha() == target and selfupdate.link("previous") == selfupdate.runtime_dir(pin.base).resolve()
    assert selfupdate.runtime_dir(pin.base).is_dir() and pin.exits == []


async def test_pending_update_swaps_after_the_drain_window_with_stages_running(rig: Rig, tmp_path: Path) -> None:
    pin = Pinned(rig, tmp_path)
    rig.gh.add_issue(1, "running")
    rig.gh.add_issue(2, "waiting")
    rig.engine.sync_issues()
    rig.db.begin_stage(1, "develop", 1, "sonnet")
    target = commit_to_origin(pin.repo, "pipeline/src/new.py", "x = 1\n")
    drain = rig.engine.config.self_update_drain_s

    assert pin.once() == "pending" and rig.db.get("self_update_pending_since") == str(rig.now)
    rig.now += drain - 1
    assert pin.once() == "pending" and pin.current_sha() == pin.base and rig.engine.claimable() is None, "inside the window"

    rig.now += 2
    assert pin.once() == "swapped", "past the window it swaps with the stage still running"
    assert pin.current_sha() == target and len(rig.db.running_stages()) == 1
    events = [e for e in rig.db.events_since() if e["kind"] == "self-update"]
    assert events[0]["data"] == {"old": pin.base, "new": target, "interrupted": [1]}
    assert rig.db.get("self_update_pending") is None and rig.db.get("self_update_pending_since") is None

    pin.daemon.reconcile()  # the restarted process marks the stage interrupted; drive() resumes it by session id
    assert rig.db.running_stages() == [] and rig.db.stages(1)[0]["outcome"] == "interrupted"


async def test_self_update_still_waits_for_the_nightly(rig: Rig, tmp_path: Path) -> None:
    pin = Pinned(rig, tmp_path)
    rig.db.begin_stage(1, "develop", 1, "sonnet")
    target = commit_to_origin(pin.repo, "pipeline/src/new.py", "x = 1\n")
    assert pin.once() == "pending"
    rig.now += rig.engine.config.self_update_drain_s + 1  # past the window, with a stage running
    gate = asyncio.Event()

    async def nightly() -> int:
        await gate.wait()
        return 0

    pin.daemon.nightly_task = asyncio.create_task(nightly())
    assert pin.once() is None and pin.current_sha() == pin.base, "a nightly is running: no swap even past the window"
    gate.set()
    await pin.daemon.nightly_task
    assert pin.once() == "swapped" and pin.current_sha() == target


async def test_a_pending_update_holds_the_next_model_stage(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    rig.db.put("self_update_pending", "abc")
    requests_when_released: list[int] = []

    async def release(_seconds: float) -> None:
        requests_when_released.append(len(rig.agent.requests))
        rig.db.put("self_update_pending", None)

    rig.engine.sleep = release  # type: ignore[assignment]
    rig.agent.on("explore", explore_ok)
    rig.agent.on("develop", lambda r: StageOutcome("no-result"))
    await rig.engine.drive(7)
    assert requests_when_released == [0], "no stage began while the update was pending"
    assert rig.db.stages(7)[0]["stage"] == "explore", "and it began once the hold cleared"


async def test_swap_to_a_vanished_runtime_restages_instead_of_exiting(rig: Rig, tmp_path: Path) -> None:
    pin = Pinned(rig, tmp_path)
    rig.db.begin_stage(1, "develop", 1, "sonnet")
    target = commit_to_origin(pin.repo, "pipeline/src/new.py", "x = 1\n")
    assert pin.once() == "pending" and rig.db.get("self_update_pending") == target
    shutil.rmtree(selfupdate.runtime_dir(target))  # pruned (or damaged) after it was staged
    rig.db.end_stage(rig.db.running_stages()[0]["id"], "accepted")

    await pin.daemon.update_step(pin.plist, pin.sync, pin.check)
    assert pin.exits == [] and pin.current_sha() == pin.base, "no exit, and current still points at a runtime that runs"
    assert rig.db.get("self_update_pending") is None and rig.db.get("self_update_failed") is None
    assert len(pin.built) == 1, "nothing rebuilt yet"

    await pin.daemon.update_step(pin.plist, pin.sync, pin.check)  # the next poll rebuilds it and swaps
    assert len(pin.built) == 2 and pin.exits == [0] and pin.current_sha() == target
    assert (selfupdate.runtime_dir(target) / ".complete").is_file()


async def test_a_failing_smoke_check_keeps_the_running_version_and_is_not_retried(rig: Rig, tmp_path: Path) -> None:
    pin = Pinned(rig, tmp_path)
    target = commit_to_origin(pin.repo, "pipeline/src/new.py", "import nope\n")
    calls: list[Path] = []

    def bad(rt: Path) -> tuple[bool, str]:
        calls.append(rt)
        return False, "ModuleNotFoundError: nope"

    assert pin.once(bad) == "failed"
    assert pin.current_sha() == pin.base and not pin.exits
    assert rig.db.get("self_update_pending") is None
    events = [e for e in rig.db.events_since() if e["kind"] == "self-update-failed"]
    assert len(events) == 1 and events[0]["data"]["sha"] == target and "ModuleNotFoundError" in events[0]["data"]["output"]
    assert not selfupdate.runtime_dir(target).exists(), "the failed staging copy is removed"
    assert any(t == "star pipeline: self-update-failed" for t, _ in rig.pages)
    client, _ = await api(rig)
    try:
        status = await (await client.get("/v1/status", headers=AUTH)).json()
    finally:
        await client.close()
    assert target[:10] in status["daemon"]["error"] and "ModuleNotFoundError" in status["daemon"]["error"]
    assert status["self_update"]["failed"]["sha"] == target

    assert pin.once(bad) is None and len(calls) == 1, "the same sha is not tried again"
    newer = commit_to_origin(pin.repo, "pipeline/src/newer.py", "y = 2\n")
    assert pin.once() == "swapped" and pin.current_sha() == newer, "a later sha gets its own try"
    assert rig.db.get("self_update_failed") is None


async def test_a_build_that_raises_counts_as_a_failed_smoke_check(rig: Rig, tmp_path: Path) -> None:
    pin = Pinned(rig, tmp_path)
    target = commit_to_origin(pin.repo, "pipeline/src/new.py", "x = 1\n")

    def broken_sync(_rt: Path) -> None:
        raise RuntimeError("uv sync failed")

    assert pin.daemon.self_update_once(pin.plist, sync=broken_sync, test=pin.check) == "failed"
    assert pin.current_sha() == pin.base and not pin.tested
    assert "uv sync failed" in str(rig.db.get("self_update_failed")) and target in str(rig.db.get("self_update_failed"))


async def test_no_update_during_a_nightly_or_for_non_pipeline_changes(rig: Rig, tmp_path: Path) -> None:
    pin = Pinned(rig, tmp_path)
    commit_to_origin(pin.repo, "docs/b.md", "docs only\n")
    commit_to_origin(pin.repo, "pipeline/monitor/App.swift", "// the monitor app is not the daemon\n")
    assert pin.once() is None and not pin.built and not pin.tested, "only non-pipeline paths changed"
    assert rig.db.get("self_update_pending") is None

    commit_to_origin(pin.repo, "pipeline/src/new.py", "x = 1\n")
    gate = asyncio.Event()

    async def nightly() -> int:
        await gate.wait()
        return 0

    pin.daemon.nightly_task = asyncio.create_task(nightly())
    assert pin.once() is None and not pin.built and not pin.tested, "a nightly is running: nothing is staged"
    assert rig.db.get("self_update_pending") is None and pin.current_sha() == pin.base

    gate.set()
    await pin.daemon.nightly_task
    assert pin.once() == "swapped" and pin.built


def test_with_no_pinned_runtime_nothing_updates(rig: Rig) -> None:
    d = Daemon(rig.engine, Config(remote="origin"), token="t")
    assert d.self_update_once(Path("/nonexistent.plist"), sync=noop_sync, test=ok_test) is None


async def test_picking_opus_in_the_monitor_and_allow_opus_are_how_a_ticket_may_use_it(rig: Rig) -> None:
    rig.gh.add_issue(8, "picked", author="someone", labels=())
    rig.gh.add_issue(9, "not picked", author="someone", labels=())
    rig.gh.add_issue(10, "later")
    rig.engine.sync_issues()
    client, _ = await api(rig)
    try:
        r = await client.post("/v1/enqueue", json={"numbers": [8], "models": {"develop": "opus"}}, headers=AUTH)
        assert r.status == 200
        r = await client.post("/v1/enqueue", json={"numbers": [9], "models": {"develop": "sonnet"}}, headers=AUTH)
        assert r.status == 200
        assert rig.db.get("opus_ok:8") == "1" and rig.db.get("opus_ok:9") is None
        assert (await client.post("/v1/tickets/10/allow-opus", json={}, headers=AUTH)).status == 200
        assert rig.db.get("opus_ok:10") == "1"
    finally:
        await client.close()


async def test_mute_is_persisted_reported_and_silences_announcements(rig: Rig) -> None:
    client, _ = await api(rig)
    try:
        snap = await (await client.get("/v1/snapshot", headers=AUTH)).json()
        assert snap["muted"] is False
        for bad in ("yes", 1, None):
            assert (await client.post("/v1/mute", json={"muted": bad}, headers=AUTH)).status == 400
        assert (await client.post("/v1/mute", json={"muted": True}, headers=AUTH)).status == 200
        assert rig.db.get("muted") == "1"
        snap = await (await client.get("/v1/snapshot", headers=AUTH)).json()
        assert snap["muted"] is True
        rig.engine.announce("landed", 5)
        assert rig.announcer.calls == []
        restarted = Daemon(rig.engine, Config(), token="tok")  # a new daemon on the same db: still muted
        assert restarted.status()["muted"] is True
        assert (await client.post("/v1/mute", json={"muted": False}, headers=AUTH)).status == 200
        snap = await (await client.get("/v1/snapshot", headers=AUTH)).json()
        assert snap["muted"] is False
        rig.engine.announce("landed", 5)
        assert rig.announcer.calls == [("landed", 5)]
    finally:
        await client.close()


def test_hard_exit_is_the_default_exit_and_ends_the_process_without_unwinding(monkeypatch: pytest.MonkeyPatch, rig: Rig) -> None:
    from starpipe import daemon as daemon_mod

    calls: list[int] = []
    monkeypatch.setattr(daemon_mod.os, "_exit", calls.append)
    assert daemon_mod.Daemon(rig.engine, rig.engine.config).exit is daemon_mod.hard_exit
    daemon_mod.hard_exit(0)
    assert calls == [0], "os._exit, not sys.exit: SystemExit would wait on non-daemon threads and hang"


def landing_daemon(rig: Rig, window: int = 120) -> Daemon:
    return Daemon(rig.engine, Config(landing_mode="batch", batch_window_s=window), token="tok")


def ready_tickets(rig: Rig, *numbers: int) -> None:
    for n in numbers:
        rig.gh.add_issue(n, f"t{n}")
    rig.engine.sync_issues()
    for n in numbers:
        rig.engine._to_state(n, "ready")  # pyright: ignore[reportPrivateUsage]


def activity_of(d: Daemon, n: int) -> str:
    return next(t["activity"] for t in d.snapshot()["tickets"] if t["number"] == n)  # type: ignore[index, union-attr]


def test_snapshot_shows_the_active_batch_in_each_phase(rig: Rig) -> None:
    ready_tickets(rig, 1, 2)
    d = landing_daemon(rig)
    assert d.snapshot()["landing"]["batch"] is None  # type: ignore[index]
    bid = rig.db.batch_create("0" * 40)
    rig.db.batch_add(bid, 1, 0)
    rig.db.batch_add(bid, 2, 1)
    rig.now += 90
    for phase in ("building", "ci", "landing"):
        rig.db.batch_update(bid, state=phase)
        landing = d.snapshot()["landing"]
        assert landing["batch"] == {"number": bid, "phase": phase, "age_s": 90, "members": [1, 2],  # type: ignore[index]
                                    "pr_number": None, "ci": "running", "slow": False}
        assert d.status()["landing"]["batch"]["phase"] == phase  # type: ignore[index]


def test_ready_ticket_reads_in_batch_n_while_building(rig: Rig) -> None:
    ready_tickets(rig, 1, 2, 3)
    d = landing_daemon(rig)
    bid = rig.db.batch_create("0" * 40)
    rig.db.batch_add(bid, 1, 0)
    rig.db.batch_add(bid, 2, 1)
    assert activity_of(d, 1) == f"ready · in batch {bid} (building)"
    assert activity_of(d, 2) == f"ready · in batch {bid} (building)"
    assert activity_of(d, 3) == f"ready · waiting for the next batch (batch {bid} is building)"


def test_ready_ticket_reads_waiting_for_the_next_batch_with_the_countdown(rig: Rig) -> None:
    ready_tickets(rig, 1)
    d = landing_daemon(rig, window=120)
    rig.now += 30
    assert activity_of(d, 1) == "ready · waiting for the next batch (starts in 90s)"
    assert d.snapshot()["landing"]["next_batch_in_s"] == 90  # type: ignore[index]
    rig.now += 100
    assert activity_of(d, 1) == "ready · waiting for the next batch (starting)"
    assert d.snapshot()["landing"]["next_batch_in_s"] == 0  # type: ignore[index]


def test_ready_activity_names_the_feature_gate(rig: Rig) -> None:
    rig.gh.add_issue(1, "t1", f"{GOOD_BODY}\n## Pipeline\ngherkin: autoMovingTiff16, uiX\n")
    ready_tickets(rig, 2)
    rig.engine.sync_issues()
    rig.engine._to_state(1, "ready")  # pyright: ignore[reportPrivateUsage]
    d = landing_daemon(rig)
    bid = rig.db.batch_create("0" * 40)
    rig.db.batch_update(bid, state="ci")  # a batch is in CI, but #1 is owed its feature run first
    assert activity_of(d, 1) == "ready · proving Gherkin features (autoMovingTiff16, uiX)"
    assert activity_of(d, 2) == f"ready · waiting for the next batch (batch {bid} is ci)", "no features: nothing to prove"
    rig.db.put("gherkin_err:1", json.dumps({"sha": "abc", "error": "gh: Bad Gateway (HTTP 502)", "count": 2}))
    assert activity_of(d, 1) == ("ready · proving Gherkin features (autoMovingTiff16, uiX) · "
                                 "last poll failed: gh: Bad Gateway (HTTP 502)")
    rig.db.put("gherkin_ok:1", "abc")
    assert activity_of(d, 1) == f"ready · waiting for the next batch (batch {bid} is ci)", "proven: it waits on the train"


def test_snapshot_remembers_the_last_abandoned_batch_for_an_hour(rig: Rig) -> None:
    d = landing_daemon(rig)
    old = rig.db.batch_create("0" * 40)
    rig.db.batch_update(old, state="abandoned", ended=rig.now, note="an older reason")
    rig.now += 10
    bid = rig.db.batch_create("0" * 40)
    rig.db.batch_update(bid, state="abandoned", ended=rig.now,
                        note="develop moved with overlapping changes: rebuilding on the new base")
    rig.now += 18 * 60
    snap = d.snapshot()["landing"]
    assert snap["batch"] is None  # type: ignore[index]
    assert snap["last_abandoned"] == {"number": bid, "state": "abandoned", "ended": rig.now - 18 * 60, "ago_s": 18 * 60,  # type: ignore[index]
                                      "reason": "develop moved with overlapping changes: rebuilding on the new base"}
    rig.now += 41 * 60  # 59 minutes since it ended
    assert d.snapshot()["landing"]["last_abandoned"]["number"] == bid  # type: ignore[index]
    rig.now += 2 * 60  # over the hour
    assert d.snapshot()["landing"]["last_abandoned"] is None  # type: ignore[index]


def test_a_batch_building_over_ten_minutes_is_marked_slow(rig: Rig) -> None:
    d = landing_daemon(rig)
    bid = rig.db.batch_create("0" * 40)
    rig.now += 599
    assert d.snapshot()["landing"]["batch"]["slow"] is False  # type: ignore[index]
    rig.now += 2
    assert d.snapshot()["landing"]["batch"]["slow"] is True  # type: ignore[index]
    rig.db.batch_update(bid, state="ci")  # only a batch still building is slow: CI is expected to take long
    assert d.snapshot()["landing"]["batch"]["slow"] is False  # type: ignore[index]


async def test_restart_finishes_an_escalation_it_cut_short(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    rig.engine.claim(rig.engine.claimable() or rig.db.tickets()[0])
    rig.db.add_question(7, "explore", "ship it?", {"question": "ship it?", "why": "unclear", "options": []})
    assert rig.db.open_question(7)["comment_id"] is None  # type: ignore[index]  # the daemon died before posting it
    Daemon(rig.engine, Config(), token="tok").reconcile()
    assert rig.state(7) == "needs-input"
    assert rig.db.open_question(7)["comment_id"] is not None  # type: ignore[index]


async def test_hung_heavy_job_raises_an_alert(rig: Rig) -> None:
    from starpipe.checks import ledger

    def hung_runner(worktree: Path, base: str) -> list[ledger.Result]:
        return [ledger.Result("test:daemon", "hung", "abc", 1.0,
                              detail="hung: `swift test --package-path daemon` made no progress for 900s and was killed")]

    rig.engine.check_runner = hung_runner
    rig.gh.add_issue(7, "Tidy the docs")
    rig.engine.sync_issues()
    rig.agent.on("explore", explore_ok)

    def develop(req: StageRequest) -> StageOutcome:
        req.contract.run_checks({})
        return StageOutcome("no-result")

    rig.agent.on("develop", develop)
    await rig.engine.drive(7)

    assert "heavy-hung:7" in [a["key"] for a in rig.db.open_alerts()]
    client, _ = await api(rig)
    try:
        status = await (await client.get("/v1/status", headers=AUTH)).json()
    finally:
        await client.close()
    alert = next(a for a in status["alerts"] if a["key"] == "heavy-hung:7")
    assert "#7" in alert["text"] and "swift test --package-path daemon" in alert["text"]
    assert [t for t, _ in rig.pages].count("star pipeline: heavy-hung") == 1


def propose(rig: Rig, n: int, title: str, by: str = "review agent", labels: tuple[str, ...] = ("pipe:proposed",)) -> None:
    rig.gh.add_issue(n, title, body=f"{GOOD_BODY}\n<!-- starpipe:filed-by:{by} -->", labels=labels)


def labels_of(rig: Rig, n: int) -> set[str]:
    return {lab["name"] for lab in rig.gh.issues[n]["labels"]}


async def test_snapshot_proposal_without_a_marker_has_author_and_no_by(rig: Rig) -> None:
    rig.gh.add_issue(30, "By hand", body=GOOD_BODY, author="someone", labels=("pipe:proposed",))
    d = Daemon(rig.engine, Config(), token="tok")
    await d.poll_once()
    assert d.snapshot()["proposals"] == [{"number": 30, "title": "By hand", "by": None, "author": "someone",
                                          "created_at": "2026-11-01T10:00:00Z"}]


async def test_snapshot_lists_proposals_from_the_last_poll(rig: Rig) -> None:
    propose(rig, 21, "Show the retry budget")
    propose(rig, 22, "Rename a key", by="interactive")
    rig.gh.add_issue(23, "Ordinary ticket")
    d = Daemon(rig.engine, Config(), token="tok")
    assert d.snapshot()["proposals"] == []  # nothing polled yet
    await d.poll_once()
    expected = [{"number": 21, "title": "Show the retry budget", "by": "review agent",
                 "author": "brianm998", "created_at": "2026-11-01T10:00:00Z"},
                {"number": 22, "title": "Rename a key", "by": "interactive",
                 "author": "brianm998", "created_at": "2026-11-01T10:00:00Z"}]
    assert d.snapshot()["proposals"] == expected

    def boom(path: str) -> list[dict[str, Any]]:
        raise AssertionError(f"snapshot asked GitHub for {path}")
    rig.gh.paged = boom  # type: ignore[method-assign]
    assert d.snapshot()["proposals"] == expected  # served from the cache
    del rig.gh.paged  # type: ignore[attr-defined]
    real = rig.gh.paged

    def down(path: str) -> list[dict[str, Any]]:
        raise GitHubError("HTTP 502")
    rig.gh.paged = down  # type: ignore[method-assign]
    await d.poll_once()  # a failing refresh keeps the last list
    assert d.last_error.startswith("github:") and d.snapshot()["proposals"] == expected
    rig.gh.paged = real  # type: ignore[method-assign]


async def test_approve_endpoint_labels_the_issue_and_drops_it_from_the_list(rig: Rig) -> None:
    propose(rig, 21, "Show the retry budget")
    propose(rig, 22, "Rename a key")
    client, d = await api(rig)
    try:
        await d.poll_once()
        r = await client.post("/v1/proposals/21/approve", json={"priority": "p1"}, headers=AUTH)
        assert r.status == 200 and (await r.json()) == {"result": "approved"}
        assert labels_of(rig, 21) == {"pipeline", "p1"}
        assert [p["number"] for p in d.snapshot()["proposals"]] == [22]  # type: ignore[union-attr, index]
        r = await client.post("/v1/proposals/22/approve", headers=AUTH)  # priority is optional
        assert r.status == 200 and labels_of(rig, 22) == {"pipeline"}
        assert d.snapshot()["proposals"] == []
        bad = await client.post("/v1/proposals/21/approve", json={"priority": "p9"}, headers=AUTH)
        assert bad.status == 400
    finally:
        await client.close()


async def test_approve_endpoint_refuses_a_full_queue_and_a_non_proposal(rig: Rig) -> None:
    propose(rig, 21, "Show the retry budget")
    rig.gh.add_issue(23, "Ordinary ticket", labels=("pipeline",))
    rig.gh.add_issue(24, "Unlabelled", labels=())
    client = TestClient(TestServer(Daemon(rig.engine, Config(max_open_tickets=1), token="tok").app()))
    await client.start_server()
    try:
        full = await client.post("/v1/proposals/21/approve", headers=AUTH)
        assert full.status == 409 and "already open" in await full.text()
        assert labels_of(rig, 21) == {"pipe:proposed"}  # untouched
        for n in (23, 24, 999):
            r = await client.post(f"/v1/proposals/{n}/approve", headers=AUTH)
            assert 400 <= r.status < 500 and "not a proposal" in await r.text(), n
        assert labels_of(rig, 24) == set()  # an arbitrary issue is never labelled `pipeline`
    finally:
        await client.close()


async def test_reject_endpoint_comments_closes_and_drops_it(rig: Rig) -> None:
    propose(rig, 21, "Show the retry budget")
    propose(rig, 22, "Rename a key")
    rig.gh.add_issue(23, "Ordinary ticket")
    client, d = await api(rig)
    try:
        await d.poll_once()
        r = await client.post("/v1/proposals/21/reject", json={"reason": "not now"}, headers=AUTH)
        assert r.status == 200 and (await r.json()) == {"result": "rejected"}
        assert rig.gh.issues[21]["state"] == "closed" and "pipe:proposed" not in labels_of(rig, 21)
        assert [c["body"] for c in rig.gh.comment_list[21]] == ["Not taking this up: not now"]
        assert [p["number"] for p in d.snapshot()["proposals"]] == [22]  # type: ignore[union-attr, index]
        r = await client.post("/v1/proposals/22/reject", headers=AUTH)  # the reason is optional
        assert r.status == 200 and [c["body"] for c in rig.gh.comment_list[22]] == ["Not taking this up."]
        assert (await client.post("/v1/proposals/23/reject", headers=AUTH)).status == 409
        assert rig.gh.issues[23]["state"] == "open"
        assert (await client.post("/v1/proposals/22/reject", json={"reason": 5}, headers=AUTH)).status == 400
    finally:
        await client.close()


async def test_land_all_marks_every_ticket_in_the_landing_queue(rig: Rig) -> None:
    for n, state in ((7, "ready"), (8, "ci"), (9, "developing")):
        rig.gh.add_issue(n, "t")
        rig.engine.sync_issues()
        rig.db.set_state(n, state)
    client, _ = await api(rig)
    try:
        r = await client.post("/v1/land-all", headers=AUTH)
        assert r.status == 200 and (await r.json())["tickets"] == [7, 8]
        assert rig.db.get("land_now:7") == "1" and rig.db.get("land_now:8") == "1" and rig.db.get("land_now:9") is None
    finally:
        await client.close()


async def test_proposal_detail_returns_the_issue(rig: Rig) -> None:
    propose(rig, 21, "Show the retry budget", labels=("pipe:proposed", "bug"))
    rig.gh.add_issue(22, "By hand", body=GOOD_BODY, author="someone", labels=("pipe:proposed",))
    client, _ = await api(rig)
    try:
        r = await client.get("/v1/proposals/21", headers=AUTH)
        assert r.status == 200
        d = await r.json()
        assert (d["number"], d["title"], d["author"]) == (21, "Show the retry budget", "brianm998")
        assert (d["created_at"], d["updated_at"]) == ("2026-11-01T10:00:00Z", "2026-11-02T10:00:00Z")
        assert d["labels"] == ["bug"] and d["by"] == "review agent"
        assert d["body"] == rig.gh.issues[21]["body"]
        by_hand = await (await client.get("/v1/proposals/22", headers=AUTH)).json()
        assert by_hand["by"] is None and by_hand["author"] == "someone"
    finally:
        await client.close()


async def test_proposal_detail_includes_the_latest_comments(rig: Rig) -> None:
    propose(rig, 21, "Show the retry budget")
    for i in range(25):
        rig.gh.say(21, f"u{i}", "x" * 5000 if i == 24 else f"c{i}", created_at=f"2026-11-02T12:{i:02d}:00Z")
    client, _ = await api(rig)
    try:
        d = await (await client.get("/v1/proposals/21", headers=AUTH)).json()
        assert d["comment_count"] == 25 and len(d["comments"]) == 20
        assert d["comments"][0] == {"author": "u5", "created_at": "2026-11-02T12:05:00Z", "body": "c5"}
        last = d["comments"][-1]["body"]
        assert last.startswith("x" * 4000) and len(last) < 4100 and last != "x" * 4000 and "truncated" in last
    finally:
        await client.close()


async def test_proposal_detail_lists_open_blockers(rig: Rig) -> None:
    propose(rig, 21, "Show the retry budget")
    rig.gh.add_issue(30, "Still open")
    rig.gh.add_issue(31, "Done already")
    rig.gh.close_issue(31)
    rig.gh.block(21, 30)
    rig.gh.block(21, 31)
    client, _ = await api(rig)
    try:
        d = await (await client.get("/v1/proposals/21", headers=AUTH)).json()
        assert d["blockers"] == [{"number": 30, "title": "Still open"}]
    finally:
        await client.close()


async def test_proposal_detail_says_how_ready_the_body_is(rig: Rig) -> None:
    planned = GOOD_BODY + "\n## Pipeline\neffort_develop: medium · gherkin: no\n\n## Plan\nsummary: do the whole thing\nparity: neither\nlocalization: no\n- approach: edit it\n"
    rig.gh.add_issue(21, "Planned", body=planned, labels=("pipe:proposed",))
    rig.gh.add_issue(22, "Bad", body="just words", labels=("pipe:proposed",))
    rig.gh.add_issue(23, "Queued", labels=("pipeline",))
    d = Daemon(rig.engine, Config(max_open_tickets=7), token="tok")
    client = TestClient(TestServer(d.app()))
    await client.start_server()
    try:
        good = (await (await client.get("/v1/proposals/21", headers=AUTH)).json())["readiness"]
        assert good["lint_ok"] is True and good["errors"] == [] and good["has_plan"] is True
        assert good["pipeline"] == {"effort_develop": "medium", "gherkin": "no"}
        assert good["queue"] == {"open": 1, "max": 7}
        bad = (await (await client.get("/v1/proposals/22", headers=AUTH)).json())["readiness"]
        assert bad["lint_ok"] is False and bad["errors"] and bad["has_plan"] is False and bad["pipeline"] == {}
    finally:
        await client.close()


async def test_proposal_detail_refuses_non_proposals_and_reports_github_errors(rig: Rig) -> None:
    propose(rig, 21, "Show the retry budget")
    rig.gh.add_issue(23, "Ordinary ticket", labels=("pipeline",))
    rig.gh.add_issue(24, "Unlabelled", labels=())
    client, _ = await api(rig)
    try:
        for n in (23, 24, 999):
            r = await client.get(f"/v1/proposals/{n}", headers=AUTH)
            assert r.status == 404 and "not a proposal" in await r.text(), n
        assert (await client.get("/v1/proposals/abc", headers=AUTH)).status == 400

        def down(path: str) -> list[dict[str, Any]]:
            raise GitHubError("HTTP 502 from GitHub")
        rig.gh.paged = down  # type: ignore[method-assign]
        r = await client.get("/v1/proposals/21", headers=AUTH)
        assert r.status == 502 and "HTTP 502 from GitHub" in await r.text()
    finally:
        await client.close()


def test_train_info_lists_every_active_batch(rig: Rig) -> None:
    from starpipe.cli import landing_lines

    ready_tickets(rig, 1, 2, 3)
    d = landing_daemon(rig)
    first = rig.db.batch_create("0" * 40)
    rig.db.batch_update(first, state="ci", pr_number=11)
    rig.db.batch_add(first, 1, 0)
    rig.now += 60
    second = rig.db.batch_create("0" * 40)
    rig.db.batch_add(second, 2, 0)  # still building
    rig.now += 30
    expected = [{"number": first, "phase": "ci", "age_s": 90, "members": [1], "pr_number": 11, "ci": "running", "slow": False},
                {"number": second, "phase": "building", "age_s": 30, "members": [2], "pr_number": None, "ci": "running", "slow": False}]
    for landing in (d.snapshot()["landing"], d.status()["landing"]):
        assert landing["batches"] == expected  # type: ignore[index]
        assert landing["batch"] == expected[0], "`batch` stays the oldest, so a client that shows one keeps working"  # type: ignore[index]
        lines = landing_lines(landing)  # type: ignore[arg-type]
        assert [line.split(":")[0] for line in lines] == [f"batch {first}", f"batch {second}"]
    assert activity_of(d, 3) == f"ready · waiting for the next batch (batch {first} is ci, batch {second} is building)"
    assert activity_of(d, 2) == f"ready · in batch {second} (building)"
