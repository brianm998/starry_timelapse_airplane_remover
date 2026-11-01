"""The ticket state machine (plan §7): intake from GitHub, CLAIM, and the model/script stages up to "ready to publish".

PUBLISH, CI and LAND are Phase 4. Everything outside the repo is injected (GitHub, agent, check runner, clock, sleep),
so the engine runs under fakes in tests.
"""

from __future__ import annotations

import asyncio
import json
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from . import gitutil, guards, load, negctl, ship, tickets, trust, worktrees
from .agent import READ_ONLY_STAGES, AgentRunner, StageOutcome, StageRequest
from .checks import impact, ledger
from .config import Config, home
from .contracts import CheckRunner, Contract
from .db import ACTIVE_STATES, Database, Ticket
from .github import GitHub, GitHubError
from .notify import Notifier
from .tickets import PROPOSED, filed_by

BUDGET_S = {"explore": 45 * 60, "develop": 4 * 3600, "fix": 90 * 60, "review": 45 * 60, "resolve": 20 * 60,
            "ci-fix": 90 * 60, "conflict": 60 * 60}
STAGE_STATE = {"explore": "exploring", "develop": "developing", "fix": "verifying", "review": "review",
               "ci-fix": "ci", "conflict": "landing"}
RETRY_STATE = {**STAGE_STATE, "publish": "ready", "ci": "ci", "land": "landing"}  # what `starpipe retry <n> <stage>` re-enters
MAX_FIX_CYCLES, MAX_REVIEW_ROUNDS, MAX_CRASH_RESUMES = 2, 2, 3
PROMPTS = Path(__file__).resolve().parents[2] / "prompts"
PRIORITY = {"p0": 0, "p1": 1, "p2": 2, "p3": 3}

Sleep = Callable[[float], Awaitable[None]]


def prompt_text(name: str) -> str:
    return (PROMPTS / f"{name}.md").read_text()


@dataclass
class StageResult:
    ok: bool
    kind: str = ""
    value: Any = None
    reason: str = ""


@dataclass
class Engine:
    config: Config
    db: Database
    gh: GitHub
    agent: AgentRunner
    repo: Path
    check_runner: CheckRunner
    notifier: Notifier
    base_ref: str = "origin/develop"
    clock: Callable[[], float] = time.time
    sleep: Sleep = asyncio.sleep
    negative_control: Callable[[Path, str, list[str]], list[negctl.Control]] = negctl.run
    shim: str = ""
    parked: set[int] = field(default_factory=lambda: set[int]())
    cpu: Callable[[], float] = lambda: 0.0  # the rolling CPU average; the daemon injects its meter
    llm_lock: asyncio.Lock = field(default_factory=asyncio.Lock)  # check-room-then-start is one step
    issue_memo: dict[int, tuple[str, bool, list[int]]] = field(default_factory=lambda: dict[int, tuple[str, bool, list[int]]]())
    land_lock: asyncio.Lock = field(default_factory=asyncio.Lock)  # LAND is serialized (§10.1)
    publish_lock: asyncio.Lock = field(default_factory=asyncio.Lock)  # check-room-then-publish is one step

    # intake --------------------------------------------------------------------------------------------------------
    def sync_issues(self) -> None:
        """Pull approved issues in, cancel the ones that lost approval, and collect owner answers."""
        issues = [i for i in self.gh.paged("issues?state=open&labels=pipeline&per_page=100") if "pull_request" not in i]
        seen: set[int] = set()
        for issue in issues:
            n = int(issue["number"])
            stamp = str(issue.get("updated_at") or "")
            memo = self.issue_memo.get(n)
            if stamp and memo and memo[0] == stamp:  # nothing changed on the issue since: no timeline or dependency calls
                allowed, blockers = memo[1], memo[2]
            else:
                allowed = trust.may_run(issue, self.gh.timeline(n), self.config.owner)
                blockers = self.gh.blocked_by(n) if allowed else []
                self.issue_memo[n] = (stamp, allowed, blockers)
            if not allowed:
                continue
            seen.add(n)
            labels = {lab["name"] for lab in issue.get("labels", [])}
            if "pipe:filed-by-pipeline" in labels:
                self.db.put(f"auto:{n}", "1")  # filed by the pipeline with the owner's token: not the owner's own ticket
            prio = min((PRIORITY[lab] for lab in labels if lab in PRIORITY), default=2)
            if self.db.upsert_ticket(n, issue["title"], issue.get("body") or "", issue["user"]["login"], prio, blockers):
                self._label(n, "queued")
        for t in self.db.tickets(("queued", *ACTIVE_STATES, "needs-input", "paused", "ready")):
            if t.number not in seen:
                self.db.set_state(t.number, "cancelled", "issue closed or lost its pipeline label")
                self.db.intervention(t.number, "cancel", t.state)
        for t in self.db.tickets(("needs-input",)):
            self._collect_answer(t)

    def _collect_answer(self, t: Ticket) -> None:
        q = self.db.open_question(t.number)
        if q is None or q["comment_id"] is None:
            return
        answers = trust.accepted_answers(self.gh.comments(t.number), int(q["comment_id"]), self.config.owner)
        if answers:
            self.db.answer_question(q["id"], answers[-1]["body"], "owner")
            self.db.intervention(t.number, "answer", q["stage"])
            self.notifier.clear("needs-input", t.number)
            self.parked.discard(t.number)
            self._to_state(t.number, STAGE_STATE.get(q["stage"], "exploring"))

    def _label(self, n: int, state: str) -> None:
        try:
            self.gh.set_state_label(n, {"ready": "ci", "cancelled": "failed", "closing": "review"}.get(state, state))
        except GitHubError:
            pass  # the database decides; the label is rewritten on the next transition

    def _to_state(self, n: int, state: str, reason: str | None = None) -> None:
        self.db.set_state(n, state, reason)
        self._label(n, state)

    def park(self, t: Ticket, reason: str, state: str = "failed") -> StageResult:
        self._to_state(t.number, state, reason)
        self.notifier.alert("needs-input" if state == "needs-input" else "ticket-failed", t.number,
                            f"#{t.number} {t.title}: {reason}")
        return StageResult(False, reason=reason)

    # claim ---------------------------------------------------------------------------------------------------------
    # limits ----------------------------------------------------------------------------------------------------------
    def limits(self) -> tuple[int, float]:
        """(max LLM sessions, CPU limit %): the owner's runtime override if set (`starpipe limits`), else the config."""
        sessions, cpu = self.db.get("limit_llm") or self.db.get("max_active"), self.db.get("limit_cpu")  # max_active: the monitor's stepper
        return (int(sessions) if sessions and sessions.isdigit() and int(sessions) >= 1 else self.config.max_llm_sessions,
                float(cpu) if cpu else self.config.cpu_limit_pct)

    def max_active(self) -> int:
        """How many LLM sessions may run at once (what the monitor's concurrency control shows)."""
        return self.limits()[0]

    def llm_active(self) -> int:
        """Sessions in the middle of work. One whose ticket is only waiting for the heavy lock is not generating anything."""
        from . import heavy

        waiting = {w.ticket for w in heavy.status().queue}
        return len([s for s in self.db.running_stages() if str(s["ticket"]) not in waiting])

    def llm_room(self) -> load.Room:
        sessions, cpu_limit = self.limits()
        return load.room(self.llm_active(), self.cpu(), sessions, cpu_limit)

    def claimable(self) -> Ticket | None:
        if self.db.get("pause") in ("all", "claims") or self.db.get("self_update_pending"):
            return None  # the second is the daemon waiting to swap to new code: nothing new starts, running stages finish
        if not self.llm_room().ok:  # a new ticket would start an LLM session at once: only when there is room for one
            return None
        for t in self.db.tickets(("queued",)):  # ordered by priority then age
            if not self.db.open_blockers(t.number):
                return t
        return None

    def claim(self, t: Ticket) -> Ticket:
        try:
            ship.fetch(self, self.repo)
        except RuntimeError:
            pass  # best effort: a stale base is fixed again when landing
        wt, branch = worktrees.create(self.repo, t.number, t.title, self.base_ref)
        self.db.set_fields(t.number, worktree=str(wt), branch=branch, claimed_at=self.clock())
        self._to_state(t.number, "exploring")
        self.db.event("claimed", t.number, branch=branch)
        updated = self.db.ticket(t.number)
        assert updated is not None
        return updated

    # model stages --------------------------------------------------------------------------------------------------
    def _usage_paused_until(self) -> float:
        return float(self.db.get("usage_pause_until") or 0)

    async def _wait_for_usage(self) -> None:
        while (left := self._usage_paused_until() - self.clock()) > 0:
            await self.sleep(min(left, 60))
        self.db.put("usage_pause_until", None)

    async def _wait_for_update_hold(self) -> None:
        while self.db.get("self_update_pending"):
            await self.sleep(5)

    def _fence(self, t: Ticket, stage: str) -> guards.Fence:
        return guards.Fence(Path(t.worktree or ""), worktrees.ticket_dir(t.number), home() / "build" / f"pipe-{t.number}",
                            read_only=stage in READ_ONLY_STAGES, branch=t.branch or "")

    def _last_session(self, t: Ticket, stage: str) -> str | None:
        rows = [s for s in self.db.stages(t.number, stage) if s["session_id"]]
        return rows[-1]["session_id"] if rows else None

    def _stage_choice(self, t: Ticket, stage: str, attempt: int) -> tuple[str, str]:
        """The model and effort for one attempt: the ticket's `model_<stage>`/`effort_<stage>` where valid, else the config.

        The ticket row is re-read so an edit picked up by intake applies to the next attempt. Attempt 3 escalates to
        `config.model_escalate` unless the ticket names a model for the stage. A bad value is ignored and noted.
        """
        fresh = self.db.ticket(t.number) or t
        chosen = tickets.parse_pipeline(fresh.body)
        suffix = stage.replace("-", "_")
        model = self.config.model if attempt < 3 else self.config.model_escalate
        effort = "high"
        for kind in ("model", "effort"):
            key = f"{kind}_{suffix}"
            if key not in chosen:
                continue
            bad = tickets.validate_choice(key, chosen[key], self.config.allow_fable)
            if not bad and kind == "model" and chosen[key] == "opus" and not (
                    self.config.allow_opus or self.db.get(f"opus_ok:{t.number}")):
                bad = "opus is used only when the owner asks for it (monitor picker, `starpipe allow-opus`)"
            if bad:
                self.db.event("stage-choice-ignored", t.number, stage=stage, attempt=attempt, key=key, value=chosen[key],
                              reason=bad)
            elif kind == "model":
                model = chosen[key]
            else:
                effort = chosen[key]
        return model, effort

    async def model_stage(self, t: Ticket, stage: str, prompt: str, *, fresh: bool = False,
                          allow_resolve: bool = True) -> tuple[StageResult, Contract]:
        """Run a model stage through the attempt ladder (§7.5). Returns once a contract call is accepted or it parks."""
        contract = Contract(t, Path(t.worktree or ""), self.base_ref, self.db, self.gh, self.check_runner,
                            owner_filed=t.author.lower() == self.config.owner.lower() and not self.db.get(f"auto:{t.number}"))
        resume = None if fresh else self._last_session(t, stage)
        pending = self._undelivered_answer(t)
        if pending:
            prompt = f"The owner's answer to your question:\n\n{pending['answer']}\n\nContinue the stage.\n\n{prompt}"
            self.db.put(f"delivered:{pending['id']}", "1")
        attempt, crashes = 1, 0
        summary = ""
        while attempt <= 3:
            await self._wait_for_usage()
            await self._wait_for_update_hold()
            model, effort = self._stage_choice(t, stage, attempt)
            stage_id = await self._begin_when_room(t, stage, attempt, model)
            body = prompt if resume or attempt == 1 else f"{prompt}\n\nA previous attempt ended without result. {summary}"
            req = StageRequest(t.number, stage, attempt, body,
                               prompt_text("_preamble") + "\n\n" + prompt_text(stage.replace("-", "_")), model,
                               effort, BUDGET_S[stage], contract, self._fence(t, stage), resume,
                               on_session=lambda sid, sid_row=stage_id: self.db.set_session(sid_row, sid))
            out: StageOutcome = await self.agent.run(req)
            if out.session_id:
                self.db.set_session(stage_id, out.session_id)
            self.db.end_stage(stage_id, out.status, contract.lock_wait_s, out.summary[:500])
            if out.status == "accepted" and contract.result:
                kind, value = contract.result
                self._file_followups(t, contract)
                if kind == "question":
                    return await self._handle_question(t, stage, value, prompt, contract, allow_resolve), contract
                return StageResult(True, kind, value), contract
            known = out.session_id or self._last_session(t, stage)  # the row has it even if the run never finished
            if out.status == "usage-limit":
                self.db.put("usage_pause_until", str(out.resets_at or self.clock() + 1800))
                self.db.event("usage-pause", None, until=out.resets_at)
                resume = known or resume
                continue  # not a failure: no attempt counted
            summary = out.summary
            if out.status == "crash":
                crashes += 1
                if crashes > MAX_CRASH_RESUMES:
                    return self.park(t, f"{stage}: session crashed {crashes} times: {out.summary}"), contract
                resume = known or resume
                continue
            crashes = 0
            resume = known if out.status == "timeout" else None
            attempt += 1
        return self.park(t, f"{stage}: no accepted result after 3 attempts. {summary}"), contract

    async def _begin_when_room(self, t: Ticket, stage: str, attempt: int, model: str) -> int:
        """Start a stage's session only while there is room: fewer than the limit of LLM sessions running and CPU not saturated.
        Waits (and says why, in the ticket's activity line) instead of starting a session the machine cannot afford."""
        while True:
            async with self.llm_lock:
                room = self.llm_room()
                if room.ok:
                    self.db.put(f"llm_wait:{t.number}", None)
                    return self.db.begin_stage(t.number, stage, attempt, model)
            self.db.put(f"llm_wait:{t.number}", room.reason)
            await self.sleep(15)

    def _undelivered_answer(self, t: Ticket) -> dict[str, Any] | None:
        rows = self.db._all("SELECT * FROM questions WHERE ticket=? AND answer IS NOT NULL ORDER BY id DESC LIMIT 1",  # pyright: ignore[reportPrivateUsage]
                            (t.number,))
        if rows and not self.db.get(f"delivered:{rows[0]['id']}"):
            return dict(rows[0])
        return None

    def _file_followups(self, t: Ticket, contract: Contract) -> None:
        for item in contract.followups:
            try:
                self.gh.ensure_label(PROPOSED)
                n = self.gh.create_issue(item["title"], f"{item['body']}\n\nFiled by the pipeline while working on #{t.number}."
                                         + filed_by(f"pipeline stage of #{t.number}"))
                self.gh.add_labels(n, ["pipe:filed-by-pipeline", PROPOSED])  # waits for `starpipe approve`
                self.db.event("followup", t.number, issue=n)
            except GitHubError as exc:
                self.db.event("followup-failed", t.number, error=str(exc))
        contract.followups.clear()

    async def _handle_question(self, t: Ticket, stage: str, q: dict[str, Any], prompt: str, contract: Contract,
                               allow_resolve: bool) -> StageResult:
        """RESOLVE first (§11); only an escalation reaches the owner."""
        qid = self.db.add_question(t.number, stage, q["question"], q)
        if allow_resolve and not self.db.asked_before(t.number, q["question"]):
            rprompt = (f"Ticket #{t.number} {t.title}\n\n{trust.untrusted_block(self._issue(t), self.config.owner)}\n\n"
                       f"Stage: {stage}\nQuestion: {q['question']}\nWhy it was asked: {q['why']}\n"
                       f"Options: {json.dumps(q['options'])}\nRecommendation: {q['recommendation']}")
            result, _ = await self.model_stage(t, "resolve", rprompt, fresh=True, allow_resolve=False)
            if result.ok and result.kind == "resolution":
                res = result.value
                if res["kind"] == "answer":
                    self.gh.comment(t.number, f"{trust.marker('resolved', qid)}\nAnswered by resolver: {res['text']}\n\n"
                                              f"Settled by: {', '.join(res['reasons'])}")
                    self.db.answer_question(qid, res["text"], "resolver")
                    return await self._redo_after_answer(t, stage, prompt)
        return self._escalate(t, stage, qid, q)

    async def _redo_after_answer(self, t: Ticket, stage: str, prompt: str) -> StageResult:
        result, _ = await self.model_stage(t, stage, prompt)
        return result

    def _escalate(self, t: Ticket, stage: str, qid: int, q: dict[str, Any]) -> StageResult:
        options = "\n".join(f"- {o}" for o in q.get("options", []))
        cid = self.gh.comment(t.number, f"{trust.marker('question', qid)}\n**Question ({stage})**: {q['question']}\n\n"
                                        f"{q['why']}\n\n{options}\n\nRecommendation: {q.get('recommendation') or 'none'}\n\n"
                                        "Reply on this issue, or `starpipe answer "
                                        f"{t.number} \"…\"`.")
        self.db.set_question_comment(qid, cid)
        return self.park(t, f"waiting on the owner: {q['question'][:120]}", state="needs-input")

    def _issue(self, t: Ticket) -> dict[str, Any]:
        return {"title": t.title, "body": t.body, "user": {"login": t.author}}

    # context for prompts ---------------------------------------------------------------------------------------------
    def _ticket_text(self, t: Ticket) -> str:
        return f"Ticket #{t.number}\n\n{trust.untrusted_block(self._issue(t), self.config.owner)}"

    # the flow ------------------------------------------------------------------------------------------------------
    async def drive(self, number: int) -> None:
        """Advance one ticket until it parks, finishes or reaches ready-to-publish."""
        while True:
            t = self.db.ticket(number)
            if t is None or t.number in self.parked:
                return
            if t.state == "queued":
                t = self.claim(t)
            elif t.state == "exploring":
                if not await self._explore(t):
                    return
            elif t.state == "developing":
                if not await self._develop(t):
                    return
            elif t.state == "verifying":
                if not await self._verify(t):
                    return
            elif t.state == "review":
                if not await self._review(t):
                    return
            elif t.state == "ready":
                if self.config.landing_mode == "batch":
                    return  # the landing train (train.py) takes it from here
                if not await self._publish_when_room(t):
                    return
            elif t.state in ("ci", "landing") and self.db.batch_of(t.number) is not None:
                return  # in a batch: the train owns it
            elif t.state == "ci":
                if not await ship.run_ci(self, t):
                    return
            elif t.state == "landing":
                if not await ship.land(self, t):
                    return
            else:
                return

    async def _publish_when_room(self, t: Ticket) -> bool:
        """PUBLISH, but only while fewer than `max_in_ci` tickets are in CI or landing. Several PRs at once queue for the same GitHub
        runners and invalidate each other (each landing makes the others catch up and run CI again), so the rest wait here as `ready`."""
        while True:
            async with self.publish_lock:
                cur = self.db.ticket(t.number)
                if cur is None or cur.state != "ready":
                    return False
                if len(self.db.tickets(("ci", "landing"))) < self.config.max_in_ci:
                    return await asyncio.to_thread(ship.publish, self, cur)
            await self.sleep(30)

    async def _explore(self, t: Ticket) -> bool:
        result, _ = await self.model_stage(t, "explore", f"{self._ticket_text(t)}\n\nBase: {self.base_ref}")
        if not result.ok:
            return False
        if result.kind == "plan":
            self.db.set_fields(t.number, plan_json=json.dumps(result.value))
            (worktrees.ticket_dir(t.number) / "plan.json").write_text(json.dumps(result.value, indent=2))
            self._to_state(t.number, "developing")
            return True
        if result.kind == "close":
            return self._close(t, result.value)
        return False

    def _close(self, t: Ticket, value: dict[str, Any]) -> bool:
        evidence = ", ".join(value["evidence"])
        text = f"{trust.marker('close', t.number)}\nClosing: {value['reason']}. Evidence: {evidence}"
        if value.get("owner_filed"):
            # an owner-filed ticket waits 24 h for a veto comment (checked by close_due)
            self.gh.comment(t.number, text + "\n\nI will close this in 24 h unless you comment.")
            self.db.put(f"close_at:{t.number}", str(self.clock() + 24 * 3600))
            self._to_state(t.number, "paused", f"closing on {value['reason']}; waiting 24h for a veto")
            return False
        self.gh.comment(t.number, text)
        self.gh.close_issue(t.number)
        self._to_state(t.number, "closed", value["reason"])
        return False

    def close_due(self) -> None:
        """Close owner-filed tickets whose 24 h veto window has passed with no owner comment."""
        for t in self.db.tickets(("paused",)):
            due = self.db.get(f"close_at:{t.number}")
            if not due or float(due) > self.clock():
                continue
            vetoed = [c for c in self.gh.comments(t.number)
                      if not trust.is_pipeline_comment(c) and c["user"]["login"].lower() == self.config.owner.lower()]
            self.db.put(f"close_at:{t.number}", None)
            if vetoed:
                self.db.intervention(t.number, "veto", "explore")
                self._to_state(t.number, "exploring", "close vetoed by the owner")
            else:
                self.gh.close_issue(t.number)
                self._to_state(t.number, "closed", "closed after 24h without a veto")

    async def _develop(self, t: Ticket, extra: str = "") -> bool:
        plan = json.dumps(t.plan, indent=2)
        findings = self._pending_findings(t)
        prompt = f"{self._ticket_text(t)}\n\nPlan:\n{plan}\n\nBase: {self.base_ref}\n{findings}{extra}"
        result, _ = await self.model_stage(t, "develop", prompt)
        if not result.ok:
            return False
        (worktrees.ticket_dir(t.number) / "change.json").write_text(json.dumps(result.value, indent=2))
        self._to_state(t.number, "verifying")
        return True

    def _pending_findings(self, t: Ticket) -> str:
        raw = self.db.get(f"findings:{t.number}")
        if not raw:
            return ""
        self.db.put(f"findings:{t.number}", None)
        return f"\nThe reviewer asked for changes:\n{raw}\n"

    def _fix_cycles(self, t: Ticket) -> int:
        return len(self.db.stages(t.number, "fix"))

    async def _verify(self, t: Ticket) -> bool:
        wt = Path(t.worktree or "")
        # The checks wait for the heavy lock and run for hours: on the event loop they froze the whole daemon (API, monitor, every other ticket).
        failure = await asyncio.to_thread(self._run_verification, t, wt)
        while failure and self._fix_cycles(t) < MAX_FIX_CYCLES:
            result, _ = await self.model_stage(t, "fix", f"{self._ticket_text(t)}\n\nFailure:\n{failure}", fresh=True)
            if not result.ok:
                return False
            failure = await asyncio.to_thread(self._run_verification, t, wt)
        if failure:
            self.park(t, f"verification failed after {MAX_FIX_CYCLES} fix cycles: {failure[:300]}")
            return False
        self._to_state(t.number, "review")
        return True

    def _run_verification(self, t: Ticket, wt: Path) -> str:
        """The daemon's own run of T0+T1 at HEAD and the negative control. Empty string means green."""
        sha = gitutil.head_sha(wt)
        if not gitutil.is_clean(wt):
            return "the tree is not clean"
        results = self.check_runner(wt, self.base_ref)
        for r in results:
            self.db.record_check(t.number, sha, r.check, r.status,
                                 {"executed": r.executed, "failed": r.failed, "skipped": r.skipped}, r.log)
        red = [r for r in results if not r.green]
        if red:
            return "\n".join(f"{r.status.upper()} {r.check}: {r.detail} (log {r.log})" for r in red)
        plan = t.plan or {}
        names = [x["name"] for x in plan.get("tests", {}).get("new", []) if x.get("fails_before_fix")]
        self.db.event("negative-control", t.number, tests=names)
        controls = self.negative_control(wt, self.base_ref, names)
        self.db.put(f"controls:{t.number}", json.dumps([c.__dict__ for c in controls]))
        bad = [c for c in controls if c.bad]
        if bad and not self.db.get(f"nc-retried:{t.number}"):
            self.db.put(f"nc-retried:{t.number}", "1")
            return "does not discriminate (passes on the merge-base without the fix): " + ", ".join(c.test for c in bad)
        return ""

    async def _review(self, t: Ticket) -> bool:
        controls = self.db.get(f"controls:{t.number}") or "[]"
        round_no = len(self.db.stages(t.number, "review")) + 1
        for _ in (0,):
            diffstat = gitutil.git(Path(t.worktree or ""), "diff", "--stat", f"{self.base_ref}...HEAD")
            prompt = (f"{self._ticket_text(t)}\n\nPlan:\n{json.dumps(t.plan, indent=2)}\n\nBase: {self.base_ref}\n"
                      f"Negative control: {controls}\nDiffstat:\n{diffstat}")
            result, _ = await self.model_stage(t, "review", prompt, fresh=True)
            if not result.ok:
                return False
            review = result.value
            if review["verdict"] == "approve":
                (worktrees.ticket_dir(t.number) / "review.json").write_text(json.dumps(review, indent=2))
                self._to_state(t.number, "ready")
                self.db.event("ready", t.number)
                return True
            if round_no > MAX_REVIEW_ROUNDS:
                self.park(t, f"review still asks for changes after {MAX_REVIEW_ROUNDS} rounds")
                return False
            self.db.put(f"findings:{t.number}", json.dumps(review["findings"], indent=2))
            self._to_state(t.number, "developing")
            return True  # drive() re-enters DEVELOP, then VERIFY, then REVIEW again
        return False


def check_runner_for(say: Callable[[str], None] = lambda _m: None) -> CheckRunner:
    """The real T0+T1 runner, used by the daemon and by the run_checks tool."""
    from .checks import runner

    def run(worktree: Path, base: str) -> list[ledger.Result]:
        changed = gitutil.changed_paths(worktree, base)
        plan = impact.plan_for(changed)
        return runner.run_plan(plan, worktree, base, {"t0", "t1"}, say=say)

    return run
