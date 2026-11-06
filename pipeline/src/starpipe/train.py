"""The landing train: one CI for many tickets (plan §10, revised 2026-10-31).

Tickets that finish REVIEW wait in `ready`. When fewer than `batch_parallel` batches are running, the train takes what is ready (all of it:
a batch has no size cap; with another batch in flight, only tickets whose files that batch does not touch), builds
one integration branch (develop plus each ticket's branch, merged in order), opens ONE pull request and runs ONE CI. Green: merge it
and land every member (a ticket's Gherkin features are not proven on its own branch first: once the batch is published, one feature run
on the batch branch with the union of the members' features is judged beside the CI, unless every member carries skip-features or
land-now). Red: rerun what looks like a flake, otherwise hold the batch (`asking`) and ask the owner: `bypass` lands it past the failing
job(s) and files a proposed follow-up, `fix` splits the batch in half and tries the halves, down to one ticket, which goes through
CI-FIX and rejoins the queue. Only the red batch waits: it takes no slot and its members are not parked. CI taking an hour is the collection window: whatever becomes ready meanwhile
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
import re
import subprocess
import threading
from dataclasses import dataclass, field
from functools import partial
from pathlib import Path
from typing import TYPE_CHECKING, Any

from . import ci, gitutil, landing, ship, tickets, trust, worktrees
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
BATCH_STAGE = "batch-ci"  # the stage name of a batch's question to the owner
LOG_EXCERPT = 1500  # characters of the failing log in the question
MACOS_PATHS = ".github/scripts/macos-paths.sh"  # the one list of macOS-specific paths (#389); read from the batch's own worktree
MACOS_GATE_TITLE = "macOS gate"  # the display_title of the dispatched macos-gate.yml run (its `title` input)


def macos_relevant(wt: Path, files: list[str]) -> bool:
    """Does a change to `files` touch anything macOS-specific? Asked of .github/scripts/macos-paths.sh in the worktree, the list PRs
    use too. A worktree without the script, or one that fails, cannot say: then yes."""
    script = wt / MACOS_PATHS
    if not script.exists() or not files:
        return True
    stdin = "".join(f"{f}\n" for f in files)  # the script's `read` drops a last line that has no newline
    done = subprocess.run(["bash", str(script)], input=stdin, capture_output=True, text=True, cwd=wt, check=False)
    return done.returncode != 0 or done.stdout.strip().splitlines()[-1:] != ["false"]


def parse_answer(text: str) -> tuple[str, bool, bool]:
    """The owner's reply to a red batch: (`bypass`|`fix`, file a follow-up, recognised). The first of the two words wins; "no follow-up"
    (or "without follow-up") declines the follow-up ticket. Text with neither word is `fix`, the recommended and safe choice."""
    low = text.lower()
    m = re.search(r"\b(bypass|fix)\b", low)
    followup = re.search(r"\b(?:no|without)\s+follow[- ]?up", low) is None
    return (m.group(1) if m else "fix", followup, m is not None)


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
    if len(db.running_batches()) >= config.batch_parallel:
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
        self._drivers: dict[int, asyncio.Task[None]] = {}  # one task per active batch, driving it through CI and landing
        self._wake = asyncio.Event()  # set when a driver ends, so the loop forms the next batch at once
        self._asked_polled: dict[int, float] = {}  # when each asking batch's anchor issue was last read for an answer
        self._git_lock = threading.Lock()  # fetches and worktree add/remove from two batches' threads must not race on the shared repo

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
            elif others := [t for t in self._beside.values() if not t.done()]:
                await asyncio.wait(others)  # a conflicted ticket's rejoin
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
        did = await self._poll_asking()
        did = self._start_drivers() or did
        active = eng.db.active_batches()  # an asking batch counts for the files it may still land, not for a slot
        if len(eng.db.running_batches()) >= max(1, eng.config.batch_parallel):
            return did
        flagged = [t.number for t in eng.db.tickets(("ready",))
                   if eng.db.batch_of(t.number) is None and ship.land_now(eng, t.number)]
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

    async def _poll_asking(self) -> bool:
        """For each batch waiting on the owner: make sure the question was posted (a restart may have cut that short), and read the
        owner's reply off the anchor's issue, at most every `ci_poll_s`. True when something happened."""
        eng = self.eng
        did = False
        for b in eng.db.active_batches():
            bid = int(b["id"])
            q = eng.db.batch_question(bid)
            if b["state"] != "asking" or q is None or (bid in self._drivers and not self._drivers[bid].done()):
                continue
            try:
                if q["comment_id"] is None:
                    await asyncio.to_thread(self._announce_question, bid)
                    did = True
                elif q["answer"] is None and eng.clock() - self._asked_polled.get(bid, float("-inf")) >= eng.config.ci_poll_s:
                    self._asked_polled[bid] = eng.clock()
                    answers = trust.accepted_answers(await asyncio.to_thread(eng.gh.comments, int(q["ticket"])),
                                                     int(q["comment_id"]), eng.config.owner)
                    if answers:
                        eng.db.answer_question(int(q["id"]), answers[-1]["body"], "owner")
                        eng.db.intervention(int(q["ticket"]), "answer", BATCH_STAGE)
                        eng.notifier.clear("needs-input", int(q["ticket"]))
                        did = True
            except GitHubError as exc:
                eng.db.event("batch-question-poll-failed", None, batch=bid, error=str(exc)[:200])
        return did

    def _start_drivers(self) -> bool:
        started = False
        for b in self.eng.db.active_batches():
            bid = int(b["id"])
            if bid in self._drivers and not self._drivers[bid].done():
                continue
            if b["state"] == "asking" and (q := self.eng.db.batch_question(bid)) is not None and q["answer"] is None:
                continue  # waiting for the owner
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
    def _pick(self, paths: dict[int, frozenset[str] | None] | None = None) -> list[int]:
        """The tickets for the next batch. With another batch in flight, only those sharing no file with any of its members:
        `paths` (from `_paths_of`, computed off the event loop) says which files each ticket changes."""
        eng = self.eng
        # a ticket whose catch-up is still running stays out: landing it would delete the worktree the catch-up is working in
        ready = [t for t in eng.db.tickets(("ready",))
                 if eng.db.batch_of(t.number) is None and t.number not in self._beside]
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
        if not built.merged:  # nothing to publish: the empty batch goes at once, the catch-ups run beside the train
            self._start_catch_ups(built.catch_up)
            await asyncio.to_thread(self._abandon, bid, "nothing merged cleanly")
            return
        try:
            await asyncio.to_thread(self._publish, bid, built, base)
        except (GitHubError, RuntimeError) as exc:
            await asyncio.to_thread(self._abandon, bid, f"could not publish the batch: {exc}")
            await eng.sleep(BACKOFF_S)
            return
        self._start_catch_ups(built.catch_up)  # conflicts with develop itself: the CONFLICT stage runs beside the batch

    def _start_catch_ups(self, numbers: list[int]) -> None:
        """Each conflicted ticket's catch-up as a task of its own; the ticket is back in the queue when it is done."""
        for n in numbers:
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
        if batch["state"] == "asking":  # its question was answered (a batch still waiting is not driven)
            await self._apply_answer(bid)
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

    def _batch_features(self, members: list[int]) -> list[str]:
        """The Gherkin features the batch must prove: the ordered union over the members that carry neither skip-features nor
        land-now. Empty means the batch dispatches no feature run."""
        eng = self.eng
        out: list[str] = []
        for n in members:
            t = eng.db.ticket(n)
            if t is None or ship.skip_features(eng, n) or ship.land_now(eng, n):
                continue
            out += [f for f in tickets.gherkin_features(t.body, t.plan) if f not in out]
        return out

    async def _feature_step(self, bid: int, head: str, features: list[str]) -> tuple[str, ci.Verdict | None]:
        """One look at the batch's feature run, dispatching it first when this head has none. ('pass'|'pending'|'fail'|'abandon', verdict).

        The run is on the batch branch (already on origin), keyed `batch<bid>` in kv: gherkin_run (sha, title, time), gherkin_reran,
        and gherkin_ok (the head sha it passed on)."""
        eng = self.eng
        key = f"batch{bid}"
        if eng.db.get(f"gherkin_ok:{key}") == head:
            return ("pass", None)
        title = tickets.feature_title(features)
        rec = json.loads(eng.db.get(f"gherkin_run:{key}") or "null")
        try:
            if not rec or rec["sha"] != head or rec["title"] != title:
                await asyncio.to_thread(ship.dispatch_features_on, eng, key, batch_branch(bid), head, title, features)
                eng.db.put(f"gherkin_err:{key}", None)
                return ("pending", None)
            reran = {tuple(k) for k in json.loads(eng.db.get(f"gherkin_reran:{key}") or "[]")}
            verdict = await asyncio.to_thread(ship.feature_verdict_on, eng, batch_branch(bid), head, title, float(rec["at"]) - 60, reran)
        except (GitHubError, RuntimeError) as exc:
            message = str(exc)
            eng.db.event("gherkin-poll-failed", None, batch=bid, error=message[:200])
            err = json.loads(eng.db.get(f"gherkin_err:{key}") or "null")
            count = err["count"] + 1 if err and err["sha"] == head and err["error"] == message else 1
            eng.db.put(f"gherkin_err:{key}", json.dumps({"sha": head, "error": message, "count": count}))
            if count >= ship.GATE_ERROR_LIMIT and not ship._is_transient(message):  # pyright: ignore[reportPrivateUsage]
                eng.db.put(f"gherkin_err:{key}", None)
                return ("abandon", None)
            return ("pending", None)
        eng.db.put(f"gherkin_err:{key}", None)
        if verdict is None:
            if eng.clock() - float(rec["at"]) > ship.FEATURE_RUN_WAIT_S:  # dispatched, but no such run ever showed up: dispatch again
                eng.db.put(f"gherkin_run:{key}", None)
            return ("pending", None)
        if verdict.kind == "rerun":
            ready = await asyncio.to_thread(ship._rerun, eng, None, [j for j in verdict.rerun if j.run_done])  # pyright: ignore[reportPrivateUsage]
            reran |= {j.key for j in ready}
            eng.db.put(f"gherkin_reran:{key}", json.dumps(sorted(reran)))
            return ("pending", None)
        if verdict.kind == "pass":
            eng.db.put(f"gherkin_ok:{key}", head)
            eng.db.event("gherkin-proven", None, batch=bid, sha=head, features=features)
            return ("pass", verdict)
        return ("fail" if verdict.kind == "fail" else "pending", verdict)

    def _macos_needed(self, bid: int, head: str, members: list[int]) -> bool:
        """Does the batch owe the macOS gate? Not when a member is land-now or skip-features, nor when no file it changes against develop
        is macOS-specific (macos_relevant). Worker thread."""
        eng = self.eng
        if any(ship.land_now(eng, n) or ship.skip_features(eng, n) for n in members):
            return False
        wt = batch_worktree(eng.repo, bid)
        try:
            mb = gitutil.git(wt, "merge-base", f"origin/{eng.config.base_branch}", head).strip()
            files = [p for p in gitutil.git(wt, "diff", "--name-only", "--no-renames", f"{mb}..{head}").splitlines() if p]
        except RuntimeError:
            return True
        return macos_relevant(wt, files)

    async def _macos_step(self, bid: int, head: str, members: list[int]) -> tuple[str, ci.Verdict | None]:
        """One look at the batch's macOS gate run, dispatching it first when this head has none: macos-gate.yml on the batch branch, once
        per head. ('pass'|'pending'|'fail'|'abandon', verdict). kv `macos_run:batch<id>` (sha, title, time), `macos_reran:`, `macos_ok:`
        (the head it passed on), `macos_note:` (the note for the PR when it passed without a runner), `macos_need:` (sha, bool).

        Red goes to the normal red handling. Jobs that never got a runner are rerun once; still without one after `macos_gate_wait_s`,
        the batch lands with a note, or waits (and dispatches the gate again each wait) when `macos_gate_hard` is on."""
        eng = self.eng
        key = f"batch{bid}"
        if eng.db.get(f"macos_ok:{key}") == head:
            return ("pass", None)
        need = json.loads(eng.db.get(f"macos_need:{key}") or "null")
        if not need or need["sha"] != head:
            need = {"sha": head, "need": await asyncio.to_thread(self._macos_needed, bid, head, members)}
            eng.db.put(f"macos_need:{key}", json.dumps(need))
        if not need["need"]:
            return ("pass", None)
        rec = json.loads(eng.db.get(f"macos_run:{key}") or "null")
        try:
            if not rec or rec["sha"] != head:
                await asyncio.to_thread(ship.dispatch_macos_gate_on, eng, key, batch_branch(bid), head, MACOS_GATE_TITLE)
                eng.db.put(f"macos_err:{key}", None)
                return ("pending", None)
            reran = {tuple(k) for k in json.loads(eng.db.get(f"macos_reran:{key}") or "[]")}
            judge = partial(ci.judge_macos_gate, waited_s=eng.clock() - float(rec["at"]), wait_s=eng.config.macos_gate_wait_s,
                            hard=eng.config.macos_gate_hard)
            verdict = await asyncio.to_thread(ship.feature_verdict_on, eng, batch_branch(bid), head, rec["title"], float(rec["at"]) - 60,
                                              reran, ship.MACOS_GATE_FILE, judge)
        except (GitHubError, RuntimeError) as exc:
            message = str(exc)
            eng.db.event("macos-gate-poll-failed", None, batch=bid, error=message[:200])
            err = json.loads(eng.db.get(f"macos_err:{key}") or "null")
            count = err["count"] + 1 if err and err["sha"] == head and err["error"] == message else 1
            eng.db.put(f"macos_err:{key}", json.dumps({"sha": head, "error": message, "count": count}))
            if count >= ship.GATE_ERROR_LIMIT and not ship._is_transient(message):  # pyright: ignore[reportPrivateUsage]
                eng.db.put(f"macos_err:{key}", None)
                return ("abandon", None)
            return ("pending", None)
        eng.db.put(f"macos_err:{key}", None)
        if verdict is None:
            if eng.clock() - float(rec["at"]) > ship.FEATURE_RUN_WAIT_S:  # dispatched, but no such run ever showed up: dispatch again
                eng.db.put(f"macos_run:{key}", None)
            return ("pending", None)
        if verdict.kind == "rerun":
            ready = await asyncio.to_thread(ship._rerun, eng, None, [j for j in verdict.rerun if j.run_done])  # pyright: ignore[reportPrivateUsage]
            reran |= {j.key for j in ready}
            eng.db.put(f"macos_reran:{key}", json.dumps(sorted(reran)))
            return ("pending", None)
        if verdict.warnings:  # macOS jobs without a runner: the run is of no further use, and its queued jobs hold the scarce runners
            await asyncio.to_thread(self._cancel_runs, [j.run_id for j in verdict.warnings if not j.run_done])
            names = ", ".join(f"{j.workflow}/{j.job}" for j in verdict.warnings)
            if verdict.kind == "pending":  # macos_gate_hard: hold, and dispatch the gate again once a whole wait has passed
                eng.db.event("macos-gate-held", None, batch=bid, sha=head, jobs=names)
                if eng.clock() - float(rec["at"]) > eng.config.macos_gate_wait_s:
                    eng.db.put(f"macos_run:{key}", None)
            else:
                eng.db.event("macos-gate-no-runner", None, batch=bid, sha=head, jobs=names)
                eng.db.put(f"macos_note:{key}", f"macOS gate: no macOS runner within {eng.config.macos_gate_wait_s / 3600:g} h "
                           f"(after one rerun), landed without it: {names}")
        if verdict.kind == "pass":
            eng.db.put(f"macos_ok:{key}", head)
            eng.db.event("macos-gate-proven", None, batch=bid, sha=head)
            return ("pass", verdict)
        return ("fail" if verdict.kind == "fail" else "pending", verdict)

    def _cancel_runs(self, run_ids: list[int]) -> None:
        for run_id in dict.fromkeys(run_ids):
            try:
                self.eng.gh.cancel_run(run_id)
            except GitHubError as exc:  # already finished
                self.eng.db.event("macos-gate-cancel-refused", None, run=run_id, error=str(exc)[:200])

    async def _ci(self, bid: int) -> tuple[str, ci.Verdict | str]:
        """Judge the batch's CI, and its Gherkin feature run beside it, until both pass, one is red, or the batch must be given up on."""
        eng = self.eng
        while True:
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
            head = str(batch["head_sha"])
            features = self._batch_features(members)
            feature_state: tuple[str, ci.Verdict | None] = ("pass", None)
            if features:  # dispatched on the first pass, then judged beside the normal CI
                feature_state = await self._feature_step(bid, head, features)
                if feature_state[0] == "abandon":
                    return ("abandon", f"the Gherkin feature run could not be dispatched or polled {ship.GATE_ERROR_LIMIT} times in a row")
            reran = {tuple(k) for k in json.loads(eng.db.get(f"reran:batch{bid}") or "[]")}
            keep = (*((tickets.feature_title(features),) if features else ()), MACOS_GATE_TITLE)  # runs the step owns, not the PR judge
            bypassed = self._bypassed(bid)
            try:
                jobs, verdict = await asyncio.to_thread(ship._judge_jobs, eng, f"batch{bid}", head, reran, keep, bypassed)  # pyright: ignore[reportPrivateUsage]
            except GitHubError as exc:
                eng.db.event("ci-poll-failed", None, batch=bid, error=str(exc)[:200])
                await eng.sleep(eng.config.ci_poll_s)
                continue
            eng.db.record_ci(0, head, verdict.kind, {"batch": bid, "reason": verdict.reason})
            if verdict.kind == "fail":
                return ("red", verdict)
            used = {j.key for j in jobs if j.red and j.key in bypassed}  # the bypassed jobs that really are red at this head
            if feature_state[0] == "fail" and feature_state[1] is not None:
                blocking = {j.key for j in feature_state[1].blocking}
                if not blocking or not blocking <= bypassed:
                    return ("red", feature_state[1])
                used |= blocking
                feature_state = ("pass", None)
            age = eng.clock() - float(eng.db.get(f"pushed_at:batch{bid}") or eng.clock())
            if verdict.kind == "rerun":
                ready = await asyncio.to_thread(ship._rerun, eng, None, [j for j in verdict.rerun if j.run_done])  # pyright: ignore[reportPrivateUsage]
                reran |= {j.key for j in ready}
                eng.db.put(f"reran:batch{bid}", json.dumps(sorted(reran)))
                await eng.sleep(eng.config.ci_poll_s)
            elif verdict.kind == "pending" or feature_state[0] != "pass":
                await eng.sleep(ci.poll_delay(age, eng.config.ci_poll_s))
            else:
                macos_state = await self._macos_step(bid, head, members)
                if macos_state[0] == "abandon":
                    return ("abandon", f"the macOS gate could not be dispatched or polled {ship.GATE_ERROR_LIMIT} times in a row")
                if macos_state[0] == "fail" and macos_state[1] is not None:
                    blocking = {j.key for j in macos_state[1].blocking}
                    if not blocking or not blocking <= bypassed:
                        return ("red", macos_state[1])
                    used |= blocking
                elif macos_state[0] == "pending":
                    await eng.sleep(ci.poll_delay(age, eng.config.ci_poll_s))
                    continue
                notes = ship.pass_notes(eng, verdict, batch=bid)
                if macos_note := eng.db.get(f"macos_note:batch{bid}"):
                    notes.append(macos_note)
                self._save_bypass(bid, used)
                notes += [f"bypassed by the owner (batch #{bid}): {w}/{j}" for w, j in sorted(used)]
                return ("pass", "\n".join(f"- {n}" for n in notes))

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
        eng.db.put(f"gherkin_reran:batch{bid}", None)  # the old head's feature run is void; _ci dispatches one for the new head
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
        self._report_bypass(bid)
        batch = eng.db.batch(bid)
        if batch and batch["branch"]:
            eng.gh.delete_branch(str(batch["branch"]))
        self._remove_worktree(bid)
        eng.db.put(f"bypass:batch{bid}", None)
        for prefix in ("gherkin_run", "gherkin_ok", "gherkin_reran", "gherkin_err", "bypass_noted", "bypass_filed"):
            eng.db.put(f"{prefix}:batch{bid}", None)
        eng.db.batch_update(bid, state="landed", ended=eng.clock())

    def _report_bypass(self, bid: int) -> None:
        """A batch that landed past failing checks: say so on each member's issue and file a proposed follow-up ticket, unless the owner
        declined it. Safe to run twice (each step has a marker); a refused filing is an event, never a reason to hold the landing."""
        eng = self.eng
        rec = self._bypass_record(bid)
        batch = eng.db.batch(bid)
        if not rec or not rec["jobs"] or batch is None:
            return
        jobs = [f"{w}/{j}" for w, j in rec["jobs"]]
        members = eng.db.batch_members(bid)
        listing = ", ".join(f"#{n}" for n in members)
        if not eng.db.get(f"bypass_noted:batch{bid}"):
            eng.db.put(f"bypass_noted:batch{bid}", "1")
            for n in members:
                try:
                    eng.gh.comment(n, f"{trust.marker('bypass', bid)}\nLanded in batch #{bid} (PR #{batch['pr_number']}) with failing "
                                      f"check(s) bypassed by the owner: {', '.join(jobs)}.")
                except GitHubError as exc:
                    eng.db.event("bypass-comment-failed", n, batch=bid, error=str(exc)[:200])
        if not rec["followup"] or eng.db.get(f"bypass_filed:batch{bid}"):
            return
        eng.db.put(f"bypass_filed:batch{bid}", "1")
        title = f"Fix {', '.join(jobs)}: bypassed when batch #{bid} landed"
        body = (f"## Goal\nMake {', '.join(jobs)} pass again.\n\n"
                f"## Context\nBatch #{bid} (PR #{batch['pr_number']}; tickets {listing}) went red on {', '.join(jobs)} and the owner chose "
                "to land it anyway. The failure is on develop now. Find what breaks it and fix it.\n\n"
                f"## Acceptance criteria\n- A1: {', '.join(jobs)} passes on develop — check: the CI run of that job after the fix\n\n"
                f"## Tests\n- ci: {', '.join(jobs)} — shows: A1\n\n"
                "## Out of scope\nOther failing checks, and anything the batch's tickets changed beyond what the failure needs.")
        try:
            number = tickets.file_ticket(eng.gh, title, body, propose=True, by=f"landing train batch #{bid}", priority="p1")
        except (tickets.FilingError, GitHubError) as exc:
            eng.db.event("bypass-followup-failed", None, batch=bid, error=str(exc)[:300])
            return
        eng.db.event("bypass-followup-filed", None, batch=bid, issue=number, jobs=jobs)

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
        """A red batch is held and the owner asked: `fix` (split it, CI-FIX the culprit) or `bypass` (land past the failing job).
        Only this batch waits: it takes no slot, its members stay in `ci`, and nothing is parked."""
        eng = self.eng
        members = eng.db.batch_members(bid)
        if not members or not verdict.blocking:  # nothing to name or to bypass
            await self._give_up_red(bid, verdict)
            return
        anchor = members[0]  # the questions table is per ticket: the batch's question sits under its first member
        jobs = [f"{j.workflow}/{j.job}" for j in verdict.blocking]
        excerpt = await asyncio.to_thread(self._log_excerpt, verdict)
        names = "\n".join(f"- #{n} {t.title}" for n in members if (t := eng.db.ticket(n)) is not None)
        question = f"Batch #{bid} is red on {', '.join(jobs)}: fix it before landing, or bypass the failing check and land?"
        why = (f"{verdict.reason}\n\nBatch #{bid} members:\n{names}\n\nFailing log (tail):\n```\n{excerpt}\n```\n\n"
               "`fix` splits the batch in half and tries the halves until the culprit is alone, then CI-FIX. `bypass` lands the batch "
               "with these checks noted in the PR body and files a proposed follow-up ticket for them (add \"no follow-up\" to skip it).")
        payload: dict[str, Any] = {
            "question": question, "why": why, "options": ["fix", "bypass"], "recommendation": "fix", "batch": bid, "jobs": jobs,
            "reason": verdict.reason,
            "blocking": [{"workflow": j.workflow, "job": j.job, "run_id": j.run_id, "conclusion": j.conclusion} for j in verdict.blocking]}
        qid = eng.db.add_question(anchor, BATCH_STAGE, question, payload)
        eng.db.batch_update(bid, state="asking", question=qid)
        eng.db.event("batch-asking", anchor, batch=bid, jobs=jobs)
        await asyncio.to_thread(self._announce_question, bid)

    def _log_excerpt(self, verdict: ci.Verdict) -> str:
        try:
            return self.eng.gh.failed_log(verdict.blocking[0].run_id)[-LOG_EXCERPT:]
        except GitHubError as exc:
            return f"(could not fetch the log: {exc})"

    def _announce_question(self, bid: int) -> None:
        """Tell the owner: the question on the anchor's issue (once: its comment id is the proof), the alert and the announcement."""
        eng = self.eng
        q = eng.db.batch_question(bid)
        if q is None:
            return
        anchor = int(q["ticket"])
        if q["comment_id"] is None:
            payload: dict[str, Any] = json.loads(q["payload"] or "{}")
            eng.post_question(anchor, BATCH_STAGE, int(q["id"]), payload)
        t = eng.db.ticket(anchor)
        eng.notifier.alert("needs-input", anchor, f"batch #{bid} is red ({q['text'][:160]}): fix or bypass? "
                                                  f"#{anchor} {t.title if t else ''}")
        eng.announce("attention", anchor)

    async def _apply_answer(self, bid: int) -> None:
        eng = self.eng
        q = eng.db.batch_question(bid)
        text = str(q["answer"] or "") if q else ""
        choice, followup, recognised = parse_answer(text)
        payload: dict[str, Any] = json.loads(q["payload"] or "{}") if q else {}
        anchor = int(q["ticket"]) if q else None
        if anchor is not None:
            eng.notifier.clear("needs-input", anchor)
        eng.db.event("batch-answered", anchor, batch=bid, choice=choice, followup=followup, recognised=recognised)
        if choice == "bypass":
            keys = {(str(b["workflow"]), str(b["job"])) for b in payload.get("blocking", [])}
            have = self._bypass_record(bid) or {"jobs": [], "followup": True}
            jobs = sorted({(str(w), str(j)) for w, j in have["jobs"]} | keys)
            eng.db.put(f"bypass:batch{bid}", json.dumps({"jobs": jobs, "followup": bool(have["followup"]) and followup}))
            eng.db.batch_update(bid, state="ci")  # the driver that restarts judges it again, with these jobs bypassed
            return
        blocking = [ci.Job(str(b["workflow"]), str(b["job"]), "completed", b.get("conclusion"), int(b["run_id"]))
                    for b in payload.get("blocking", [])]
        await self._give_up_red(bid, ci.Verdict("fail", str(payload.get("reason") or "CI red"), blocking=blocking))

    def _bypass_record(self, bid: int) -> dict[str, Any] | None:
        """What the owner chose to land past, `{"jobs": [[workflow, job], ...], "followup": bool}`; None when nothing is bypassed."""
        return json.loads(self.eng.db.get(f"bypass:batch{bid}") or "null")

    def _bypassed(self, bid: int) -> frozenset[tuple[str, str]]:
        rec = self._bypass_record(bid)
        return frozenset((str(w), str(j)) for w, j in rec["jobs"]) if rec else frozenset()

    def _save_bypass(self, bid: int, used: set[tuple[str, str]]) -> None:
        """At the passing head, keep only the bypassed jobs that really were red there (a catch-up may have cured one)."""
        rec = self._bypass_record(bid)
        if rec is None:
            return
        self.eng.db.put(f"bypass:batch{bid}", json.dumps({"jobs": sorted(used), "followup": rec["followup"]}) if used else None)

    async def _give_up_red(self, bid: int, verdict: ci.Verdict) -> None:
        """The `fix` path: split the batch in half and try the halves, down to one ticket, which gets CI-FIX and rejoins the queue."""
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
        if t is not None and t.state == "ready" and verdict.blocking:
            # one ticket and still red: it is the culprit, so it gets the CI-FIX stage and rejoins the queue
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
