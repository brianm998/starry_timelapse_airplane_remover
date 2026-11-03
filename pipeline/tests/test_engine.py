from __future__ import annotations

import asyncio
import json
import time
from pathlib import Path
from typing import Any

import pytest

from starpipe import gitutil, guards, negctl, worktrees
from starpipe.agent import StageOutcome, StageRequest
from starpipe.config import Config
from starpipe.db import Database
from starpipe.engine import Engine
from starpipe.notify import Notifier
from starpipe.tickets import filed_by

from .fakes import (
    GOOD_BODY,
    OWNER,
    FakeAgent,
    FakeAnnouncer,
    FakeGitHub,
    accepted,
    commit_change,
    green_runner,
    make_repo,
    plan_args,
    sh,
)


class Rig:
    def __init__(self, tmp: Path) -> None:
        self.db = Database(tmp / "state.db")
        self.gh = FakeGitHub(origin=tmp / "origin.git")
        self.agent = FakeAgent()
        self.pages: list[tuple[str, str]] = []
        self.announcer = FakeAnnouncer()
        self.slept: list[float] = []
        self.now = time.time()

        async def sleep(s: float) -> None:
            self.slept.append(s)
            self.now += s
            await asyncio.sleep(0)  # yield like the real sleep: a ticket polling for room must let the others run

        self.engine = Engine(Config(remote="origin", landing_mode="single"), self.db, self.gh, self.agent, make_repo(tmp), green_runner,
                             Notifier(self.db, lambda t, x: self.pages.append((t, x))), "origin/develop",
                             clock=lambda: self.now, sleep=sleep,
                             negative_control=no_controls, announcer=self.announcer)
        self.db.clock = lambda: self.now

    def state(self, n: int) -> str:
        t = self.db.ticket(n)
        assert t
        return t.state


@pytest.fixture
def rig(tmp_path: Path) -> Rig:
    return Rig(tmp_path)


def explore_ok(req: StageRequest) -> StageOutcome:
    req.contract.submit_plan(plan_args())
    return accepted(req, "S-explore")


def develop_ok(req: StageRequest) -> StageOutcome:
    commit_change(req)
    req.contract.run_checks({})
    req.contract.submit_change({"summary": "done"})
    return accepted(req, "S-dev")


def develop_with(text: str):  # type: ignore[no-untyped-def]
    def script(req: StageRequest) -> StageOutcome:
        commit_change(req, text)
        req.contract.run_checks({})
        req.contract.submit_change({"summary": "again"})
        return accepted(req, "S-dev")
    return script


def no_controls(*_args: object) -> list[negctl.Control]:
    return []


def review_ok(req: StageRequest) -> StageOutcome:
    req.contract.submit_review({"verdict": "approve"})
    return accepted(req, "S-rev")


async def test_a_ticket_goes_from_label_to_landed(rig: Rig) -> None:
    rig.gh.add_issue(7, "Tidy the docs")
    rig.engine.sync_issues()
    assert rig.state(7) == "queued"
    rig.agent.on("explore", explore_ok)
    rig.agent.on("develop", develop_ok)
    rig.agent.on("review", review_ok)

    t = rig.engine.claimable()
    assert t and t.number == 7
    await rig.engine.drive(7)

    assert rig.state(7) == "landed"
    t = rig.db.ticket(7)
    assert t and t.plan and t.plan["summary"].startswith("Add a line")
    assert [s["stage"] for s in rig.db.stages(7)] == ["explore", "develop", "review"]
    assert rig.db.checks(7), "run_checks results are in the database"
    assert rig.gh.issues[7]["state"] == "closed"
    assert (rig.engine.repo / ".claude" / "worktrees" / "pipe-7").exists() is False


async def test_an_outsider_issue_is_not_taken_without_the_owner_label(rig: Rig) -> None:
    rig.gh.add_issue(8, "Please do this", author="stranger")
    rig.gh.timelines[8] = []
    rig.engine.sync_issues()
    assert rig.db.ticket(8) is None
    assert rig.engine.claimable() is None


async def test_blockers_and_priority_decide_the_claim(rig: Rig) -> None:
    rig.gh.add_issue(1, "first", labels=("pipeline", "p3"))
    rig.gh.add_issue(2, "second", labels=("pipeline", "p0"))
    rig.gh.add_issue(3, "third", labels=("pipeline", "p0"))
    rig.gh.deps[2] = [1]
    rig.engine.sync_issues()
    t = rig.engine.claimable()
    assert t and t.number == 3  # 2 is p0 but blocked by 1; 3 is p0 and free
    rig.db.set_state(3, "landed")
    t = rig.engine.claimable()
    assert t and t.number == 1


async def test_a_landing_stage_takes_a_session_over_the_limit_and_new_work_waits_for_it(rig: Rig) -> None:
    rig.engine.config.max_llm_sessions = 1
    rig.gh.add_issue(1, "running", labels=("pipeline", "p2"))
    rig.gh.add_issue(2, "landing", labels=("pipeline", "p2"))
    rig.gh.add_issue(3, "new", labels=("pipeline", "p2"))
    rig.engine.sync_issues()
    t1, t2, t3 = (rig.db.ticket(n) for n in (1, 2, 3))
    assert t1 and t2 and t3
    rig.db.begin_stage(1, "develop", 1, "sonnet")  # the one allowed session is busy
    assert not rig.engine.llm_room().ok and rig.engine.llm_room(extra=1).ok
    async def sleep(_: float) -> None:
        await asyncio.sleep(0.01)

    rig.engine.sleep = sleep
    new_work = asyncio.create_task(rig.engine._begin_when_room(t3, "develop", 1, "sonnet"))  # pyright: ignore[reportPrivateUsage]
    await asyncio.sleep(0.05)
    assert not new_work.done() and rig.db.get("llm_wait:3"), "no room for new work"
    stage_id = await rig.engine._begin_when_room(t2, "conflict", 1, "sonnet")  # pyright: ignore[reportPrivateUsage]
    assert stage_id and rig.engine.landing_waiting == set(), "the landing stage started at once, one over the limit"
    rig.db.end_stage(1, "accepted", 0.0, "")  # stage rows are 1 (develop) and 2 (conflict): both end, room opens
    rig.db.end_stage(2, "accepted", 0.0, "")
    await asyncio.wait_for(new_work, 2)


async def test_nothing_new_is_claimed_while_a_landing_stage_waits_for_a_session(rig: Rig) -> None:
    rig.gh.add_issue(1, "queued", labels=("pipeline", "p2"))
    rig.engine.sync_issues()
    assert rig.engine.claimable() is not None
    rig.engine.landing_waiting.add(9)
    assert rig.engine.claimable() is None


async def test_the_monitors_max_active_override_is_the_llm_session_limit(rig: Rig) -> None:
    assert rig.engine.max_active() == rig.engine.config.max_llm_sessions
    rig.db.put("max_active", "2")
    assert rig.engine.max_active() == 2
    rig.db.put("max_active", "junk")
    assert rig.engine.max_active() == rig.engine.config.max_llm_sessions  # an unreadable override falls back to the file
    rig.db.put("max_active", "2")
    rig.db.put("limit_llm", "5")  # `starpipe limits` is the more specific override
    assert rig.engine.max_active() == 5
    rig.db.put("limit_llm", None)
    rig.db.put("max_active", None)
    assert rig.engine.max_active() == rig.engine.config.max_llm_sessions


async def test_a_stage_without_a_result_climbs_the_ladder_then_parks(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    await rig.engine.drive(7)
    models = [r.model for r in rig.agent.requests]
    assert models == ["sonnet", "sonnet", "sonnet"]  # the escalation model equals the default today
    assert [r.attempt for r in rig.agent.requests] == [1, 2, 3]
    assert rig.state(7) == "failed"
    assert rig.db.open_alert("ticket-failed:7", "again") is False  # already open


def piped(entries: str) -> str:
    return GOOD_BODY + f"\n## Pipeline\n{entries}\n"


async def test_a_tickets_per_stage_model_and_effort_reach_the_stage_request(rig: Rig) -> None:
    rig.engine.config.model = "sonnet"
    rig.gh.add_issue(7, "t", body=piped("model_explore: haiku · effort_explore: max · effort_develop: low"))
    rig.gh.add_issue(8, "t")
    rig.engine.sync_issues()
    await rig.engine.drive(7)
    await rig.engine.drive(8)
    mine = [r for r in rig.agent.requests if r.ticket == 7]
    other = [r for r in rig.agent.requests if r.ticket == 8]
    assert [(r.model, r.effort) for r in mine[:2]] == [("haiku", "max")] * 2
    assert [(r.model, r.effort) for r in other[:2]] == [("sonnet", "high")] * 2

    # a stage the ticket does not name keeps the default, a hyphenated stage maps to its underscored key
    rig.db.upsert_ticket(7, "t", piped("model_ci_fix: sonnet · effort_ci_fix: xhigh"), OWNER, 2, [])
    assert rig.engine._stage_choice(rig.db.ticket(7), "ci-fix", 1) == ("sonnet", "xhigh")  # type: ignore[arg-type]
    assert rig.engine._stage_choice(rig.db.ticket(7), "conflict", 1) == ("sonnet", "high")  # type: ignore[arg-type]


async def test_attempt_three_escalates_unless_the_ticket_names_a_model(rig: Rig) -> None:
    rig.engine.config.model = "sonnet"
    rig.engine.config.model_escalate = "opus"
    rig.gh.add_issue(7, "t", body=piped("model_develop: haiku"))
    rig.gh.add_issue(8, "t", body=piped("effort_explore: low"))
    rig.engine.sync_issues()
    await rig.engine.drive(7)
    await rig.engine.drive(8)
    assert [r.model for r in rig.agent.requests if r.ticket == 8] == ["sonnet", "sonnet", "opus"]  # explore, escalates
    rig.agent.on("explore", explore_ok)
    rig.agent.on("develop", lambda r: StageOutcome("no-result"), lambda r: StageOutcome("no-result"),
                 lambda r: StageOutcome("no-result"))
    rig.db.set_state(7, "queued")
    await rig.engine.drive(7)
    develops = [r for r in rig.agent.requests if r.ticket == 7 and r.stage == "develop"]
    assert [r.model for r in develops] == ["haiku", "haiku", "haiku"]  # the explicit choice survives attempt 3


async def test_a_disallowed_model_or_unknown_effort_falls_back_and_is_noted(rig: Rig) -> None:
    rig.gh.add_issue(7, "t", body=piped("model_explore: fable · effort_explore: ultra"))
    rig.engine.sync_issues()
    await rig.engine.drive(7)
    assert {(r.model, r.effort) for r in rig.agent.requests} == {(rig.engine.config.model, "high")}
    noted = [e for e in rig.db.events_since() if e["kind"] == "stage-choice-ignored"]
    assert {e["data"]["key"] for e in noted} == {"model_explore", "effort_explore"}
    assert any("fable" in e["data"]["reason"] for e in noted)

    rig.engine.config.allow_fable = True  # fable is honoured once the config allows it
    assert rig.engine._stage_choice(rig.db.ticket(7), "explore", 1)[0] == "fable"  # type: ignore[arg-type]


async def test_a_timeout_resumes_the_same_session(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    rig.agent.on("explore", lambda r: StageOutcome("timeout", session_id="S1"), explore_ok)
    rig.agent.on("develop", lambda r: StageOutcome("no-result"))
    await rig.engine.drive(7)
    explores = [r for r in rig.agent.requests if r.stage == "explore"]
    assert explores[1].resume == "S1"
    assert rig.state(7) == "failed"  # develop never produced a result


async def test_crashes_resume_without_counting_an_attempt(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    rig.agent.on("explore", lambda r: StageOutcome("crash", session_id="S1"),
                 lambda r: StageOutcome("crash", session_id="S1"), explore_ok)
    rig.agent.on("develop", lambda r: StageOutcome("no-result"))
    await rig.engine.drive(7)
    explores = [r for r in rig.agent.requests if r.stage == "explore"]
    assert [r.attempt for r in explores] == [1, 1, 1]
    assert explores[2].resume == "S1"


async def test_a_usage_limit_pauses_without_counting_an_attempt(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    reset = rig.now + 600
    rig.agent.on("explore", lambda r: StageOutcome("usage-limit", session_id="S1", resets_at=reset), explore_ok)
    rig.agent.on("develop", lambda r: StageOutcome("no-result"))
    await rig.engine.drive(7)
    explores = [r for r in rig.agent.requests if r.stage == "explore"]
    assert [r.attempt for r in explores] == [1, 1]
    assert sum(rig.slept) >= 600
    assert rig.db.get("usage_pause_until") is None


async def test_rate_limit_windows_are_recorded(rig: Rig, tmp_path: Path) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    both = {"five_hour": {"utilization": 0.08, "resetsAt": 1793493600, "status": "allowed"},
            "seven_day": {"utilization": 0.25, "resetsAt": 1793984400, "status": "allowed"}}

    def explore(req: StageRequest) -> StageOutcome:
        req.on_usage(both)
        req.on_usage({"five_hour": {"utilization": 0.1, "resetsAt": 1793497200}})  # one window: the other stays
        req.on_usage({"seven_day": {"utilization": "lots", "resetsAt": None}, "five_hour": "x"})  # malformed: ignored
        return explore_ok(req)

    rig.agent.on("explore", explore)
    rig.agent.on("develop", lambda r: StageOutcome("no-result"))
    await rig.engine.drive(7)
    stored = json.loads(rig.db.get("usage_windows") or "null")
    assert stored == {"five_hour": {"utilization": 0.1, "resetsAt": 1793497200},
                      "seven_day": {"utilization": 0.25, "resetsAt": 1793984400}}
    reopened = Database(tmp_path / "state.db")  # it survives a daemon restart
    assert json.loads(reopened.get("usage_windows") or "null") == stored


def _credit_report(**over: Any) -> dict[str, Any]:
    base: dict[str, Any] = {"status": "allowed", "window": "five_hour", "utilization": None, "overage_status": None,
                            "overage_resets_at": None, "overage_disabled_reason": None}
    return {**base, **over}


async def test_credit_support_is_recorded(rig: Rig, tmp_path: Path) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    assert rig.db.get("credit_support") is None, "unknown until a stream reports"

    def explore(req: StageRequest) -> StageOutcome:
        req.on_credits(_credit_report())  # says nothing about credits: still unknown
        assert rig.db.get("credit_support") is None
        req.on_credits(_credit_report(overage_status="allowed"))
        return explore_ok(req)

    rig.agent.on("explore", explore)
    rig.agent.on("develop", lambda r: StageOutcome("no-result"))
    await rig.engine.drive(7)
    assert rig.db.get("credit_support") == "supported"
    assert Database(tmp_path / "state.db").get("credit_support") == "supported"  # survives a restart
    rig.engine._record_credits(_credit_report(status="rejected", overage_status="rejected", overage_disabled_reason="out_of_credits"))  # pyright: ignore[reportPrivateUsage]
    assert rig.db.get("credit_support") == "supported", "exhausted credits are still supported credits"
    rig.db.put("credit_support", None)
    rig.engine._record_credits(_credit_report(overage_status="rejected", overage_disabled_reason="org_level_disabled"))  # pyright: ignore[reportPrivateUsage]
    assert rig.db.get("credit_support") == "none"
    rig.db.put("credit_support", None)
    rig.engine._record_credits(_credit_report(overage_status="something-new"))  # pyright: ignore[reportPrivateUsage]
    assert rig.db.get("credit_support") == "none", "an unrecognised state is treated as no credits"


async def test_credit_use_is_recorded_and_announced(rig: Rig) -> None:
    record = rig.engine._record_credits  # pyright: ignore[reportPrivateUsage]
    record(_credit_report(status="allowed", window="five_hour", overage_status="allowed"))
    assert rig.db.get("credit_use") is None
    record(_credit_report(status="rejected", window="five_hour", overage_status="allowed"))  # base window out, credits carry on
    first = json.loads(rig.db.get("credit_use") or "null")
    assert first["window"] == "five_hour" and first["amount"] is None
    record(_credit_report(status="allowed", window="overage", overage_status="allowed", utilization=0.25))
    second = json.loads(rig.db.get("credit_use") or "null")
    assert second["amount"] == 0.25 and second["since"] == first["since"], "the amount follows; the start stays"
    record(_credit_report(status="allowed_warning", window="overage", overage_status="allowed_warning", utilization=0.9))
    events = [e for e in rig.db.events_since() if e["kind"] == "credits-in-use"]
    assert len(events) == 1, "announced once per start of use"
    assert events[0]["data"]["window"] == "five_hour"
    record(_credit_report(status="allowed", window="five_hour", overage_status="allowed"))  # the base window is back
    assert rig.db.get("credit_use") is None
    record(_credit_report(status="rejected", window="five_hour", overage_status="allowed"))
    assert len([e for e in rig.db.events_since() if e["kind"] == "credits-in-use"]) == 2, "a new start is announced again"
    record(_credit_report(status="rejected", window="overage", overage_status="rejected"))  # credits ran out
    assert rig.db.get("credit_use") is None and rig.db.get("credit_exhausted") == "1"


async def test_no_credits_pause_resumes_at_the_reset(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    reset = rig.now + 900

    def limited(req: StageRequest) -> StageOutcome:
        req.on_credits(_credit_report(status="rejected", window="seven_day", overage_status="rejected"))
        assert rig.db.get("credit_support") == "none"
        return StageOutcome("usage-limit", session_id="S1", resets_at=reset, window="seven_day")

    paused: list[tuple[str | None, str | None]] = []

    def resumed(req: StageRequest) -> StageOutcome:
        paused.append((rig.db.get("usage_pause_until"), rig.db.get("usage_pause_window")))
        return explore_ok(req)

    rig.agent.on("explore", limited, resumed)
    rig.agent.on("develop", lambda r: StageOutcome("no-result"))
    # the pause is stored, with its window, while the engine waits
    original_sleep = rig.engine.sleep
    seen: list[tuple[str | None, str | None]] = []

    async def watching(seconds: float) -> None:
        seen.append((rig.db.get("usage_pause_until"), rig.db.get("usage_pause_window")))
        await original_sleep(seconds)

    rig.engine.sleep = watching
    await rig.engine.drive(7)
    explores = [r for r in rig.agent.requests if r.stage == "explore"]
    assert [r.attempt for r in explores] == [1, 1], "no attempt counted"
    assert explores[1].resume == "S1"
    assert seen and all(s == (str(reset), "seven_day") for s in seen)
    assert sum(rig.slept) >= 900
    assert rig.db.get("usage_pause_until") is None and rig.db.get("usage_pause_window") is None
    pauses = [e for e in rig.db.events_since() if e["kind"] == "usage-pause"]
    assert [e["data"]["window"] for e in pauses] == ["seven_day"]


async def test_credits_keep_stages_running_until_exhausted(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    reset = rig.now + 900

    def credits_carry_on(req: StageRequest) -> StageOutcome:
        req.on_credits(_credit_report(status="rejected", window="five_hour", overage_status="allowed"))
        return StageOutcome("usage-limit", session_id="S1", resets_at=reset, window="five_hour")

    def credits_run_out(req: StageRequest) -> StageOutcome:
        req.on_credits(_credit_report(status="rejected", window="overage", overage_status="rejected"))
        return StageOutcome("usage-limit", session_id="S1", resets_at=reset, window="overage")

    rig.agent.on("explore", credits_carry_on, credits_run_out, explore_ok)
    rig.agent.on("develop", lambda r: StageOutcome("no-result"))
    await rig.engine.drive(7)
    explores = [r for r in rig.agent.requests if r.stage == "explore"]
    assert [r.attempt for r in explores] == [1, 1, 1], "neither limit counts an attempt"
    pauses = [e for e in rig.db.events_since() if e["kind"] == "usage-pause"]
    assert [e["data"]["window"] for e in pauses] == ["overage"], "only the exhausted credits paused the stages"
    assert sum(rig.slept) >= 900
    assert rig.db.get("credit_exhausted") is None, "cleared when the credit pause ended"


async def test_a_question_the_resolver_can_answer_resumes_the_session(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()

    def ask(req: StageRequest) -> StageOutcome:
        req.contract.ask_question({"question": "tabs or spaces?", "why_unanswerable": "not in ticket"})
        return accepted(req, "S-explore")

    def resolve(req: StageRequest) -> StageOutcome:
        req.contract.submit_resolution({"kind": "answer", "text": "spaces", "reasons": ["CLAUDE.md"]})
        return accepted(req, "S-res")

    rig.agent.on("explore", ask, explore_ok)
    rig.agent.on("resolve", resolve)
    rig.agent.on("develop", lambda r: StageOutcome("no-result"))
    await rig.engine.drive(7)
    explores = [r for r in rig.agent.requests if r.stage == "explore"]
    assert explores[1].resume == "S-explore"
    assert "spaces" in explores[1].prompt
    assert any("Answered by resolver" in c["body"] for c in rig.gh.comments(7))
    assert rig.db.stages(7)[-1]["stage"] == "develop"


async def test_an_escalated_question_waits_for_an_owner_comment(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()

    def ask(req: StageRequest) -> StageOutcome:
        req.contract.ask_question({"question": "ship it?", "why_unanswerable": "product call"})
        return accepted(req, "S-explore")

    def escalate(req: StageRequest) -> StageOutcome:
        req.contract.submit_resolution({"kind": "escalate", "text": "product decision"})
        return accepted(req, "S-res")

    rig.agent.on("explore", ask, explore_ok)
    rig.agent.on("resolve", escalate)
    rig.agent.on("develop", lambda r: StageOutcome("no-result"))
    await rig.engine.drive(7)
    assert rig.state(7) == "needs-input"
    assert rig.gh.state_label(7) == "pipe:needs-input"
    assert ("star pipeline: needs-input", "#7 t: waiting on the owner: ship it?") in rig.pages

    rig.gh.say(7, "stranger", "yes ship")
    rig.engine.sync_issues()
    assert rig.state(7) == "needs-input"  # an outsider's comment is not an answer
    rig.gh.say(7, OWNER, "yes, ship it")
    rig.engine.sync_issues()
    assert rig.state(7) == "exploring"
    await rig.engine.drive(7)
    explores = [r for r in rig.agent.requests if r.stage == "explore"]
    assert explores[1].resume == "S-explore" and "yes, ship it" in explores[1].prompt


async def test_the_same_question_goes_straight_to_the_owner(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    rig.db.add_question(7, "explore", "ship it?", {})
    rig.db.answer_question(1, "no", "owner")
    rig.db.put("delivered:1", "1")

    def ask(req: StageRequest) -> StageOutcome:
        req.contract.ask_question({"question": "ship it?", "why_unanswerable": "again"})
        return accepted(req)

    rig.agent.on("explore", ask)
    await rig.engine.drive(7)
    assert rig.state(7) == "needs-input"
    assert not [r for r in rig.agent.requests if r.stage == "resolve"]


async def test_review_changes_send_it_back_through_develop_and_verify(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()

    def changes(req: StageRequest) -> StageOutcome:
        req.contract.submit_review({"verdict": "changes", "findings": [
            {"file": "docs/a.md", "line": 1, "severity": "major", "issue": "wrong word"}]})
        return accepted(req, "S-rev1")

    def develop_again(req: StageRequest) -> StageOutcome:
        commit_change(req, "three\n")
        req.contract.run_checks({})
        req.contract.submit_change({"summary": "fixed"})
        return accepted(req, "S-dev")

    rig.agent.on("explore", explore_ok)
    rig.agent.on("develop", develop_ok, develop_again)
    rig.agent.on("review", changes, review_ok)
    await rig.engine.drive(7)
    assert rig.state(7) == "landed"
    develops = [r for r in rig.agent.requests if r.stage == "develop"]
    assert "wrong word" in develops[1].prompt
    reviews = [r for r in rig.agent.requests if r.stage == "review"]
    assert all(r.resume is None for r in reviews), "REVIEW is a fresh session each time"


async def test_review_parks_after_two_rounds_of_changes(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()

    def changes(req: StageRequest) -> StageOutcome:
        req.contract.submit_review({"verdict": "changes", "findings": [
            {"file": "x", "line": 1, "severity": "major", "issue": "no"}]})
        return accepted(req)

    rig.agent.on("explore", explore_ok)
    rig.agent.on("develop", develop_ok, develop_with("a\n"), develop_with("b\n"))
    rig.agent.on("review", changes, changes, changes)
    await rig.engine.drive(7)
    assert rig.state(7) == "failed"
    assert len(rig.db.stages(7, "review")) == 3


async def test_a_red_verification_runs_fix_then_parks_after_two(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    rig.agent.on("explore", explore_ok)
    rig.agent.on("develop", develop_ok)
    calls = {"n": 0}
    real = rig.engine.check_runner

    def flaky(worktree: Path, base: str):  # type: ignore[no-untyped-def]
        results = real(worktree, base)
        calls["n"] += 1
        if calls["n"] > 1 and results:  # DEVELOP's own run is green; the daemon's runs are not
            results[0].status = "fail"
            results[0].detail = "boom"
        return results

    rig.engine.check_runner = flaky
    rig.agent.on("fix", lambda r: StageOutcome("no-result"), lambda r: StageOutcome("no-result"))
    await rig.engine.drive(7)
    assert rig.state(7) in ("failed",)


async def test_a_non_discriminating_test_goes_back_to_develop_once(rig: Rig) -> None:
    rig.gh.add_issue(7, "Fix crash")
    rig.engine.sync_issues()
    rig.agent.on("explore", lambda r: (r.contract.submit_plan(plan_args(
        tests={"new": [{"target": "T", "name": "docs", "kind": "unit", "shows": "A1", "fails_before_fix": True}]})), accepted(r))[1])
    rig.agent.on("develop", develop_ok)
    def passes_on_base(*_args: object) -> list[negctl.Control]:
        return [negctl.Control("docs", "passes-on-base")]

    rig.engine.negative_control = passes_on_base
    await rig.engine.drive(7)
    # verification failed once with 'does not discriminate'; a FIX stage was asked, it produced nothing, so it parked
    fixes = [r for r in rig.agent.requests if r.stage == "fix"]
    assert fixes and "does not discriminate" in fixes[0].prompt


async def test_close_by_explore_closes_a_pipeline_filed_ticket_at_once(rig: Rig) -> None:
    rig.gh.add_issue(9, "dup", author="stranger")
    rig.gh.timelines[9] = [{"event": "labeled", "label": {"name": "pipeline"}, "actor": {"login": OWNER}}]
    rig.engine.sync_issues()
    head = rig.engine.repo
    sha = __import__("subprocess").run(["git", "-C", str(head), "rev-parse", "origin/develop"], capture_output=True,
                                        text=True).stdout.strip()

    def close(req: StageRequest) -> StageOutcome:
        req.contract.owner_filed = False
        assert "accepted" in req.contract.close_ticket({"reason": "already-done", "evidence": [sha]})
        return accepted(req)

    rig.agent.on("explore", close)
    await rig.engine.drive(9)
    assert rig.state(9) == "closed" and rig.gh.issues[9]["state"] == "closed"


async def test_close_of_an_owner_ticket_waits_for_a_veto_window(rig: Rig) -> None:
    rig.gh.add_issue(9, "mine")
    rig.engine.sync_issues()
    sha = __import__("subprocess").run(["git", "-C", str(rig.engine.repo), "rev-parse", "origin/develop"],
                                       capture_output=True, text=True).stdout.strip()

    def close(req: StageRequest) -> StageOutcome:
        assert "accepted" in req.contract.close_ticket({"reason": "already-done", "evidence": [sha]})
        return accepted(req)

    rig.agent.on("explore", close)
    await rig.engine.drive(9)
    assert rig.state(9) == "paused" and rig.gh.issues[9]["state"] == "open"
    rig.engine.close_due()
    assert rig.state(9) == "paused"
    rig.now += 25 * 3600
    rig.engine.close_due()
    assert rig.state(9) == "closed" and rig.gh.issues[9]["state"] == "closed"


async def test_losing_the_pipeline_label_cancels_the_ticket(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    rig.gh.issues[7]["labels"] = []
    rig.engine.sync_issues()
    assert rig.state(7) == "cancelled"


def test_the_fence_denies_what_the_plan_says_it_denies(tmp_path: Path) -> None:
    wt = tmp_path / "wt"
    wt.mkdir()
    fence = guards.Fence(wt, tmp_path / "t", tmp_path / "b", branch="pipe/1-x")

    def bash(cmd: str) -> str:
        return guards.decide("Bash", {"command": cmd}, fence, shim="/s/starpipe").kind

    assert guards.decide("Write", {"file_path": str(wt / "a.txt")}, fence).kind == "allow"
    assert guards.decide("Write", {"file_path": "/etc/passwd"}, fence).kind == "deny"
    assert guards.decide("Write", {"file_path": str(wt / ".." / "x")}, fence).kind == "deny"
    assert guards.decide("Write", {"file_path": "/Users/x/.claude/projects/p/memory/a.md"}, fence).kind == "deny"
    assert guards.decide("Monitor", {}, fence).kind == "deny"
    assert bash("echo hi > /tmp/../etc/x") == "deny"
    assert bash("rm -rf /Users/brian/git/other") == "deny"
    assert bash("echo hi > out.txt") == "allow"
    assert bash("sleep 100 &") == "deny"
    assert bash("nohup swift build") == "deny"
    assert bash("git push origin HEAD") == "deny"
    assert bash("git checkout develop") == "deny"
    assert bash("git branch -f develop HEAD") == "deny"
    assert bash("git status && git commit -m x") == "allow"
    assert bash("swift test --filter X") == "rewrite"
    assert guards.decide("Bash", {"command": "swift test"}, fence, shim="/s/starpipe").command.startswith("/s/starpipe heavy")
    assert bash("/s/starpipe heavy -- swift test") == "allow"
    ro = guards.Fence(wt, tmp_path / "t", tmp_path / "b", read_only=True)
    assert guards.decide("Edit", {"file_path": str(wt / "a")}, ro).kind == "deny"
    assert guards.decide("Bash", {"command": "echo x > a.txt"}, ro).kind == "deny"
    assert guards.decide("Bash", {"command": "git diff origin/develop...HEAD"}, ro).kind == "allow"


async def test_verification_does_not_block_the_event_loop(rig: Rig) -> None:
    """The checks wait for the heavy lock and run for hours. Run on the event loop they froze the whole daemon (its API, the monitor,
    every other ticket); found when a verifying ticket made `starpipe status` report the daemon down."""
    import asyncio
    import threading

    from starpipe.checks import ledger

    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    rig.engine.claim(rig.db.tickets()[0])
    rig.db.set_state(7, "verifying")
    loop_ran = threading.Event()
    waited_out: list[bool] = []

    def blocking_runner(worktree: Path, base: str) -> list[ledger.Result]:
        waited_out.append(not loop_ran.wait(5))  # True would mean the event loop never got to run
        return green_runner(worktree, base)

    async def ticker() -> None:
        await asyncio.sleep(0.2)
        loop_ran.set()

    rig.engine.check_runner = blocking_runner
    ticket = rig.db.ticket(7)
    assert ticket
    await asyncio.gather(rig.engine._verify(ticket), ticker())  # pyright: ignore[reportPrivateUsage]
    assert waited_out == [False]
    assert rig.state(7) == "review"


async def test_opus_in_a_ticket_body_is_ignored_unless_the_owner_asked_for_it(rig: Rig) -> None:
    """Found live: tickets filed by agent sessions carried `model_develop: opus` copied from the skill's example, and ran on opus."""
    rig.gh.add_issue(7, "t", body=piped("model_develop: opus · model_review: haiku"))
    rig.engine.sync_issues()
    t = rig.db.ticket(7)
    assert t is not None
    assert rig.engine._stage_choice(t, "develop", 1) == ("sonnet", "high"), "opus in the body does nothing"  # pyright: ignore[reportPrivateUsage]
    assert rig.engine._stage_choice(t, "review", 1) == ("haiku", "high"), "other models are still honoured"  # pyright: ignore[reportPrivateUsage]
    assert any(e["kind"] == "stage-choice-ignored" and e["data"]["value"] == "opus" for e in rig.db.events_since())

    rig.db.put("opus_ok:7", "1")  # `starpipe allow-opus 7`, or picking opus in the monitor
    assert rig.engine._stage_choice(t, "develop", 1) == ("opus", "high")  # pyright: ignore[reportPrivateUsage]
    rig.db.put("opus_ok:7", None)
    rig.engine.config.allow_opus = True
    assert rig.engine._stage_choice(t, "develop", 1) == ("opus", "high")  # pyright: ignore[reportPrivateUsage]


def test_the_defaults_are_sonnet_everywhere() -> None:
    from starpipe.config import Config

    cfg = Config()
    assert (cfg.model, cfg.model_escalate, cfg.allow_opus) == ("sonnet", "sonnet", False)


async def test_needs_input_announces_with_the_attention_voice(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    rig.db.add_question(7, "explore", "ship it?", {})
    rig.db.answer_question(1, "no", "owner")
    rig.db.put("delivered:1", "1")

    def ask(req: StageRequest) -> StageOutcome:
        req.contract.ask_question({"question": "ship it?", "why_unanswerable": "again"})
        return accepted(req)

    rig.agent.on("explore", ask)
    await rig.engine.drive(7)
    assert rig.state(7) == "needs-input"
    assert rig.announcer.calls == [("attention", 7)]
    from starpipe.announce import CLIPS

    sound, voice, sentence = CLIPS["attention"]
    assert sentence.format(n=7) == "Star issue number 7 needs your attention"
    assert (sound, voice) != CLIPS["landed"][:2]


async def test_announcer_failure_does_not_fail_the_stage(rig: Rig) -> None:
    rig.announcer.fail = True
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    t = rig.db.ticket(7)
    assert t
    result = rig.engine.park(t, "needs a human", state="needs-input")
    assert not result.ok and rig.state(7) == "needs-input" and rig.announcer.calls == [("attention", 7)]
    rig.engine._to_state(7, "landed")  # pyright: ignore[reportPrivateUsage]
    assert rig.state(7) == "landed"


def test_the_real_announcer_swallows_missing_binaries_and_never_blocks(monkeypatch: pytest.MonkeyPatch) -> None:
    from starpipe import announce

    monkeypatch.setattr(announce, "AFPLAY", "/nonexistent/afplay")
    monkeypatch.setattr(announce, "SAY", "/nonexistent/say")
    announce.SayAnnouncer.play("landed", 1)  # no exception
    a = announce.SayAnnouncer()
    a.announce("attention", 2)  # returns at once; the worker thread swallows the failure


PLAN_TICKET = """## Goal
Tidy the docs.

## Context
docs/a.md.

## Acceptance criteria
- A1: the docs file has a second line — check: review: docs/a.md

## Tests
none: docs only

## Out of scope
Everything else.

## Plan
summary: Add a line to the docs file.
parity: neither
localization: no
- approach: edit docs/a.md
- file: docs/a.md:1 — the one line there
- risk: none

## Pipeline
gherkin: no
"""


async def test_owner_ticket_with_a_valid_plan_skips_explore(rig: Rig) -> None:
    rig.gh.add_issue(7, "Tidy the docs", PLAN_TICKET + filed_by("interactive"))
    rig.engine.sync_issues()
    t = rig.engine.claim(rig.db.ticket(7))  # type: ignore[arg-type]
    assert t.state == "developing"
    assert t.plan and t.plan["summary"] == "Add a line to the docs file." and t.plan["findings"][0]["line"] == 1
    assert json.loads((worktrees.ticket_dir(7) / "plan.json").read_text()) == t.plan
    assert [e["kind"] for e in rig.db.events_since() if e["ticket"] == 7 and e["kind"].startswith(("plan", "ticket-plan"))] \
        == ["plan-from-ticket"]
    rig.agent.on("develop", develop_ok)
    rig.agent.on("review", review_ok)
    await rig.engine.drive(7)
    assert rig.state(7) == "landed"
    assert not [r for r in rig.agent.requests if r.stage == "explore"]


async def test_an_invalid_ticket_plan_falls_back_to_explore_with_reasons(rig: Rig) -> None:
    past_eof = PLAN_TICKET.replace("docs/a.md:1 —", "docs/a.md:99 —").replace(
        "none: docs only", "unit: pipeline/tests/test_x.py test_x — shows: A1")
    rig.gh.add_issue(7, "Fix the docs crash", past_eof + filed_by("interactive"))
    rig.engine.sync_issues()
    rig.agent.on("explore", explore_ok)
    rig.agent.on("develop", develop_ok)
    rig.agent.on("review", review_ok)
    rig.engine.claim(rig.db.ticket(7))  # type: ignore[arg-type]
    assert rig.state(7) == "exploring" and not rig.db.ticket(7).plan  # type: ignore[union-attr]
    rejected = [e for e in rig.db.events_since() if e["kind"] == "ticket-plan-rejected"]
    assert len(rejected) == 1 and rejected[0]["ticket"] == 7
    reasons = rejected[0]["data"]["reasons"]
    assert any("docs/a.md has fewer than 99 lines" in r for r in reasons)
    assert any("fails_before_fix" in r for r in reasons)
    await rig.engine.drive(7)
    (req,) = [r for r in rig.agent.requests if r.stage == "explore"]
    assert "was rejected" in req.prompt and all(r in req.prompt for r in reasons)
    assert rig.state(7) == "landed"

    rig.gh.add_issue(8, "Tidy the docs again", PLAN_TICKET.replace("## Plan", "## Plan\nbogus: 1")
                     + filed_by("nightly-review"))
    rig.engine.sync_issues()
    rig.engine.claim(rig.db.ticket(8))  # type: ignore[arg-type]
    assert rig.state(8) == "exploring" and "unknown key" in (rig.db.get("plan_rejected:8") or "")


async def test_a_plan_from_an_agent_filed_ticket_skips_explore(rig: Rig) -> None:
    rig.gh.add_issue(7, "Tidy the docs", PLAN_TICKET + filed_by("nightly-review"))
    rig.engine.sync_issues()
    t = rig.engine.claim(rig.db.ticket(7))  # type: ignore[arg-type]
    assert t.state == "developing" and t.plan and t.plan["summary"] == "Add a line to the docs file."
    assert [e["kind"] for e in rig.db.events_since() if e["ticket"] == 7 and e["kind"].startswith(("plan", "ticket-plan"))] \
        == ["plan-from-ticket"]
    rig.agent.on("develop", develop_ok)
    rig.agent.on("review", review_ok)
    await rig.engine.drive(7)
    assert rig.state(7) == "landed"
    assert not [r for r in rig.agent.requests if r.stage == "explore"]


async def test_a_pipeline_filed_ticket_ignores_its_plan(rig: Rig) -> None:
    mine = PLAN_TICKET + filed_by("interactive")
    rig.gh.add_issue(1, "labelled by the pipeline", mine, labels=("pipeline", "pipe:filed-by-pipeline"))
    rig.gh.add_issue(2, "filed by a stranger", mine, author="stranger")
    rig.engine.sync_issues()
    for n in (1, 2):
        assert tickets_ok(rig, n)


def tickets_ok(rig: Rig, n: int) -> bool:
    assert rig.db.ticket(n), f"#{n} was not taken up"
    t = rig.engine.claim(rig.db.ticket(n))  # type: ignore[arg-type]
    assert t.state == "exploring" and t.plan is None, f"#{n} skipped EXPLORE"
    assert rig.db.get(f"plan_rejected:{n}") is None
    return True


# a restarted ticket takes in develop first -------------------------------------------------------------------------
GIT_AS_T = ("git", "-c", "user.email=t@t", "-c", "user.name=t")


def stopped_ticket(rig: Rig, file: str = "mine.md", text: str = "mine\n") -> Path:
    """Ticket 7 stopped in `developing` with one commit on a branch cut from the develop of its time."""
    rig.gh.add_issue(7, "Tidy the docs")
    rig.engine.sync_issues()
    t = rig.engine.claim(rig.db.ticket(7))  # type: ignore[arg-type]
    wt = Path(t.worktree or "")
    (wt / "docs").mkdir(exist_ok=True)
    (wt / "docs" / file).write_text(text)
    sh(wt, "git", "add", "-A")
    sh(wt, *GIT_AS_T, "commit", "-q", "-m", f"change {file}")
    rig.db.set_fields(7, plan_json=json.dumps({"summary": "A planned change.", "acceptance": [{"id": "A1", "check": "review: x"}],
                                               "tests": {"none_reason": "docs"}}))
    rig.db.set_state(7, "developing")
    return wt


def develop_moves(rig: Rig, file: str, text: str) -> None:
    """Another ticket lands `docs/<file>` on origin's develop."""
    clone = rig.engine.repo.parent / "dev-clone"
    if not clone.exists():
        sh(clone.parent, "git", "clone", "-q", str(rig.gh.origin), str(clone))
        sh(clone, "git", "checkout", "-q", "develop")
    sh(clone, "git", "pull", "-q", "origin", "develop")
    (clone / "docs").mkdir(exist_ok=True)
    (clone / "docs" / file).write_text(text)
    sh(clone, "git", "add", "-A")
    sh(clone, *GIT_AS_T, "commit", "-q", "-m", f"develop: {file}")
    sh(clone, "git", "push", "-q", "origin", "develop")


def behind(wt: Path) -> bool:
    return not gitutil.is_ancestor(wt, "origin/develop", "HEAD")


def resolver(keep: str):  # type: ignore[no-untyped-def]
    """A conflict stage that writes `keep` over docs/shared.md, commits the merge and submits."""
    def script(req: StageRequest) -> StageOutcome:
        wt = req.contract.worktree
        assert "docs/shared.md" in req.prompt and "Conflicts merging origin/develop" in req.prompt
        (wt / "docs" / "shared.md").write_text(keep)
        sh(wt, "git", "add", "-A")
        sh(wt, *GIT_AS_T, "commit", "-q", "--no-edit")
        req.contract.run_checks({})
        req.contract.submit_change({"summary": "resolved"})
        return accepted(req, "S-conflict")
    return script


async def test_a_retried_stale_branch_merges_develop_before_its_stage(rig: Rig) -> None:
    stopped_ticket(rig)
    develop_moves(rig, "other.md", "theirs\n")
    rig.db.put("catch_up:7", "1")
    seen: list[tuple[bool, str, bool]] = []

    def develop(req: StageRequest) -> StageOutcome:
        d = req.contract.worktree / "docs"
        seen.append((behind(req.contract.worktree), req.prompt, (d / "other.md").read_text() == "theirs\n" and (d / "mine.md").exists()))
        req.contract.run_checks({})
        req.contract.submit_change({"summary": "done"})
        return accepted(req, "S-dev")

    rig.agent.on("develop", develop)
    rig.agent.on("review", review_ok)
    await rig.engine.drive(7)
    assert seen and seen[0][0] is False, "develop is in the branch when the stage starts"
    assert "was merged into this branch" in seen[0][1] and "1 commit(s)" in seen[0][1]
    assert seen[0][2], "develop's file and the ticket's own commit are both in the tree"
    assert rig.db.get("catch_up:7") is None
    assert [e["data"]["commits"] for e in rig.db.events_since() if e["kind"] == "caught-up"] == [1]


async def test_a_retried_branch_with_conflicts_goes_through_the_conflict_stage(rig: Rig) -> None:
    stopped_ticket(rig, "shared.md", "mine\n")
    develop_moves(rig, "shared.md", "develop's line\n")
    rig.db.put("catch_up:7", "1")
    behind_at_develop: list[bool] = []
    waiting: list[set[int]] = []
    inner = resolver("develop's line\nmine\n")

    def resolve(req: StageRequest) -> StageOutcome:
        waiting.append(set(rig.engine.landing_waiting))
        return inner(req)

    def develop(req: StageRequest) -> StageOutcome:
        behind_at_develop.append(behind(req.contract.worktree))
        return develop_ok(req)

    rig.agent.on("conflict", resolve)
    rig.agent.on("develop", develop)
    rig.agent.on("review", review_ok)
    await rig.engine.drive(7)
    stages = [s["stage"] for s in rig.db.stages(7)]
    assert stages[0] == "conflict" and "develop" in stages
    assert waiting == [set()], "the ticket is not landing: its conflict stage does not take landing priority"
    assert behind_at_develop == [False], "the resumed stage continues on the merged branch"


async def test_a_dropped_develop_line_parks_a_retried_branch(rig: Rig) -> None:
    stopped_ticket(rig, "shared.md", "mine\n")
    develop_moves(rig, "shared.md", "develop's line\n")
    rig.db.put("catch_up:7", "1")
    rig.agent.on("conflict", resolver("mine\n"))
    await rig.engine.drive(7)
    t = rig.db.ticket(7)
    assert t and t.state == "failed" and "dropped 1 landed line" in (t.park_reason or "")
    assert [s["stage"] for s in rig.db.stages(7)] == ["conflict"]


async def test_a_dirty_worktree_is_not_caught_up(rig: Rig) -> None:
    wt = stopped_ticket(rig)
    develop_moves(rig, "other.md", "theirs\n")
    (wt / "docs" / "mine.md").write_text("half an edit\n")  # a stage was interrupted mid-edit
    rig.db.put("catch_up:7", "1")
    ran: list[bool] = []

    def develop(req: StageRequest) -> StageOutcome:
        ran.append(behind(req.contract.worktree))
        sh(req.contract.worktree, "git", "add", "-A")
        sh(req.contract.worktree, *GIT_AS_T, "commit", "-q", "-m", "finish")
        req.contract.run_checks({})
        req.contract.submit_change({"summary": "done"})
        return accepted(req, "S-dev")

    rig.agent.on("develop", develop)
    rig.agent.on("review", review_ok)
    await rig.engine.drive(7)
    assert ran == [True], "the stage ran on the old base"
    skipped = [e for e in rig.db.events_since() if e["kind"] == "catch-up-skipped"]
    assert len(skipped) == 1 and "uncommitted" in skipped[0]["data"]["reason"]
    assert not [e for e in rig.db.events_since() if e["kind"] == "caught-up"]
