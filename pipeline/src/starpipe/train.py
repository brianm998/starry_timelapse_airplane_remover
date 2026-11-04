"""The landing train: one CI for many tickets (plan §10, revised 2026-10-31).

Tickets that finish REVIEW wait in `ready`. When fewer than `batch_parallel` batches are running, the train takes what is ready (all of it:
a batch has no size cap; with another batch in flight, only tickets whose files that batch does not touch), builds
one integration branch (develop plus each ticket's branch, merged in order), opens ONE pull request and runs ONE CI. Green: merge it
and land every member. Red: rerun what looks like a flake, otherwise split the batch in half and try the halves, down to one
ticket, which goes through CI-FIX and rejoins the queue. CI taking an hour is the collection window: whatever becomes ready meanwhile
is the next batch, and when its files are disjoint from the batch in CI it goes into CI beside it (each batch has its own worktree,
branch and driver task; merges stay one at a time, and a batch that lands after develop moved takes the overlap/catch-up path below).

Why: a PR and a full CI per ticket queued six matrices for the same few GitHub runners, and every landing made the others catch up
and run again. A ticket that conflicts with an earlier member waits for the next batch; one that conflicts with develop itself goes
through the existing CONFLICT stage first.

Everything here that touches git or GitHub runs in a worker thread: on the event loop it froze the daemon (plan §19, 2026-10-31).
"""

from __future__ import annotations

import asyncio
import json
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

from . import ci, gitutil, landing, ship, tickets, worktrees
from .config import Config
from .db import Database, Ticket
from .github import GitHubError

if TYPE_CHECKING:
    from .engine import Engine

WORKTREE = "pipe-batch"
BACKOFF_S = 60.0
SLOW_BUILDING_S = 600.0  # a batch still `building` after this long is marked slow in the snapshot
ABANDONED_MEMORY_S = 3600.0  # how long the snapshot and status remember the last abandoned batch

MAX_NOTED = 5  # files named in an abandon note


def overlap_note(ov: landing.Overlap) -> str:
    """What develop and the batch both changed, for the abandon note: up to MAX_NOTED files, or the shared check sets."""
    if not ov.files:
        return "same checks: " + ", ".join(ov.checks[:MAX_NOTED])
    more = len(ov.files) - MAX_NOTED
    return ", ".join(ov.files[:MAX_NOTED]) + (f" and {more} more" if more > 0 else "")


def batch_worktree(repo: Path, batch: int) -> Path:
    return repo / ".claude" / "worktrees" / f"{WORKTREE}-{batch}"


def batch_branch(batch: int) -> str:
    return f"pipe/batch-{batch}"


def window_left(db: Database, config: Config, now: float) -> float | None:
    """Seconds until the train forms its next batch (0: it is about to), or None when `batch_parallel` batches are active or nothing
    is ready.

    The same arithmetic as `Train._pick`: a batch forms once the oldest ready ticket has waited `batch_window_s`."""
    if len(db.active_batches()) >= config.batch_parallel:
        return None
    ready = [t for t in db.tickets(("ready",)) if db.batch_of(t.number) is None]
    if not ready:
        return None
    if any(ship.land_now_mark(db, t.number) for t in ready):
        return 0.0
    oldest = min(db.state_since(t.number, "ready") or t.updated_at for t in ready)
    return max(0.0, config.batch_window_s - (now - oldest))


@dataclass
class Built:
    merged: list[int] = field(default_factory=lambda: list[int]())
    deferred: list[int] = field(default_factory=lambda: list[int]())  # conflict with an earlier member: next batch
    catch_up: list[int] = field(default_factory=lambda: list[int]())  # conflict with develop itself: the CONFLICT stage
    head: str = ""


class Train:
    def __init__(self, eng: Engine) -> None:
        self.eng = eng
        self._beside: dict[int, asyncio.Task[None]] = {}  # a conflicted ticket's catch-up, beside the train: it is not batched until done
        self._gates: dict[int, asyncio.Task[None]] = {}  # a ticket's Gherkin feature run, beside the train, before it may be batched
        self._drivers: dict[int, asyncio.Task[None]] = {}  # one task per active batch, driving it through CI and landing
        self._wake = asyncio.Event()  # set when a driver ends, so the loop forms the next batch at once
        self._git_lock = threading.Lock()  # fetches and worktree add/remove from two batches' threads must not race on the shared repo
        self._macos_queued: dict[int, int] = {}  # per active batch: CI jobs still waiting for a macOS runner, as of its last poll
        self._deferred: set[tuple[int, int]] = set()  # (ticket, batch) pairs whose feature-run deferral was already reported

    # the loop ------------------------------------------------------------------------------------------------------
    async def run_forever(self) -> None:
        try:
            while True:
                self._wake.clear()
                did = await self.step()
                try:
                    await asyncio.wait_for(self._wake.wait(), 2 if did else 15)
                except TimeoutError:
                    pass
        finally:
            for task in self._drivers.values():
                task.cancel()

    async def run_until_idle(self, limit: int = 50) -> int:
        steps = 0
        while steps < limit:
            if await self.step():
                steps += 1
            elif drivers := [t for t in self._drivers.values() if not t.done()]:  # a batch is running: its end may free the train
                await asyncio.wait(drivers, return_when=asyncio.FIRST_COMPLETED)
            elif others := [t for t in (*self._beside.values(), *self._gates.values()) if not t.done()]:
                await asyncio.wait(others)  # a conflicted ticket's rejoin, or the feature runs of everything now ready
            else:
                break
        return steps

    async def drain(self) -> None:
        """Wait until every batch driver now running has ended (the batches may still be active: a catch-up sends one back to CI)."""
        while drivers := [t for t in self._drivers.values() if not t.done()]:
            await asyncio.wait(drivers)

    def _held(self, bypass_stop_line: bool = False) -> bool:
        db = self.eng.db
        return db.get("pause") in ("all", "landing") or (bool(db.get("stop_line")) and not bypass_stop_line)

    def _owner_landed(self, members: list[int]) -> bool:
        """True when every ticket in the batch carries the owner's land-now mark (so CI and the stop line are skipped)."""
        return bool(members) and all(ship.land_now(self.eng, n) for n in members)

    async def step(self) -> bool:
        """Advance the train by one thing: start a driver for each active batch that has none, and form a new batch when there is room
        for one. Never waits for a batch to finish. True when something happened (so the caller need not wait)."""
        eng = self.eng
        if eng.config.landing_mode != "batch":
            return False
        self._start_gates()  # feature runs cost no landing slot, so they go ahead even while the train is held or busy
        did = self._start_drivers()
        active = eng.db.active_batches()
        if len(active) >= max(1, eng.config.batch_parallel):
            return did
        flagged = [t.number for t in eng.db.tickets(("ready",))
                   if eng.db.batch_of(t.number) is None and ship.land_now(eng, t.number) and not self._gated(t)]
        if self._held(bypass_stop_line=bool(flagged)):
            return did
        paths = None
        if active:  # a batch is in flight: only tickets that share no file with it may go beside it
            numbers = {n for b in active for n in eng.db.batch_members(int(b["id"]))}
            numbers |= {t.number for t in eng.db.tickets(("ready",)) if eng.db.batch_of(t.number) is None}
            paths = await asyncio.to_thread(self._paths_of, sorted(numbers))
        members = self._pick(paths)
        if not members:
            return did
        await self._start(members)
        self._start_drivers()
        return True

    def _start_drivers(self) -> bool:
        started = False
        for b in self.eng.db.active_batches():
            bid = int(b["id"])
            if bid in self._drivers and not self._drivers[bid].done():
                continue
            task = asyncio.create_task(self._driven(bid))
            self._drivers[bid] = task
            task.add_done_callback(lambda t, bid=bid: self._driver_ended(bid, t))
            started = True
        return started

    def _driver_ended(self, bid: int, task: asyncio.Task[None]) -> None:
        if self._drivers.get(bid) is task:
            del self._drivers[bid]
        self._wake.set()

    async def _driven(self, bid: int) -> None:
        try:
            await self._drive(bid)
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 - one batch's failure must not take the train, or the other batch, down
            self.eng.db.event("train-driver-failed", None, batch=bid, error=str(exc)[:200])
            await self.eng.sleep(BACKOFF_S)

    def _paths_of(self, numbers: list[int]) -> dict[int, frozenset[str] | None]:
        """The files each ticket's branch changes against develop; None when that cannot be told (it then overlaps everything)."""
        eng = self.eng
        base = f"origin/{eng.config.base_branch}"
        out: dict[int, frozenset[str] | None] = {}
        for n in numbers:
            t = eng.db.ticket(n)
            try:
                if t is None or not t.branch:
                    raise RuntimeError("no branch")
                mb = gitutil.git(eng.repo, "merge-base", base, t.branch).strip()
                out[n] = frozenset(p for p in gitutil.git(eng.repo, "diff", "--name-only", mb, t.branch).splitlines() if p)
            except RuntimeError:
                out[n] = None
        return out

    # forming a batch -----------------------------------------------------------------------------------------------
    def _gated(self, t: Ticket) -> bool:
        """True while a ticket still owes a Gherkin feature run on its own branch: it is not batched until that is green."""
        db = self.eng.db
        return (bool(tickets.gherkin_features(t.body, t.plan)) and not db.get(f"gherkin_ok:{t.number}")
                and not ship.land_now(self.eng, t.number))

    def _start_gates(self) -> None:
        """Start the feature run of each ready ticket that needs one. It runs on the ticket's own branch, once per ticket: the batch
        branch is a new merge commit, so the batch's CI never carries a feature run.

        While an active batch still has macOS jobs queued, no new run starts: it would take a macOS runner ahead of them. A run already
        going is left alone."""
        eng = self.eng
        active = {int(b["id"]) for b in eng.db.active_batches()}
        waiting = sorted((bid, n) for bid, n in self._macos_queued.items() if bid in active and n > 0)
        for t in eng.db.tickets(("ready",)):
            if eng.db.batch_of(t.number) is None and self._gated(t) and t.number not in self._gates:
                if waiting:
                    bid, queued = waiting[0]
                    if (t.number, bid) not in self._deferred:
                        self._deferred.add((t.number, bid))
                        eng.db.event("gate-deferred", t.number, batch=bid, queued_macos=queued)
                    continue
                task = asyncio.create_task(self._gate_beside(t))
                self._gates[t.number] = task
                task.add_done_callback(lambda _t, n=t.number: self._gates.pop(n, None))

    async def _gate_beside(self, t: Ticket) -> None:
        try:
            await ship.feature_gate(self.eng, t, rejoin=True)
        except Exception as exc:  # noqa: BLE001 - one ticket's feature run must not take the train down
            self.eng.db.event("train-gate-failed", t.number, error=str(exc)[:200])

    def _pick(self, paths: dict[int, frozenset[str] | None] | None = None) -> list[int]:
        """The tickets for the next batch. With another batch in flight, only those sharing no file with any of its members:
        `paths` (from `_paths_of`, computed off the event loop) says which files each ticket changes."""
        eng = self.eng
        # a ticket whose catch-up is still running stays out: landing it would delete the worktree the catch-up is working in
        ready = [t for t in eng.db.tickets(("ready",))
                 if eng.db.batch_of(t.number) is None and not self._gated(t) and t.number not in self._beside]
        ids = [t.number for t in ready]
        flying = [n for b in eng.db.active_batches() for n in eng.db.batch_members(int(b["id"]))]
        if flying and paths is None:
            paths = self._paths_of([*flying, *ids])
        taken = [paths.get(n) for n in flying] if paths is not None else []

        def disjoint(numbers: list[int]) -> bool:
            assert paths is not None
            mine = [paths.get(n) for n in numbers]
            return all(a is not None and b is not None and not (a & b) for a in mine for b in taken)

        groups: list[list[int]] = json.loads(eng.db.get("train_groups") or "[]")
        while groups:  # halves of a batch that went red: exactly these tickets, nothing else
            if any(n in self._beside for n in groups[0]):
                return []  # a member is still catching up: the group stays for the next pick, whole
            if any(n in flying for n in groups[0]):
                return []  # a member is still in the batch being given up (its tickets are going back to the queue one by one)
            group = [n for n in groups[0] if n in ids]
            if group and flying and not disjoint(group):
                return []  # it shares files with the batch in flight: it goes when that one is done
            groups.pop(0)
            eng.db.put("train_groups", json.dumps(groups) if groups else None)
            if group:
                return group
        if flying:
            ready = [t for t in ready if disjoint([t.number])]
            ids = [t.number for t in ready]
        if not ready:
            return []
        flagged = [t.number for t in ready if ship.land_now(eng, t.number)]
        if flagged:  # the owner's land-now: a batch of just these, now, without waiting out the window
            return flagged
        oldest = min(eng.db.state_since(t.number, "ready") or t.updated_at for t in ready)
        if eng.clock() - oldest >= eng.config.batch_window_s:
            return ids
        return []

    async def _start(self, members: list[int]) -> None:
        eng = self.eng
        try:
            await asyncio.to_thread(self._fetch, eng.repo)
            base = (await asyncio.to_thread(gitutil.git, eng.repo, "rev-parse", f"origin/{eng.config.base_branch}")).strip()
        except (RuntimeError, GitHubError) as exc:
            eng.db.event("train-fetch-failed", None, error=str(exc)[:200])
            await eng.sleep(BACKOFF_S)
            return
        bid = eng.db.batch_create(base)
        tickets = [t for n in members if (t := eng.db.ticket(n)) is not None and t.state == "ready"]
        for position, t in enumerate(tickets):  # members from the start, so the monitor can say "in batch N (building)"
            eng.db.batch_add(bid, t.number, position)
        try:
            built = await asyncio.to_thread(self._build, bid, tickets, base)
        except (RuntimeError, OSError) as exc:
            await asyncio.to_thread(self._abandon, bid, f"could not build the batch: {exc}")
            await eng.sleep(BACKOFF_S)
            return
        eng.db.batch_remove(bid, [*built.deferred, *built.catch_up])  # not in this batch after all
        if not built.merged:
            for n in built.catch_up:
                await self._catch_up(n)
            await asyncio.to_thread(self._abandon, bid, "nothing merged cleanly")
            return
        try:
            await asyncio.to_thread(self._publish, bid, built, base)
        except (GitHubError, RuntimeError) as exc:
            await asyncio.to_thread(self._abandon, bid, f"could not publish the batch: {exc}")
            await eng.sleep(BACKOFF_S)
            return
        for n in built.catch_up:  # conflicts with develop itself: the CONFLICT stage runs beside the batch, then back in the queue
            task = asyncio.create_task(self._catch_up_beside(n))
            self._beside[n] = task
            task.add_done_callback(lambda _t, n=n: self._beside.pop(n, None))

    def _fetch(self, root: Path) -> None:
        with self._git_lock:
            ship.fetch(self.eng, root)

    async def _catch_up_beside(self, n: int) -> None:
        """A conflicted ticket's catch-up, off the train's own path: the clean members publish and go through CI without waiting for it."""
        try:
            await self._catch_up(n)
        except Exception as exc:  # noqa: BLE001 - one ticket's catch-up must not take the train down
            self.eng.db.event("train-catch-up-failed", n, error=str(exc)[:200])

    def _build(self, bid: int, tickets: list[Ticket], base: str) -> Built:
        repo = self.eng.repo
        wt = batch_worktree(repo, bid)
        self._remove_worktree(bid)
        with self._git_lock:
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
        wt, branch = batch_worktree(eng.repo, bid), batch_branch(bid)
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
        try:
            outcome = await self._ci(bid)
        finally:
            self._macos_queued.pop(bid, None)
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
            self._start_gates()  # a ticket that became ready while this batch is in CI proves its features meanwhile
            batch = eng.db.batch(bid)
            assert batch is not None
            members = eng.db.batch_members(bid)
            gone = [n for n in members if (t := eng.db.ticket(n)) is None or t.state != "ci"]
            if gone:  # cancelled or parked while in the batch: its changes are in the integration branch, so rebuild without it
                return ("abandon", f"#{gone[0]} left the batch")
            if self._owner_landed(members):
                return ("pass", "- tests bypassed by the owner (land-now)")
            if any(ship.land_now(eng, n) for n in members):  # a flagged ticket must not wait on its unflagged batch-mates' CI
                return ("abandon", "a land-now ticket is in a batch with tickets that still need CI: rebuilding without the wait")
            reran = {tuple(k) for k in json.loads(eng.db.get(f"reran:batch{bid}") or "[]")}
            try:
                jobs, verdict = await asyncio.to_thread(ship._judge_jobs, eng, f"batch{bid}", batch["head_sha"], reran)  # pyright: ignore[reportPrivateUsage]
            except GitHubError as exc:
                eng.db.event("ci-poll-failed", None, batch=bid, error=str(exc)[:200])
                await eng.sleep(eng.config.ci_poll_s)
                continue
            self._macos_queued[bid] = sum(1 for j in jobs if j.queued_for_macos)
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
                notes = ship.pass_notes(eng, verdict, batch=bid)
                return ("pass", "\n".join(f"- {n}" for n in notes))
            else:
                return ("red", verdict)

    async def _land(self, bid: int, notes: str) -> None:
        eng = self.eng
        async with eng.land_lock:
            while self._held(bypass_stop_line=self._owner_landed(eng.db.batch_members(bid))):
                await eng.sleep(eng.config.ci_poll_s)
            members = eng.db.batch_members(bid)
            if any((t := eng.db.ticket(n)) is None or t.state != "ci" for n in members):
                await asyncio.to_thread(self._abandon, bid, "a member left the batch while it waited to land")
                return
            result = await asyncio.to_thread(self._merge, bid, notes)
        if result.startswith("rebuild"):
            why = result.partition(":")[2].strip()
            await asyncio.to_thread(self._abandon, bid, f"develop moved with overlapping changes{f' ({why})' if why else ''}: "
                                    "rebuilding on the new base")
        elif result.startswith("refused"):
            await asyncio.to_thread(self._abandon, bid, f"the merge was {result}")
            await eng.sleep(BACKOFF_S)

    def _merge(self, bid: int, notes: str) -> str:
        eng = self.eng
        batch = eng.db.batch(bid)
        assert batch is not None
        wt = batch_worktree(eng.repo, bid)
        try:
            self._fetch(wt)
            base = f"origin/{eng.config.base_branch}"
            pr = eng.gh.pr(int(batch["pr_number"]))
            head = pr["head"]["sha"]
            mb = gitutil.git(wt, "merge-base", base, head).strip()
            if head != batch["head_sha"]:
                return "rebuild"
            if mb != gitutil.git(wt, "rev-parse", base).strip():  # develop moved while CI ran
                files = [p for p in gitutil.git(wt, "diff", "--name-only", f"{mb}..{head}").splitlines() if p]
                ov = landing.overlap(wt, mb, base, files)
                if pr.get("mergeable") is False:
                    return f"rebuild:{overlap_note(ov)}" if ov.any else "rebuild:the PR is not mergeable"
                if ov.any:
                    # the overlap is real, but it may still merge cleanly: keep the batch and its PR, and run CI on the merge
                    return "updated" if self._catch_up_batch(bid, wt, base, head, ov) else f"rebuild:{overlap_note(ov)}"
            if notes:
                tickets = [t for n in eng.db.batch_members(bid) if (t := eng.db.ticket(n)) is not None]
                eng.gh.update_pr(int(batch["pr_number"]), self._body(bid, tickets, notes))
            eng.gh.merge_pr(int(batch["pr_number"]), head)
        except (GitHubError, RuntimeError) as exc:
            return f"refused: {exc}"
        self._fetch(wt)
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

    def _catch_up_batch(self, bid: int, wt: Path, base: str, head: str, ov: landing.Overlap) -> bool:
        """Merge develop into the green batch's branch and push it, so the same batch and PR go back to CI.

        False (with the worktree left clean) when the merge conflicts: the batch has to be rebuilt instead."""
        eng = self.eng
        if gitutil.head_sha(wt) != head:
            return False
        code, _ = gitutil.run(wt, "merge", "--no-ff", "--no-edit", "-m", f"Merge develop into batch #{bid}", base)
        if code != 0:
            gitutil.run(wt, "merge", "--abort")
            return False
        branch = batch_branch(bid)
        if eng.config.remote == "https":
            gitutil.remote_push(wt, eng.config.owner, eng.config.repo, branch)
        else:
            gitutil.git(wt, "push", "--quiet", "origin", f"HEAD:refs/heads/{branch}")
        new = gitutil.head_sha(wt)
        eng.db.batch_update(bid, head_sha=new, ci_started=eng.clock())
        eng.db.put(f"pushed_at:batch{bid}", str(eng.clock()))
        eng.db.put(f"reran:batch{bid}", None)
        eng.db.event("batch-caught-up", None, batch=bid, files=ov.files[:MAX_NOTED], head=new)
        return True

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
        wt = batch_worktree(eng.repo, bid)
        changed = gitutil.git(wt, "diff", "--name-only", f"{sha}^1", sha, check=False).split() if wt.exists() else []
        if any(p.startswith("pipeline/") and not p.startswith("pipeline/monitor/") for p in changed):
            eng.db.put("self_update_wanted", sha)
        self._seed_baseline(bid, sha, wt)
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
            if eng.db.get(f"gherkin_run:{n}"):  # its feature run needed the branch on origin
                try:
                    eng.gh.delete_branch(t.branch or "")
                except GitHubError as exc:
                    eng.db.event("landing-bookkeeping-failed", n, error=str(exc)[:200])
            worktrees.remove(eng.repo, n, keep_branch=False, branch=t.branch)
            eng._to_state(n, "landed")  # pyright: ignore[reportPrivateUsage]
            eng.db.event("landed", n, merge=sha, batch=bid)
        batch = eng.db.batch(bid)
        if batch and batch["branch"]:
            eng.gh.delete_branch(str(batch["branch"]))
        self._remove_worktree(bid)
        eng.db.batch_update(bid, state="landed", ended=eng.clock())

    def _seed_baseline(self, bid: int, sha: str, wt: Path) -> None:
        """The batch PR's finished jobs become develop's baseline at the merge commit: develop's own push run may skip its jobs
        because this PR already tested the same tree, and a baseline lost that way weakens the judge. A baseline already at a
        commit that descends from the merge (or at the merge itself) is newer or equal and stays. Safe to run twice."""
        eng = self.eng
        batch = eng.db.batch(bid)
        if not batch or not batch["head_sha"]:
            return
        try:
            jobs = ship.fetch_jobs(eng, str(batch["head_sha"]))
        except GitHubError as exc:
            eng.db.event("baseline-seed-failed", None, batch=bid, error=str(exc)[:200])
            return
        root = wt if wt.exists() else eng.repo
        for job in jobs:
            if not job.done or job.conclusion == "skipped":
                continue
            have = eng.db.baseline_sha(*job.key)
            if have and (have == sha or gitutil.is_ancestor(root, sha, have)):
                continue
            eng.db.set_baseline(job.workflow, job.job, sha, job.conclusion or "failure")

    # when it does not land -----------------------------------------------------------------------------------------
    async def _on_red(self, bid: int, verdict: ci.Verdict) -> None:
        eng = self.eng
        members = eng.db.batch_members(bid)
        if len(members) > 1:  # try the halves: the culprit is in one of them (log2 of the batch size more CIs, at worst)
            # recorded before the abandon puts the tickets back: a step() that looks at the queue in between must find the split
            half = (len(members) + 1) // 2
            groups: list[list[int]] = [members[:half], members[half:], *json.loads(eng.db.get("train_groups") or "[]")]
            eng.db.put("train_groups", json.dumps(groups))
            eng.db.event("train-split", None, batch=bid, halves=[members[:half], members[half:]])
            await asyncio.to_thread(self._abandon, bid, f"CI red: {verdict.reason}", "failed")
            return
        await asyncio.to_thread(self._abandon, bid, f"CI red: {verdict.reason}", "failed")
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
                eng.gh.cancel_runs(str(batch["branch"]))  # its CI is of no use now, and queued runs still hold up the others
                eng.gh.delete_branch(str(batch["branch"]))
        except GitHubError as exc:
            eng.db.event("batch-cleanup-failed", None, batch=bid, error=str(exc)[:200])
        self._remove_worktree(bid)
        for n in eng.db.batch_members(bid):
            t = eng.db.ticket(n)
            if t is not None and t.state == "ci":
                eng.db.set_fields(n, pr_number=None)
                eng._to_state(n, "ready")  # pyright: ignore[reportPrivateUsage]
        eng.db.batch_update(bid, state=final, ended=eng.clock(), note=why[:300])

    def _remove_worktree(self, bid: int) -> None:
        repo = self.eng.repo
        wt = batch_worktree(repo, bid)
        if wt.exists():
            with self._git_lock:
                gitutil.run(repo, "worktree", "remove", "--force", str(wt))
                if wt.exists():
                    import shutil

                    shutil.rmtree(wt, ignore_errors=True)
                    gitutil.run(repo, "worktree", "prune")
