"""What limits model sessions is masond's `llm:claude` count (ticket #169), not a number or a CPU gate in starpipe."""

from __future__ import annotations

import asyncio
from pathlib import Path

import pytest
from aiohttp.test_utils import TestClient, TestServer

from starpipe.agent import StageOutcome, StageRequest
from starpipe.config import Config, load
from starpipe.daemon import Daemon, activity

from .fakes import accepted, plan_args
from .test_engine import Rig, gated


@pytest.fixture
def rig(tmp_path: Path) -> Rig:
    return Rig(tmp_path)


def queue_ticket(rig: Rig, n: int) -> None:
    rig.gh.add_issue(n, f"ticket {n}")
    rig.engine.sync_issues()


def running_session(rig: Rig, ticket: int) -> None:
    rig.db.begin_stage(ticket, "develop", 1, "sonnet")


def test_the_session_and_cpu_settings_are_gone_and_an_old_config_still_loads(tmp_path: Path) -> None:
    gone = {"max_llm_sessions", "cpu_limit_pct", "cpu_window_s", "heavy_split", "heavy_build_slots", "heavy_free_mem_pct"}
    assert not gone & set(Config.model_fields)
    old = tmp_path / "config.toml"
    old.write_text("max_llm_sessions = 5\ncpu_limit_pct = 70.0\nheavy_build_slots = 2\napi_port = 1234\n")
    assert load(old).api_port == 1234


# claiming -------------------------------------------------------------------------------------------------------------
def test_tickets_in_a_state_but_with_no_session_running_do_not_count(rig: Rig) -> None:
    for n in (1, 2, 3):
        queue_ticket(rig, n)
    rig.db.set_state(1, "verifying")  # the daemon is running checks, or waiting for the heavy lock: no LLM involved
    rig.db.set_state(2, "developing")
    ticket = rig.engine.claimable()
    assert ticket is not None and ticket.number == 3


def test_claims_are_not_limited_by_running_sessions_masond_does_that(rig: Rig) -> None:
    for n in (1, 2, 3, 4):
        queue_ticket(rig, n)
    for n in (1, 2, 3):
        running_session(rig, n)
    assert rig.engine.claimable() is not None


# starting a stage -----------------------------------------------------------------------------------------------------
async def test_stages_wait_for_masond_instead_of_running_more_sessions_than_its_limit(rig: Rig, monkeypatch: pytest.MonkeyPatch) -> None:
    gate = gated(rig, monkeypatch, 1)  # masond's llm:claude is 1
    for n in (1, 2, 3):
        queue_ticket(rig, n)
    running = 0
    peak = 0
    seen_waiting: list[str] = []

    async def explore(req: StageRequest) -> StageOutcome:
        nonlocal running, peak
        running += 1
        peak = max(peak, running)
        await asyncio.sleep(0.05)  # long enough for the others to ask for a slot
        for n in (1, 2, 3):
            ticket = rig.db.ticket(n)
            assert ticket
            line = activity(rig.db, ticket)
            if "waiting to start" in line:
                seen_waiting.append(line)
        running -= 1
        req.contract.submit_plan(plan_args())
        return accepted(req)

    rig.agent.on("explore", explore, explore, explore)
    rig.agent.on("develop", lambda r: StageOutcome("no-result"), lambda r: StageOutcome("no-result"),
                 lambda r: StageOutcome("no-result"))
    await asyncio.wait_for(asyncio.gather(*(rig.engine.drive(n) for n in (1, 2, 3))), 60)
    assert peak == 1, "never more sessions at once than masond grants"
    assert [r.stage for r in rig.agent.requests if r.stage == "explore"] == ["explore"] * 3, "all three still ran"
    assert seen_waiting, "the activity line says it is waiting"
    assert len(gate.released) == len(gate.started), "every hold ended with its stage"


async def test_the_wait_note_is_cleared_once_the_stage_starts(rig: Rig) -> None:
    queue_ticket(rig, 1)
    rig.db.put("llm_wait:1", "stale")
    rig.agent.on("explore", lambda r: (r.contract.submit_plan(plan_args()), accepted(r))[1])
    rig.agent.on("develop", lambda r: StageOutcome("no-result"))
    await rig.engine.drive(1)
    assert rig.db.get("llm_wait:1") is None


# the limit is MASON's ----------------------------------------------------------------------------------------------------
async def test_the_limits_endpoint_shows_sessions_and_refuses_changes(rig: Rig) -> None:
    daemon = Daemon(rig.engine, Config(), token="tok")
    client = TestClient(TestServer(daemon.app()))
    await client.start_server()
    auth = {"Authorization": "Bearer tok"}
    try:
        running_session(rig, 1)
        shown = await (await client.get("/v1/limits", headers=auth)).json()
        assert shown["llm_active"] == 1 and "mason resources limit llm:claude" in shown["limit"]
        for body in ({"llm": 4}, {"cpu": 70}, {"reset": True}):
            r = await client.post("/v1/limits", json=body, headers=auth)
            assert r.status == 400 and "mason resources limit llm:claude" in await r.text()
        r = await client.post("/v1/settings", json={"max_active": 3}, headers=auth)
        assert r.status == 400
    finally:
        await client.close()


def test_the_status_reports_the_sessions(rig: Rig) -> None:
    daemon = Daemon(rig.engine, Config(), token="t")
    running_session(rig, 1)
    res = daemon.status()["resources"]
    assert isinstance(res, dict) and res["llm_active"] == 1 and "llm_max" not in res and "cpu_pct" not in res
