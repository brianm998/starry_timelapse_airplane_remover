from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Any

import pytest
from aiohttp.test_utils import TestClient, TestServer

from starpipe.agent import StageOutcome, StageRequest
from starpipe.config import Config
from starpipe.daemon import Daemon, activity

from .fakes import accepted, plan_args
from .test_engine import Rig, explore_ok


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


ISSUES = "https://github.com/brianm998/starry_timelapse_airplane_remover/issues"


async def test_resolve_reports_number_title_state_and_queued_for_an_issue_in_this_repo(rig: Rig) -> None:
    rig.gh.add_issue(8, "Fix the sky", author="someone", labels=())
    rig.gh.add_issue(9, "Already approved")
    client, _ = await api(rig)
    try:
        r = await client.get("/v1/issues/resolve", params={"url": f"{ISSUES}/8"}, headers=AUTH)
        assert r.status == 200
        assert await r.json() == {"number": 8, "title": "Fix the sky", "state": "open", "queued": False}
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
