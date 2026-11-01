from __future__ import annotations

import time
from pathlib import Path

import pytest

from starpipe import guards, negctl
from starpipe.agent import StageOutcome, StageRequest
from starpipe.config import Config
from starpipe.db import Database
from starpipe.engine import Engine
from starpipe.notify import Notifier

from .fakes import (
    GOOD_BODY,
    OWNER,
    FakeAgent,
    FakeGitHub,
    accepted,
    commit_change,
    green_runner,
    make_repo,
    plan_args,
)


class Rig:
    def __init__(self, tmp: Path) -> None:
        self.db = Database(tmp / "state.db")
        self.gh = FakeGitHub(origin=tmp / "origin.git")
        self.agent = FakeAgent()
        self.pages: list[tuple[str, str]] = []
        self.slept: list[float] = []
        self.now = time.time()

        async def sleep(s: float) -> None:
            self.slept.append(s)
            self.now += s

        self.engine = Engine(Config(remote="origin"), self.db, self.gh, self.agent, make_repo(tmp), green_runner,
                             Notifier(self.db, lambda t, x: self.pages.append((t, x))), "origin/develop",
                             clock=lambda: self.now, sleep=sleep,
                             negative_control=no_controls)
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


async def test_the_active_cap_holds_new_claims(rig: Rig) -> None:
    for n in (1, 2, 3):
        rig.gh.add_issue(n, f"t{n}")
    rig.engine.sync_issues()
    rig.db.set_state(1, "developing")
    rig.db.set_state(2, "exploring")
    assert rig.engine.claimable() is None


async def test_the_db_max_active_override_decides_claims(rig: Rig) -> None:
    for n in (1, 2, 3):
        rig.gh.add_issue(n, f"t{n}")
    rig.engine.sync_issues()
    rig.db.set_state(1, "developing")
    rig.db.set_state(2, "exploring")
    assert rig.engine.max_active() == 2 and rig.engine.claimable() is None  # config.toml's default
    rig.db.put("max_active", "3")
    assert rig.engine.max_active() == 3
    t = rig.engine.claimable()
    assert t and t.number == 3
    rig.db.put("max_active", "1")  # lowering it stops new claims; the running tickets stay as they are
    assert rig.engine.claimable() is None and rig.state(1) == "developing" and rig.state(2) == "exploring"
    rig.db.put("max_active", "junk")
    assert rig.engine.max_active() == 2  # an unreadable override falls back to the file
    rig.db.put("max_active", None)
    assert rig.engine.max_active() == 2


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
