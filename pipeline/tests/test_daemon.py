from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Any

import pytest
from aiohttp.test_utils import TestClient, TestServer

from starpipe.agent import StageOutcome, StageRequest
from starpipe.config import Config
from starpipe.daemon import Daemon, activity

from .fakes import accepted, plan_args, sh
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


async def test_monitor_update_for_an_unknown_sha_is_behind_null_not_an_error(rig: Rig) -> None:
    latest = commit_under(rig.engine.repo, "pipeline/monitor/a.swift", "one\n")
    client, _ = await api(rig)
    try:
        for sha in ("deadbeef" * 5, "", "--output=x", "HEAD"):
            assert await monitor_update(client, sha) == {"behind": None, "latest": latest}
    finally:
        await client.close()
