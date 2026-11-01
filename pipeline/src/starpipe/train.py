"""The landing train: one CI for many tickets (plan §10, revised 2026-10-31).

Tickets that finish REVIEW wait in `ready`. When no batch is running, the train takes what is ready (up to `batch_max`), builds
one integration branch (develop plus each ticket's branch, merged in order), opens ONE pull request and runs ONE CI. Green: merge it
and land every member. Red: rerun what looks like a flake, otherwise split the batch in half and try the halves, down to one
ticket, which goes through CI-FIX and rejoins the queue. CI taking an hour is the collection window: whatever becomes ready meanwhile
is the next batch.

Why: a PR and a full CI per ticket queued six matrices for the same few GitHub runners, and every landing made the others catch up
and run again. A ticket that conflicts with an earlier member waits for the next batch; one that conflicts with develop itself goes
through the existing CONFLICT stage first.

Everything here that touches git or GitHub runs in a worker thread: on the event loop it froze the daemon (plan §19, 2026-10-31).
"""

from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

from . import ci, gitutil, landing, ship, worktrees
from .db import Ticket
from .github import GitHubError

if TYPE_CHECKING:
    from .engine import Engine

WORKTREE = "pipe-batch"
BACKOFF_S = 60.0


def batch_worktree(repo: Path) -> Path:
    return repo / ".claude" / "worktrees" / WORKTREE


def batch_branch(batch: int) -> str:
    return f"pipe/batch-{batch}"


@dataclass
class Built:
    merged: list[int] = field(default_factory=lambda: list[int]())
    deferred: list[int] = field(default_factory=lambda: list[int]())  # conflict with an earlier member: next batch
    catch_up: list[int] = field(default_factory=lambda: list[int]())  # conflict with develop itself: the CONFLICT stage
    head: str = ""


class Train:
    def __init__(self, eng: Engine) -> None:
        self.eng = eng

    # the loop ------------------------------------------------------------------------------------------------------
    async def run_forever(self) -> None:
        while True:
            did = await self.step()
            await asyncio.sleep(2 if did else 15)

    async def run_until_idle(self, limit: int = 50) -> int:
        steps = 0
        while steps < limit and await self.step():
            steps += 1
        return steps

    def _held(self) -> bool:
        db = self.eng.db
        return db.get("pause") in ("all", "landing") or bool(db.get("stop_line"))

    async def step(self) -> bool:
        """Advance the train by one thing. True when something happened (so the caller need not wait)."""
        eng = self.eng
        if eng.config.landing_mode != "batch":
            return False
        batch = eng.db.active_batch()
        if batch is not None:
            await self._drive(int(batch["id"]))
            return True
        if self._held():
            return False
        members = self._pick()
        if not members:
            return False
        await self._start(members)
        return True

    # forming a batch -----------------------------------------------------------------------------------------------
    def _pick(self) -> list[int]:
        eng = self.eng
        ready = [t for t in eng.db.tickets(("ready",)) if eng.db.batch_of(t.number) is None]
        ids = [t.number for t in ready]
        groups: list[list[int]] = json.loads(eng.db.get("train_groups") or "[]")
        while groups:  # halves of a batch that went red: exactly these tickets, nothing else
            group = [n for n in groups.pop(0) if n in ids]
            eng.db.put("train_groups", json.dumps(groups) if groups else None)
            if group:
                return group
        if not ready:
            return []
        oldest = min(eng.db.state_since(t.number, "ready") or t.updated_at for t in ready)
        if len(ready) >= eng.config.batch_max or eng.clock() - oldest >= eng.config.batch_window_s:
            return ids[: eng.config.batch_max]
        return []

    async def _start(self, members: list[int]) -> None:
        eng = self.eng
        try:
            await asyncio.to_thread(ship.fetch, eng, eng.repo)
            base = (await asyncio.to_thread(gitutil.git, eng.repo, "rev-parse", f"origin/{eng.config.base_branch}")).strip()
        except (RuntimeError, GitHubError) as exc:
            eng.db.event("train-fetch-failed", None, error=str(exc)[:200])
            await eng.sleep(BACKOFF_S)
            return
        bid = eng.db.batch_create(base)
        tickets = [t for n in members if (t := eng.db.ticket(n)) is not None and t.state == "ready"]
        try:
            built = await asyncio.to_thread(self._build, bid, tickets, base)
        except (RuntimeError, OSError) as exc:
            await asyncio.to_thread(self._abandon, bid, f"could not build the batch: {exc}")
            await eng.sleep(BACKOFF_S)
            return
        for n in built.catch_up:  # conflicts with develop itself: the CONFLICT stage, then back in the queue
            await self._catch_up(n)
        if not built.merged:
            await asyncio.to_thread(self._abandon, bid, "nothing merged cleanly")
            return
        try:
            await asyncio.to_thread(self._publish, bid, built, base)
        except (GitHubError, RuntimeError) as exc:
            await asyncio.to_thread(self._abandon, bid, f"could not publish the batch: {exc}")
            await eng.sleep(BACKOFF_S)

    def _build(self, bid: int, tickets: list[Ticket], base: str) -> Built:
        repo = self.eng.repo
        wt = batch_worktree(repo)
        self._remove_worktree()
        gitutil.git(repo, "worktree", "add", "--detach", str(wt), base)
        gitutil.git(wt, "checkout", "-q", "-b", batch_branch(bid))
        built = Built()
        for t in tickets:
            code, _ = gitutil.run(wt, "merge", "--no-ff", "--no-edit", "-m", f"Merge #{t.number}: {t.title}", t.branch or "")
            if code == 0:
                built.merged.append(t.number)
                continue
            gitutil.run(wt, "merge", "--abort")
            (built.deferred if gitutil.merges_cleanly(repo, base, t.branch or "") else built.catch_up).append(t.number)
        built.head = gitutil.head_sha(wt)
        return built

    def _publish(self, bid: int, built: Built, base: str) -> None:
        eng = self.eng
        wt, branch = batch_worktree(eng.repo), batch_branch(bid)
        if eng.config.remote == "https":
            gitutil.remote_push(wt, eng.config.owner, eng.config.repo, branch)
        else:
            gitutil.git(wt, "push", "--quiet", "origin", f"HEAD:refs/heads/{branch}")
        tickets = [t for n in built.merged if (t := eng.db.ticket(n)) is not None]
        title = f"Batch #{bid}: " + ", ".join(f"#{t.number}" for t in tickets)
        pr = eng.gh.create_pr(title, self._body(bid, tickets), branch, eng.config.base_branch)
        eng.db.batch_update(bid, state="ci", branch=branch, pr_number=int(pr["number"]), head_sha=built.head,
                            ci_started=eng.clock())
        eng.db.put(f"pushed_at:batch{bid}", str(eng.clock()))
        for position, t in enumerate(tickets):  # the members first, then their state: drive() skips tickets in a batch
            eng.db.batch_add(bid, t.number, position)
            eng.db.set_fields(t.number, pr_number=int(pr["number"]))
            eng._to_state(t.number, "ci")  # pyright: ignore[reportPrivateUsage]
        eng.db.event("batch-published", None, batch=bid, pr=pr["number"], members=built.merged)

    def _body(self, bid: int, tickets: list[Ticket], notes: str = "") -> str:
        sections: list[str] = []
        for t in tickets:
            plan = t.plan or {}
            acceptance = "\n".join(f"  - {a['id']}: {a['check']}" for a in plan.get("acceptance", []))
            sections.append(f"### #{t.number} {t.title}\n{plan.get('summary', '')}\n{acceptance}")
        closes = "\n".join(f"Closes #{t.number}" for t in tickets)
        return (f"Batch #{bid}: one CI for {len(tickets)} ticket(s), opened by the star pipeline's landing train.\n\n{closes}\n\n"
                + "\n\n".join(sections) + (f"\n\n## CI notes\n{notes}\n" if notes else "\n"))

    async def _catch_up(self, n: int) -> None:
        eng = self.eng
        t = eng.db.ticket(n)
        if t is None or t.state != "ready":
            return
        base = f"origin/{eng.config.base_branch}"
        head = (await asyncio.to_thread(gitutil.git, eng.repo, "rev-parse", t.branch or "")).strip()
        mb = (await asyncio.to_thread(gitutil.git, eng.repo, "merge-base", base, head)).strip()
        await ship.catch_up(eng, t, base, mb, head, landing.Overlap([], []), rejoin=True)

    # running it ----------------------------------------------------------------------------------------------------
    async def _drive(self, bid: int) -> None:
        eng = self.eng
        batch = eng.db.batch(bid)
        assert batch is not None
        if batch["state"] == "building":  # the daemon died while building it: nothing was published
            await asyncio.to_thread(self._abandon, bid, "interrupted while building")
            return
        if batch["state"] == "landing":  # died between the merge and the bookkeeping
            await asyncio.to_thread(self._resume_landing, bid)
            return
        outcome = await self._ci(bid)
        if outcome[0] == "abandon":
            await asyncio.to_thread(self._abandon, bid, str(outcome[1]))
        elif outcome[0] == "red" and isinstance(outcome[1], ci.Verdict):
            await self._on_red(bid, outcome[1])
        else:
            await self._land(bid, str(outcome[1]))

    async def _ci(self, bid: int) -> tuple[str, ci.Verdict | str]:
        """Judge the batch's CI until it passes, is red, or must be given up on."""
        eng = self.eng
        while True:
            batch = eng.db.batch(bid)
            assert batch is not None
            members = eng.db.batch_members(bid)
            gone = [n for n in members if (t := eng.db.ticket(n)) is None or t.state != "ci"]
            if gone:  # cancelled or parked while in the batch: its changes are in the integration branch, so rebuild without it
                return ("abandon", f"#{gone[0]} left the batch")
            reran = {tuple(k) for k in json.loads(eng.db.get(f"reran:batch{bid}") or "[]")}
            try:
                verdict = await asyncio.to_thread(ship._judge, eng, f"batch{bid}", batch["head_sha"], reran)  # pyright: ignore[reportPrivateUsage]
            except GitHubError as exc:
                eng.db.event("ci-poll-failed", None, batch=bid, error=str(exc)[:200])
                await eng.sleep(eng.config.ci_poll_s)
                continue
            eng.db.record_ci(0, batch["head_sha"], verdict.kind, {"batch": bid, "reason": verdict.reason})
            if verdict.kind == "pending":
                age = eng.clock() - float(eng.db.get(f"pushed_at:batch{bid}") or eng.clock())
                await eng.sleep(ci.poll_delay(age, eng.config.ci_poll_s))
            elif verdict.kind == "rerun":
                ready = await asyncio.to_thread(ship._rerun, eng, None, [j for j in verdict.rerun if j.run_done])  # pyright: ignore[reportPrivateUsage]
                reran |= {j.key for j in ready}
                eng.db.put(f"reran:batch{bid}", json.dumps(sorted(reran)))
                await eng.sleep(eng.config.ci_poll_s)
            elif verdict.kind == "pass":
                notes = [f"known red on develop (not blocking): {j.workflow}/{j.job}" for j in verdict.known_red]
                notes += [f"still running after {eng.config.ci_blocking_wait_s / 3600:g} h (demoted to the post-merge watch): "
                          f"{j.workflow}/{j.job}" for j in verdict.demoted]
                return ("pass", "\n".join(f"- {n}" for n in notes))
            else:
                return ("red", verdict)

    async def _land(self, bid: int, notes: str) -> None:
        eng = self.eng
        async with eng.land_lock:
            while self._held():
                await eng.sleep(eng.config.ci_poll_s)
            members = eng.db.batch_members(bid)
            if any((t := eng.db.ticket(n)) is None or t.state != "ci" for n in members):
                await asyncio.to_thread(self._abandon, bid, "a member left the batch while it waited to land")
                return
            result = await asyncio.to_thread(self._merge, bid, notes)
        if result == "rebuild":
            await asyncio.to_thread(self._abandon, bid, "develop moved with overlapping changes: rebuilding on the new base")
        elif result.startswith("refused"):
            await asyncio.to_thread(self._abandon, bid, f"the merge was {result}")
            await eng.sleep(BACKOFF_S)

    def _merge(self, bid: int, notes: str) -> str:
        eng = self.eng
        batch = eng.db.batch(bid)
        assert batch is not None
        wt = batch_worktree(eng.repo)
        try:
            base = ship._remote(eng, wt)  # pyright: ignore[reportPrivateUsage]
            pr = eng.gh.pr(int(batch["pr_number"]))
            head = pr["head"]["sha"]
            mb = gitutil.git(wt, "merge-base", base, head).strip()
            if head != batch["head_sha"]:
                return "rebuild"
            if mb != gitutil.git(wt, "rev-parse", base).strip():  # develop moved while CI ran
                files = [p for p in gitutil.git(wt, "diff", "--name-only", f"{mb}..{head}").splitlines() if p]
                if landing.overlap(wt, mb, base, files).any or pr.get("mergeable") is False:
                    return "rebuild"
            if notes:
                tickets = [t for n in eng.db.batch_members(bid) if (t := eng.db.ticket(n)) is not None]
                eng.gh.update_pr(int(batch["pr_number"]), self._body(bid, tickets, notes))
            eng.gh.merge_pr(int(batch["pr_number"]), head)
        except (GitHubError, RuntimeError) as exc:
            return f"refused: {exc}"
        ship.fetch(eng, wt)
        merged = eng.gh.pr(int(batch["pr_number"]))
        sha = merged.get("merge_commit_sha") or ""
        base = f"origin/{eng.config.base_branch}"
        if not (sha and gitutil.is_ancestor(wt, sha, base) and merged.get("merged")):
            eng.notifier.alert("phantom-landing", None, f"batch #{bid}: merge reported but {sha[:10]} is not on {base}")
            for n in eng.db.batch_members(bid):
                if (t := eng.db.ticket(n)) is not None:
                    eng.park(t, "landing could not be verified: the batch's merge commit is not on origin/develop")
            eng.db.batch_update(bid, state="abandoned", ended=eng.clock(), note="phantom landing")
            return "phantom"
        eng.db.batch_update(bid, state="landing", note=sha)
        self._finish(bid, sha)
        return "merged"

    def _resume_landing(self, bid: int) -> None:
        eng = self.eng
        batch = eng.db.batch(bid)
        assert batch is not None
        try:
            merged = eng.gh.pr(int(batch["pr_number"]))
        except GitHubError:
            return
        if merged.get("merged") and merged.get("merge_commit_sha"):
            self._finish(bid, str(merged["merge_commit_sha"]))
        else:
            eng.db.batch_update(bid, state="ci")  # it never merged: judge it again

    def _finish(self, bid: int, sha: str) -> None:
        """Bookkeeping after the merge, safe to run twice: issues closed, branches and worktrees gone, tickets landed."""
        eng = self.eng
        wt = batch_worktree(eng.repo)
        changed = gitutil.git(wt, "diff", "--name-only", f"{sha}^1", sha, check=False).split() if wt.exists() else []
        if any(p.startswith("pipeline/") and not p.startswith("pipeline/monitor/") for p in changed):
            eng.db.put("self_update_wanted", sha)
        for n in eng.db.batch_members(bid):
            t = eng.db.ticket(n)
            if t is None or t.state == "landed":
                continue
            try:
                if eng.gh.issue(n).get("state") != "closed":
                    eng.gh.close_issue(n, "completed")
                eng.gh.add_labels(n, ["pipe:landed"])
            except GitHubError as exc:
                eng.db.event("landing-bookkeeping-failed", n, error=str(exc)[:200])
            worktrees.remove(eng.repo, n, keep_branch=False, branch=t.branch)
            eng._to_state(n, "landed")  # pyright: ignore[reportPrivateUsage]
            eng.db.event("landed", n, merge=sha, batch=bid)
        batch = eng.db.batch(bid)
        if batch and batch["branch"]:
            eng.gh.delete_branch(str(batch["branch"]))
        self._remove_worktree()
        eng.db.batch_update(bid, state="landed", ended=eng.clock())

    # when it does not land -----------------------------------------------------------------------------------------
    async def _on_red(self, bid: int, verdict: ci.Verdict) -> None:
        eng = self.eng
        members = eng.db.batch_members(bid)
        await asyncio.to_thread(self._abandon, bid, f"CI red: {verdict.reason}", "failed")
        if len(members) > 1:  # try the halves: the culprit is in one of them (log2 of the batch size more CIs, at worst)
            half = (len(members) + 1) // 2
            groups: list[list[int]] = [members[:half], members[half:], *json.loads(eng.db.get("train_groups") or "[]")]
            eng.db.put("train_groups", json.dumps(groups))
            eng.db.event("train-split", None, batch=bid, halves=[members[:half], members[half:]])
            return
        t = eng.db.ticket(members[0]) if members else None
        if t is not None:  # one ticket and still red: it is the culprit, so it gets the CI-FIX stage and rejoins the queue
            await ship.ci_fix(eng, t, verdict, rejoin=True)

    def _abandon(self, bid: int, why: str, final: str = "abandoned") -> None:
        """Give a batch up: close its PR, drop its branch and worktree, and put its tickets back in the queue."""
        eng = self.eng
        batch = eng.db.batch(bid)
        if batch is None:
            return
        try:
            if batch["pr_number"]:
                eng.gh.close_pr(int(batch["pr_number"]), f"Closing this batch: {why}.")
            if batch["branch"]:
                eng.gh.delete_branch(str(batch["branch"]))
        except GitHubError as exc:
            eng.db.event("batch-cleanup-failed", None, batch=bid, error=str(exc)[:200])
        self._remove_worktree()
        for n in eng.db.batch_members(bid):
            t = eng.db.ticket(n)
            if t is not None and t.state == "ci":
                eng.db.set_fields(n, pr_number=None)
                eng._to_state(n, "ready")  # pyright: ignore[reportPrivateUsage]
        eng.db.batch_update(bid, state=final, ended=eng.clock(), note=why[:300])

    def _remove_worktree(self) -> None:
        repo = self.eng.repo
        wt = batch_worktree(repo)
        if wt.exists():
            gitutil.run(repo, "worktree", "remove", "--force", str(wt))
            if wt.exists():
                import shutil

                shutil.rmtree(wt, ignore_errors=True)
                gitutil.run(repo, "worktree", "prune")
