"""What limits starting work is resources, not a count of tickets: LLM sessions running and CPU use (owner's rule)."""

from __future__ import annotations

import asyncio
from pathlib import Path

import pytest
from aiohttp.test_utils import TestClient, TestServer

from starpipe import heavy, load
from starpipe.agent import StageOutcome, StageRequest
from starpipe.config import Config
from starpipe.daemon import Daemon, activity

from .fakes import accepted, plan_args
from .test_engine import Rig


@pytest.fixture
def rig(tmp_path: Path) -> Rig:
    r = Rig(tmp_path)
    r.engine.config.max_llm_sessions = 2
    r.engine.config.cpu_limit_pct = 80.0
    return r


def queue_ticket(rig: Rig, n: int) -> None:
    rig.gh.add_issue(n, f"ticket {n}")
    rig.engine.sync_issues()


def running_session(rig: Rig, ticket: int) -> None:
    rig.db.begin_stage(ticket, "develop", 1, "sonnet")


# the rule, alone -----------------------------------------------------------------------------------------------------
def test_with_nothing_running_a_session_may_always_start_even_at_full_cpu() -> None:
    assert load.room(0, 100.0, 3, 85.0).ok, "the pipeline must never stall itself"


def test_the_session_limit_and_the_cpu_limit_apply_once_something_is_running() -> None:
    assert load.room(1, 40.0, 3, 85.0).ok
    assert load.room(2, 84.0, 3, 85.0).ok
    full = load.room(3, 10.0, 3, 85.0)
    assert not full.ok and "3 of 3 LLM sessions" in full.reason
    busy = load.room(1, 91.0, 3, 85.0)
    assert not busy.ok and "CPU is at 91%" in busy.reason and "limit 85%" in busy.reason


def test_the_cpu_meter_averages_over_its_window_and_forgets_older_samples() -> None:
    now = {"t": 0.0}
    readings = iter([100.0, 100.0, 20.0, 20.0, 20.0])
    meter = load.CpuMeter(window_s=30.0, clock=lambda: now["t"], sampler=lambda: next(readings))
    assert meter.average() == 0.0, "no samples yet: it does not block before it knows"
    for t in (0, 10, 20):
        now["t"] = float(t)
        meter.sample()
    assert meter.average() == pytest.approx((100 + 100 + 20) / 3)
    for t in (40, 50):
        now["t"] = float(t)
        meter.sample()
    assert meter.average() == pytest.approx(20.0), "the two old 100% readings are outside the 30 s window"


# claiming -------------------------------------------------------------------------------------------------------------
def test_tickets_in_a_state_but_with_no_session_running_do_not_count(rig: Rig) -> None:
    for n in (1, 2, 3):
        queue_ticket(rig, n)
    rig.db.set_state(1, "verifying")  # the daemon is running checks, or waiting for the heavy lock: no LLM involved
    rig.db.set_state(2, "developing")
    ticket = rig.engine.claimable()
    assert ticket is not None and ticket.number == 3


def test_a_new_ticket_is_claimed_only_while_there_is_room_for_its_session(rig: Rig) -> None:
    for n in (1, 2, 3, 4):
        queue_ticket(rig, n)
    running_session(rig, 1)
    assert rig.engine.claimable() is not None  # 1 of 2
    running_session(rig, 2)
    assert rig.engine.claimable() is None, "2 of 2 sessions are running"
    rig.db.end_stage(rig.db.running_stages()[0]["id"], "accepted")
    assert rig.engine.claimable() is not None


def test_high_cpu_defers_a_claim_only_while_something_else_is_running(rig: Rig) -> None:
    queue_ticket(rig, 1)
    queue_ticket(rig, 2)
    rig.engine.cpu = lambda: 95.0
    assert rig.engine.claimable() is not None, "nothing is running, so it starts however busy the machine is"
    running_session(rig, 1)
    assert rig.engine.claimable() is None
    rig.engine.cpu = lambda: 30.0
    assert rig.engine.claimable() is not None


def test_a_session_waiting_for_the_heavy_lock_does_not_count_as_running(rig: Rig, monkeypatch: pytest.MonkeyPatch) -> None:
    queue_ticket(rig, 1)
    queue_ticket(rig, 2)
    rig.engine.config.max_llm_sessions = 1
    running_session(rig, 1)
    assert rig.engine.llm_active() == 1 and rig.engine.claimable() is None
    waiter = heavy.Waiter(priority=1, enqueued_at=0.0, pid=4242, started=0.0, ticket="1", cmd="swift test")
    monkeypatch.setattr(heavy, "status", lambda: heavy.Status([], [waiter]))
    assert rig.engine.llm_active() == 0, "ticket 1's session is blocked on the lock, not generating"
    assert rig.engine.claimable() is not None


# starting a stage -----------------------------------------------------------------------------------------------------
async def test_stages_wait_for_room_instead_of_running_more_sessions_than_the_limit(rig: Rig) -> None:
    rig.engine.config.max_llm_sessions = 1
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
    await asyncio.gather(*(rig.engine.drive(n) for n in (1, 2, 3)))
    assert peak == 1, "never more than the limit of sessions at once"
    assert [r.stage for r in rig.agent.requests if r.stage == "explore"] == ["explore"] * 3, "all three still ran"
    assert any("1 of 1 LLM sessions are running" in line for line in seen_waiting), "the activity line says why it is waiting"


async def test_a_stage_waits_out_a_cpu_spike_and_then_starts(rig: Rig) -> None:
    queue_ticket(rig, 1)
    running_session(rig, 99)  # something else is running, so the CPU limit applies
    readings = iter([95.0, 95.0, 95.0])
    rig.engine.cpu = lambda: next(readings, 20.0)
    rig.agent.on("explore", lambda r: (r.contract.submit_plan(plan_args()), accepted(r))[1])
    rig.agent.on("develop", lambda r: StageOutcome("no-result"))
    await rig.engine.drive(1)
    assert rig.slept.count(15) == 3, "it waited out exactly the three high readings, 15 s each"
    assert any(r.stage == "explore" for r in rig.agent.requests)


async def test_the_wait_note_is_cleared_once_the_stage_starts(rig: Rig) -> None:
    queue_ticket(rig, 1)
    rig.db.put("llm_wait:1", "stale")
    rig.agent.on("explore", lambda r: (r.contract.submit_plan(plan_args()), accepted(r))[1])
    rig.agent.on("develop", lambda r: StageOutcome("no-result"))
    await rig.engine.drive(1)
    assert rig.db.get("llm_wait:1") is None


# the limits can be changed while it runs ---------------------------------------------------------------------------------
def test_a_runtime_override_beats_the_config(rig: Rig) -> None:
    assert rig.engine.limits() == (2, 80.0)
    rig.db.put("limit_llm", "5")
    rig.db.put("limit_cpu", "60.5")
    assert rig.engine.limits() == (5, 60.5)


async def test_the_limits_endpoint_shows_sets_validates_and_resets(rig: Rig) -> None:
    daemon = Daemon(rig.engine, Config(), token="tok")
    client = TestClient(TestServer(daemon.app()))
    await client.start_server()
    auth = {"Authorization": "Bearer tok"}
    try:
        shown = await (await client.get("/v1/limits", headers=auth)).json()
        assert shown["llm_max"] == 2 and shown["cpu_limit"] == 80.0 and shown["overridden"] is False
        set_ = await (await client.post("/v1/limits", json={"llm": 4, "cpu": 70}, headers=auth)).json()
        assert set_["llm_max"] == 4 and set_["cpu_limit"] == 70.0 and set_["overridden"] is True
        assert (await client.post("/v1/limits", json={"llm": 0}, headers=auth)).status == 400
        assert (await client.post("/v1/limits", json={"cpu": 5}, headers=auth)).status == 400
        back = await (await client.post("/v1/limits", json={"reset": True}, headers=auth)).json()
        assert back["llm_max"] == 2 and back["overridden"] is False
    finally:
        await client.close()


def test_the_status_reports_the_resources(rig: Rig) -> None:
    daemon = Daemon(rig.engine, Config(), token="t")
    running_session(rig, 1)
    rig.engine.cpu = lambda: 91.0
    res = daemon.status()["resources"]
    assert res == {"llm_active": 1, "llm_max": 2, "cpu_pct": 91.0, "cpu_limit": 80.0,
                   "waiting": "CPU is at 91% (limit 80%)", "overridden": False}
