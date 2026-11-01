"""starpiped: one asyncio process (plan §5, §14). Supervised tasks: intake poller, scheduler, local API."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
from collections.abc import Awaitable, Callable
from datetime import datetime
from pathlib import Path
from typing import Any, cast

from aiohttp import web

from . import digest as digest_mod
from . import gitutil, heavy, load, nightly, selfupdate, ship, tickets, train, trust, watch, worktrees
from .config import Config, home, token_path
from .db import ACTIVE_STATES, POST_STATES, Database, Ticket
from .engine import RETRY_STATE, STAGE_STATE, Engine
from .github import GitHubError

log = logging.getLogger("starpiped")

ISSUE_URL = re.compile(r"\Ahttps://github\.com/(?P<owner>[^/\s]+)/(?P<repo>[^/\s]+)/(?P<kind>issues|pull)/(?P<n>\d+)/?\Z")


def api_token() -> str:
    path = token_path()
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(secrets.token_urlsafe(32))
        path.chmod(0o600)
    return path.read_text().strip()


def activity(db: Database, t: Ticket, now: float | None = None, mode: str = "batch") -> str:
    """The one-line "what is it doing" the CLI and monitor both show (computed here, never by a client)."""
    now = now or time.time()
    stages = db.stages(t.number)
    last = stages[-1] if stages else None
    if t.state == "needs-input":
        q = db.open_question(t.number)
        return f"needs you · asked {int((now - q['asked_at']) / 60)}m ago" if q else "needs you"
    if t.state in ("failed", "cancelled", "closed", "paused") and t.park_reason:
        return f"{t.state} · {t.park_reason}"
    wait = db.get(f"llm_wait:{t.number}")
    if wait and t.state in ACTIVE_STATES and (last is None or last["ended"] is not None):
        return f"{t.state} · waiting to start: {wait}"
    if last and last["ended"] is None:
        spent = int((now - last["started"]) / 60)
        return f"{t.state} · attempt {last['attempt']}/3 · {spent}m" + (
            f" (+{int(last['lock_wait_s'] / 60)}m lock wait)" if last["lock_wait_s"] >= 60 else "")
    if t.state in ("ci", "landing") and (batch := db.batch_of(t.number)) is not None:
        return f"CI · batch #{batch} ({len(db.batch_members(batch))} tickets together)"
    if t.state == "queued" and (blockers := db.open_blockers(t.number)):
        return "queued: " + ", ".join(f"#{b}" for b in blockers)
    if t.state == "ready":
        return "ready · waiting for the next batch" if mode == "batch" else "ready to publish"
    return t.state


LAND_NOW_STATES = ("ready", "ci", "landing")
MAX_ACTIVE_CAP = 6
GROUPS = ("needs_you", "running", "waiting", "queued", "landed_today", "failed")


def group_of(t: Ticket, holding_or_waiting_lock: bool, now: float, updated: float) -> str | None:
    """Which sidebar group a ticket belongs in (computed here, never by a client). None: not shown."""
    if t.state == "needs-input":
        return "needs_you"
    if t.state in ACTIVE_STATES:
        return "waiting" if holding_or_waiting_lock else "running"
    if t.state in ("ready", "ci", "landing", "paused"):
        return "waiting"
    if t.state == "queued":
        return "queued"
    if t.state == "landed":
        return "landed_today" if now - updated < 24 * 3600 else None
    if t.state in ("failed", "cancelled"):
        return "failed" if now - updated < 7 * 24 * 3600 else None
    return None


class Daemon:
    def __init__(self, engine: Engine, config: Config, token: str | None = None) -> None:
        self.engine, self.config, self.db = engine, config, engine.db
        self.token = token or api_token()
        self.tasks: dict[int, asyncio.Task[None]] = {}
        self.started = time.time()
        self.last_poll: float | None = None
        self.last_error: str = ""
        self.watch = watch.Watch()
        self._runtime: dict[str, object] = {}
        self.nightly_task: asyncio.Task[int] | None = None
        self.train = train.Train(engine)
        self.cpu = load.CpuMeter(window_s=float(config.cpu_window_s))
        engine.cpu = self.cpu.average
        self._update_lock = threading.Lock()
        self._blocker_titles: dict[int, str] = {}  # GitHub titles of blockers, fetched once per daemon
        self.exit: Callable[[int], None] = hard_exit  # replaced in tests

    # supervision ---------------------------------------------------------------------------------------------------
    def reconcile(self) -> None:
        """Mark stages that were running when the daemon died; drive() resumes them by session id."""
        for s in self.db.running_stages():
            self.db.end_stage(s["id"], "interrupted", detail="daemon restarted")
        self.engine.parked.clear()
        self.db.put("self_update_pending", None)  # a restart is how an update completes; whatever is still wanted is re-staged

    async def supervise(self, name: str, body: Callable[[], Awaitable[None]], delay: float = 5.0) -> None:
        while True:
            try:
                await body()
                return
            except asyncio.CancelledError:
                raise
            except Exception:  # a task that dies is logged and restarted, never fatal
                log.exception("task %s died; restarting", name)
                self.last_error = f"{name} died at {time.ctime()}"
                await asyncio.sleep(delay)

    # loops ---------------------------------------------------------------------------------------------------------
    async def poll_once(self) -> None:
        try:
            await asyncio.to_thread(self.engine.sync_issues)
            await asyncio.to_thread(self.engine.close_due)
            await asyncio.to_thread(ship.watch_develop, self.engine)
            self.last_poll = time.time()
            await self.update_step()
        except GitHubError as exc:
            self.last_error = f"github: {exc}"
            log.warning("poll failed: %s", exc)

    async def poller(self) -> None:
        while True:
            await self.poll_once()
            await asyncio.sleep(self.config.poll_s)

    def schedule_once(self) -> None:
        for t in self.db.tickets((*ACTIVE_STATES, *POST_STATES)):  # resume after a restart, and after a RETRY or an answer
            self._start(t.number)
        while (t := self.engine.claimable()) is not None:
            self._start(t.number)  # drive() claims it; one claim per tick keeps the active cap honest
            break

    def _start(self, number: int) -> None:
        task = self.tasks.get(number)
        if task and not task.done():
            return
        self.tasks[number] = asyncio.create_task(self._drive(number))

    async def _drive(self, number: int) -> None:
        try:
            await self.engine.drive(number)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            log.exception("ticket %s crashed the engine", number)
            t = self.db.ticket(number)
            if t:
                self.engine.park(t, f"internal error: {type(exc).__name__}: {exc}")

    # nightly and digest -----------------------------------------------------------------------------------------------
    def make_nightly(self) -> nightly.Nightly:
        return nightly.Nightly(self.db, self.config, self.engine.gh, self.engine.notifier, self.engine.repo,
                               fetch_ref=lambda _repo: ship.fetch(self.engine, self.engine.repo))

    def start_nightly(self, opts: nightly.Options) -> int | None:
        """Start a nightly in the background; None when one is already running."""
        if self.nightly_task and not self.nightly_task.done():
            return None
        self.nightly_task = asyncio.create_task(asyncio.to_thread(self.make_nightly().run, opts))
        return 1

    async def nightly_loop(self) -> None:
        while True:
            now = datetime.now()
            if (self.config.nightly_enabled and nightly.due(now, self.db.get("nightly_last_day"), self.config.nightly_start)
                    and self.start_nightly(nightly.Options(ui=self.config.nightly_ui))):
                self.db.put("nightly_last_day", now.strftime("%Y-%m-%d"))
            await asyncio.sleep(60)

    def self_update_once(self, plist: Path | None = None, sync: selfupdate.Sync | None = None,
                         test: Callable[[Path], tuple[bool, str]] | None = None) -> str | None:
        """Notice newer pipeline/ code on origin/develop, stage and smoke-check it, then swap once nothing is running.

        Returns None (nothing to do or not allowed now), "failed", "pending" (staged and good, waiting for stages to finish) or
        "swapped" (the caller exits so launchd restarts the daemon on the new runtime). A staged version that fails its smoke check
        is recorded against its sha and never retried; the running version stays."""
        plist = plist or Path.home() / "Library" / "LaunchAgents" / f"{selfupdate.LABEL}.plist"
        current = selfupdate.link("current")
        if not self.config.auto_self_update or current is None:
            return None  # off, or running from a checkout: never update a tree the owner is working in
        if self.nightly_task and not self.nightly_task.done():
            return None  # no staging, no swap: the nightly outlives a restart badly
        if not self._update_lock.acquire(blocking=False):
            return None
        try:
            have = selfupdate.runtime_sha(current)
            if have is None:
                return None
            try:
                target = selfupdate.fetch_target(self.engine.repo, self.config)
            except (RuntimeError, subprocess.SubprocessError, OSError) as exc:
                log.warning("self-update: fetch failed: %s", exc)
                return None
            failed = json.loads(self.db.get("self_update_failed") or "{}")
            if selfupdate.pipeline_commits_behind(self.engine.repo, have, target) == 0:
                self.db.put("self_update_pending", None)
                self.db.put("self_update_failed", None)
                return None
            if failed.get("sha") == target:
                self.db.put("self_update_pending", None)
                return None
            if self.db.get("self_update_pending") != target:
                self.db.put("self_update_failed", None)  # a newer sha than the one that failed: it gets its own try
                if not self._stage_update(target, sync or selfupdate.real_sync, test or selfupdate.smoke_check):
                    return "failed"
            if self.db.running_stages():
                return "pending"
            selfupdate.switch(selfupdate.runtime_dir(target), plist, restart=False)
            self.db.event("self-update", None, old=have, new=target)
            self.db.put("self_update_pending", None)
            self.db.put("self_update_failed", None)
            selfupdate.prune()
            return "swapped"
        finally:
            self._update_lock.release()

    def _stage_update(self, target: str, sync: selfupdate.Sync, test: Callable[[Path], tuple[bool, str]]) -> bool:
        """Build `target` beside the running runtime and smoke-check it. On success mark the update pending (which holds new work)."""
        try:
            rt = selfupdate.build(self.engine.repo, target, sync)
            ok, output = test(rt)
        except (RuntimeError, subprocess.SubprocessError, OSError) as exc:
            ok, output = False, getattr(exc, "stderr", None) or str(exc)
        if ok:
            self.db.put("self_update_pending", target)
            return True
        shutil.rmtree(selfupdate.runtime_dir(target), ignore_errors=True)
        output = str(output)[-800:]
        self.db.put("self_update_failed", json.dumps({"sha": target, "output": output, "at": time.time()}))
        self.db.put("self_update_pending", None)
        self.db.event("self-update-failed", None, sha=target, output=output)
        self.engine.notifier.alert("self-update-failed", None, f"self-update to {target[:10]} failed: {output}")
        return False

    async def update_step(self, plist: Path | None = None, sync: selfupdate.Sync | None = None,
                          test: Callable[[Path], tuple[bool, str]] | None = None) -> None:
        if await asyncio.to_thread(self.self_update_once, plist, sync, test) == "swapped":
            log.info("self-update: swapped the runtime; exiting for launchd to restart on it")
            self.exit(0)

    async def update_loop(self) -> None:
        while True:
            await self.update_step()
            await asyncio.sleep(30)

    def write_digest(self, now: float | None = None) -> Path:
        from .checks import ledger

        now = now or time.time()
        folder = home() / "digests"
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"{datetime.fromtimestamp(now):%Y-%m-%d}.md"
        path.write_text(digest_mod.build(self.db, now, 7, ledger.ledger_path()).render())
        self.db.event("digest", None, path=str(path))
        return path

    async def digest_loop(self) -> None:
        while True:
            now = datetime.now()
            if (now.weekday() == self.config.digest_weekday and now.hour >= self.config.digest_hour
                    and self.db.get("digest_last_day") != now.strftime("%Y-%m-%d")):
                await asyncio.to_thread(self.write_digest)
                self.db.put("digest_last_day", now.strftime("%Y-%m-%d"))
            await asyncio.sleep(600)

    def watch_targets(self) -> list[watch.Target]:
        """Stage sessions (this process's `claude` children) and pipeline-owned heavy jobs. Never an interactive holder."""
        import psutil

        state = heavy.status()
        waiting = frozenset(w.pid for w in state.queue)
        targets: list[watch.Target] = []
        for child in psutil.Process().children():
            try:
                if "_bundled/claude" not in " ".join(child.cmdline()):
                    continue
                ticket = child.environ().get("STARPIPE_TICKET", "?")
            except psutil.Error:
                continue
            folder = home() / "tickets" / ticket / "transcripts"

            def newest(folder: Path = folder) -> float:
                return max((f.stat().st_mtime for f in folder.glob("*.jsonl")), default=0.0)

            targets.append(watch.Target(f"stage:{ticket}", child.pid, newest, waiting))
        for h in state.holders:
            if h.ticket:  # an empty ticket is an interactive caller: not ours to kill
                targets.append(watch.Target(f"heavy:{h.pid}", h.pid, waiting_pids=waiting))
        return targets

    def watch_once(self) -> list[watch.Action]:
        actions = self.watch.tick(self.watch_targets())
        for a in actions:
            ticket = int(a.label.split(":")[1]) if a.label.startswith("stage:") and a.label[6:].isdigit() else None
            self.db.event("process-watch", ticket, action=a.kind, label=a.label, pids=a.pids)
            log.warning("process watch: %s %s %s", a.kind, a.label, a.pids)
        return actions

    async def watcher(self) -> None:
        while True:
            await asyncio.to_thread(self.watch_once)
            await asyncio.sleep(30)

    async def cpu_loop(self) -> None:
        self.cpu.sample()  # psutil's first reading is meaningless; this primes it
        while True:
            await asyncio.sleep(5)
            self.cpu.sample()

    def resources(self) -> dict[str, object]:
        sessions, cpu_limit = self.engine.limits()
        room = self.engine.llm_room()
        return {"llm_active": room.llm_active, "llm_max": sessions, "cpu_pct": round(room.cpu, 1), "cpu_limit": cpu_limit,
                "waiting": room.reason, "overridden": bool(self.db.get("limit_llm") or self.db.get("limit_cpu"))}

    async def scheduler(self) -> None:
        while True:
            self.schedule_once()
            await asyncio.sleep(5)

    # API -----------------------------------------------------------------------------------------------------------
    def status(self) -> dict[str, object]:
        from . import heavy

        hv = heavy.status()
        tickets = [{"number": t.number, "title": t.title, "state": t.state, "priority": t.priority,
                    "activity": activity(self.db, t, mode=self.config.landing_mode), "blocked_by": self.db.open_blockers(t.number)}
                   for t in self.db.tickets() if t.state not in ("landed", "closed", "cancelled")]
        return {"daemon": {"pid": os.getpid(), "since": self.started, "last_poll": self.last_poll,
                           "error": self.last_error or self.update_error()},
                "self_update": {"pending": self.db.get("self_update_pending"), "failed": self.update_failure()},
                "resources": self.resources(), "pause": self.db.get("pause"), "muted": self.db.get("muted") == "1", "usage_pause_until": self.db.get("usage_pause_until"),
                "heavy": {"holders": [h.__dict__ for h in hv.holders], "queue": [w.__dict__ for w in hv.queue]},
                "tickets": tickets}

    def update_failure(self) -> dict[str, object] | None:
        raw = self.db.get("self_update_failed")
        return cast("dict[str, object]", json.loads(raw)) if raw else None

    def update_error(self) -> str:
        f = self.update_failure()
        return f"self-update to {str(f['sha'])[:10]} failed: {f['output']}" if f else ""

    def runtime(self) -> dict[str, object]:
        """The checkout the daemon runs from and how far behind origin/develop its pipeline/ is (cached 30 s)."""
        now = time.time()
        if self._runtime and now - float(str(self._runtime["at"])) < 30:
            return self._runtime
        root = self.engine.repo
        pinned = selfupdate.link("current")
        have = selfupdate.runtime_sha(pinned) if pinned else None
        if have:  # a pinned runtime is what is running: measure from it, not from the checkout's HEAD
            target = gitutil.git(root, "rev-parse", f"origin/{self.config.base_branch}", check=False).strip()
            behind = selfupdate.pipeline_commits_behind(root, have, target) if target else 0
            self._runtime = {"sha": have[:7], "behind_develop": behind, "at": now}
            return self._runtime
        sha = gitutil.git(root, "rev-parse", "--short", "HEAD", check=False).strip()
        behind_out = gitutil.git(root, "rev-list", "--count", f"HEAD..origin/{self.config.base_branch}", "--",
                                 "pipeline", ":(exclude)pipeline/monitor", check=False).strip()
        self._runtime = {"sha": sha, "behind_develop": int(behind_out or 0), "at": now}
        return self._runtime

    def monitor_update(self, sha: str) -> dict[str, object]:
        """How many commits under pipeline/monitor on origin/<base> the monitor build `sha` lacks, and the newest one.

        An unknown sha (or one that cannot be a sha) answers behind null; so does a repo without origin/<base>."""
        root, ref = self.engine.repo, f"origin/{self.config.base_branch}"
        paths = ("--", "pipeline/monitor")
        latest = gitutil.git(root, "rev-list", "-1", ref, *paths, check=False).strip() or None
        known = re.fullmatch(r"[0-9a-fA-F]{4,40}", sha) is not None and subprocess.run(
            ["git", "-C", str(root), "cat-file", "-e", f"{sha}^{{commit}}"], capture_output=True, check=False,
        ).returncode == 0
        behind: int | None = None
        if known:
            count = gitutil.git(root, "rev-list", "--count", f"{sha}..{ref}", *paths, check=False).strip()
            behind = int(count) if count.isdigit() else None
        return {"behind": behind, "latest": latest}

    def snapshot(self) -> dict[str, object]:
        """Everything the monitor shows, in one document. The daemon decides groups and activity lines, not the client."""
        base = {k: v for k, v in self.status().items() if k != "self_update"}  # the monitor's contract is pinned by a fixture
        now = time.time()
        hv: dict[str, Any] = base["heavy"]  # type: ignore[assignment]
        lock_tickets = {str(h["ticket"]) for h in hv["holders"]} | {str(w["ticket"]) for w in hv["queue"]}
        tickets: list[dict[str, object]] = []
        for t in self.db.tickets():
            row = self.db._all("SELECT updated_at FROM tickets WHERE number=?", (t.number,))[0]  # pyright: ignore[reportPrivateUsage]
            group = group_of(t, str(t.number) in lock_tickets, now, float(row["updated_at"]))
            if group is None:
                continue
            stages = self.db.stages(t.number)
            question = self.db.open_question(t.number)
            running = [s["model"] for s in stages if s["ended"] is None]  # the open stage's model, else none
            tickets.append({"number": t.number, "title": t.title, "state": t.state, "priority": t.priority,
                            "group": group, "model": running[-1] if running else None, "activity": activity(self.db, t, now, self.config.landing_mode), "blocked_by": self.db.open_blockers(t.number),
                            "pr_number": t.pr_number, "branch": t.branch, "worktree": t.worktree,
                            "park_reason": t.park_reason, "question": question["text"] if question else None,
                            "stages": [{k: s[k] for k in ("stage", "attempt", "model", "started", "ended", "lock_wait_s", "outcome")}
                                       for s in stages]})
        gate = [r for r in self.db._all("SELECT job, conclusion FROM develop_baseline WHERE workflow='pr-gate'")]  # pyright: ignore[reportPrivateUsage]
        reds = self.db._all("SELECT COUNT(*) AS n FROM develop_baseline WHERE conclusion NOT IN ('success','skipped','neutral')")  # pyright: ignore[reportPrivateUsage]
        week = self.db._all("SELECT kind, COUNT(*) AS n FROM interventions WHERE at > ? GROUP BY kind", (now - 7 * 86400,))  # pyright: ignore[reportPrivateUsage]
        cursor = self.db._all("SELECT COALESCE(MAX(id),0) AS m FROM events")[0]["m"]  # pyright: ignore[reportPrivateUsage]
        return {**base, "max_active": self.engine.max_active(), "tickets": tickets, "groups": list(GROUPS), "runtime": {k: v for k, v in self.runtime().items() if k != "at"},
                "landing": {"paused": self.db.get("pause") in ("all", "landing"), "stop_line": self.db.get("stop_line")},
                "develop": {"gate": {r["job"]: r["conclusion"] for r in gate}, "known_red": int(reds[0]["n"])},
                "interventions_week": {r["kind"]: r["n"] for r in week}, "events_cursor": int(cursor), "now": now,
                "version": "starpipe 1", "repo": f"{self.config.owner}/{self.config.repo}",
                "nightly": self.nightly_info()}

    def nightly_info(self) -> dict[str, object] | None:
        run = self.db.nightly_run()
        if run is None:
            return None
        return {"id": run["id"], "at": run["ended"] or run["started"], "running": run["ended"] is None, "status": run["status"],
                "ref": run["ref"], "sha": run["sha"][:12], "reds": len(run["summary"].get("reds", [])),
                "line": nightly.summary_line(run)}

    def log_tail(self, n: int, lines: int = 60) -> list[str]:
        folder = home() / "tickets" / str(n) / "transcripts"
        files = sorted(folder.glob("*.jsonl"), key=lambda f: f.stat().st_mtime)
        out: list[str] = []
        for row in (files[-1].read_text().splitlines()[-lines:] if files else []):
            try:
                data = json.loads(row)
            except ValueError:
                continue
            out.append(f"{time.strftime('%H:%M:%S', time.localtime(data['t']))} {data['type']}  {str(data['repr'])[:220]}")
        return out

    def _close_pr_for_requeue(self, n: int) -> None:
        t = self.db.ticket(n)
        if t is None or t.state not in ("ci", "landing") or self.db.batch_of(n) is not None or not t.pr_number:
            return
        try:
            self.engine.gh.close_pr(t.pr_number, "Moving this ticket onto the landing train: its changes will be in the next batch PR, "
                                    "which runs one CI for several tickets.")
            if t.branch:
                self.engine.gh.cancel_runs(t.branch)  # closing the PR leaves its queued runs in the queue, ahead of everyone else's
        except GitHubError:
            pass  # it is requeued either way; an open stale PR is harmless

    def show(self, n: int) -> dict[str, object] | None:
        t = self.db.ticket(n)
        if t is None:
            return None
        return {"number": t.number, "title": t.title, "state": t.state, "priority": t.priority, "branch": t.branch,
                "park_reason": t.park_reason, "plan": t.plan, "activity": activity(self.db, t, mode=self.config.landing_mode),
                "stages": self.db.stages(n), "checks": self.db.checks(n), "question": self.db.open_question(n),
                "blockers": [{"number": b, "title": self.blocker_title(b)} for b in self.db.open_blockers(n)]}

    def blocker_title(self, n: int) -> str:
        """A blocker's title: the pipeline ticket's, else the GitHub issue's (cached; a failed lookup is retried later)."""
        if n in self._blocker_titles:
            return self._blocker_titles[n]
        t = self.db.ticket(n)
        if t is not None:
            return t.title
        try:
            title = str(self.engine.gh.issue(n).get("title") or "")
        except GitHubError:
            return ""
        self._blocker_titles[n] = title
        return title

    def mutate(self, n: int, action: str, body: dict[str, object]) -> str:
        t = self.db.ticket(n)
        if t is None:
            raise web.HTTPNotFound(text=f"no ticket #{n}")
        if action == "answer":
            q = self.db.open_question(n)
            if q is None:
                raise web.HTTPConflict(text="no open question")
            self.db.answer_question(q["id"], str(body["text"]), "owner")
            self.db.intervention(n, "answer", q["stage"])
            self.engine.notifier.clear("needs-input", n)
            self.engine.parked.discard(n)
            self.engine._to_state(n, STAGE_STATE.get(q["stage"], "exploring"))  # pyright: ignore[reportPrivateUsage]
        elif action == "retry":
            stage = str(body.get("stage") or "explore")
            if stage not in RETRY_STATE:
                raise web.HTTPBadRequest(text=f"stage must be one of {', '.join(RETRY_STATE)}")
            self.db.intervention(n, "retry", stage)
            self.db.put(f"land_now:{n}", None)  # a retried ticket is tested again
            self.engine.parked.discard(n)
            self.engine._to_state(n, RETRY_STATE[stage])  # pyright: ignore[reportPrivateUsage]
        elif action == "allow-opus":
            self.db.put(f"opus_ok:{n}", "1")  # the ticket's own `model_<stage>: opus` choices now apply
            self.db.intervention(n, "allow-opus", t.state)
        elif action == "cancel":
            task = self.tasks.get(n)
            if task:
                task.cancel()
            self.db.intervention(n, "cancel", t.state)
            self.db.put(f"land_now:{n}", None)
            self.engine._to_state(n, "cancelled", str(body.get("reason") or "cancelled by the owner"))  # pyright: ignore[reportPrivateUsage]
        elif action == "requeue":
            if t.state not in ("ci", "landing") or self.db.batch_of(n) is not None:
                raise web.HTTPConflict(text=f"#{n} is {t.state}: only a ticket in its own CI can be moved onto the train")
            self.db.set_fields(n, pr_number=None)
            self.db.intervention(n, "requeue", t.state)
            self.engine._to_state(n, "ready")  # pyright: ignore[reportPrivateUsage]
        elif action == "land-now":
            if t.state not in LAND_NOW_STATES:
                raise web.HTTPConflict(text=f"#{n} is {t.state}: land-now needs a ticket in {', '.join(LAND_NOW_STATES)}")
            self.db.put(f"land_now:{n}", "1")
            self.db.intervention(n, "land-now", t.state)
            if t.pr_number:  # say so on the PR now; ship.pr_body repeats it on every later update
                try:
                    self.engine.gh.update_pr(t.pr_number, ship.pr_body(self.engine, t))
                except (GitHubError, RuntimeError):
                    pass
        elif action == "prio":
            prio = int(str(body["priority"]))
            self.db.set_fields(n, priority=prio)
            try:
                self.engine.gh.add_labels(n, [f"p{prio}"])
                for other in {"p0", "p1", "p2", "p3"} - {f"p{prio}"}:
                    self.engine.gh.remove_label(n, other)
            except GitHubError:
                pass
        else:
            raise web.HTTPBadRequest(text=f"unknown action {action}")
        return "ok"

    def _issue_problem(self, issue: dict[str, Any]) -> str | None:
        """Why `issue` cannot be enqueued, or None."""
        n = issue.get("number")
        if "pull_request" in issue:
            return f"#{n} is a pull request"
        if issue.get("state") != "open":
            return f"#{n} is closed"
        return None

    @staticmethod
    def _labelled(issue: dict[str, Any]) -> bool:
        labels = cast("list[object]", issue.get("labels") or [])
        names = {str(cast("dict[str, object]", lab).get("name")) if isinstance(lab, dict) else str(lab) for lab in labels}
        return trust.PIPELINE_LABEL in names

    def resolve_issue(self, url: str) -> dict[str, object]:
        """An issue link from the monitor's + sheet: this repo's open issue, its title and whether it is queued."""
        link = url.strip().split("#", 1)[0].split("?", 1)[0]
        m = ISSUE_URL.match(link)
        if m is None:
            raise web.HTTPBadRequest(text=f"not a GitHub issue link: {url.strip()[:200]}")
        if (m["owner"].lower(), m["repo"].lower()) != (self.config.owner.lower(), self.config.repo.lower()):
            raise web.HTTPBadRequest(text=f"not this repo ({self.config.owner}/{self.config.repo}): {m['owner']}/{m['repo']}")
        n = int(m["n"])
        if m["kind"] == "pull":
            raise web.HTTPBadRequest(text=f"#{n} is a pull request")
        try:
            issue = self.engine.gh.issue(n)
        except GitHubError as exc:
            raise web.HTTPNotFound(text=f"#{n}: {exc}") from exc
        problem = self._issue_problem(issue)
        if problem:
            raise web.HTTPUnprocessableEntity(text=problem)
        return {"number": n, "title": str(issue.get("title") or ""), "state": str(issue.get("state")),
                "queued": self._labelled(issue), "models": list(tickets.allowed_models(self.config.allow_fable)),
                "stages": list(tickets.MODEL_STAGES)}

    def _check_models(self, models: dict[str, str]) -> None:
        """400 for a stage or model the engine would not honour (tickets.validate_choice), before any issue is touched."""
        for stage, model in models.items():
            if stage not in tickets.MODEL_STAGES:
                raise web.HTTPBadRequest(text=f"unknown stage '{stage}' (one of {', '.join(tickets.MODEL_STAGES)})")
            bad = tickets.validate_choice(f"model_{stage}", model, self.config.allow_fable)
            if bad:
                raise web.HTTPBadRequest(text=f"{stage}: {bad}")

    def enqueue(self, numbers: list[int], models: dict[str, str] | None = None) -> list[dict[str, object]]:
        """Label each issue `pipeline` with the owner's token, so the next intake poll queues it (trust.may_run).

        `models` ({stage: model}) is written into each issue's '## Pipeline' section first, so the engine applies it."""
        models = models or {}
        self._check_models(models)
        out: list[dict[str, object]] = []
        for n in dict.fromkeys(numbers):
            try:
                issue = self.engine.gh.issue(n)
                problem = self._issue_problem(issue)
                if problem:
                    result = f"rejected: {problem}"
                elif self._labelled(issue):
                    result = "already queued"
                else:
                    body = str(issue.get("body") or "")
                    new_body = tickets.with_pipeline_models(body, models)
                    if new_body != body:
                        self.engine.gh.set_body(n, new_body)
                    self.engine.gh.add_labels(n, [trust.PIPELINE_LABEL])
                    if "opus" in models.values():
                        self.db.put(f"opus_ok:{n}", "1")  # the owner picked it in the monitor: the one way opus is asked for
                    result = "labelled"
            except GitHubError as exc:
                result = f"error: {exc}"
            out.append({"number": n, "result": result})
        return out

    def app(self) -> web.Application:
        @web.middleware
        async def auth(request: web.Request, handler: Callable[[web.Request], Awaitable[web.StreamResponse]]) -> web.StreamResponse:
            if request.headers.get("Authorization") != f"Bearer {self.token}":
                raise web.HTTPUnauthorized()
            return await handler(request)

        app = web.Application(middlewares=[auth])
        r = web.RouteTableDef()

        async def body_of(req: web.Request) -> dict[str, object]:
            data: object = await req.json() if req.can_read_body else {}
            return cast("dict[str, object]", data) if isinstance(data, dict) else {}

        @r.get("/v1/status")
        async def status(_: web.Request) -> web.Response:  # pyright: ignore[reportUnusedFunction]
            return web.json_response(self.status())

        @r.get("/v1/tickets/{n}")
        async def show(req: web.Request) -> web.Response:  # pyright: ignore[reportUnusedFunction]
            data = await asyncio.to_thread(self.show, int(req.match_info["n"]))  # a blocker's title may need GitHub
            if data is None:
                raise web.HTTPNotFound()
            return web.json_response(data)

        @r.get("/v1/snapshot")
        async def snapshot(_: web.Request) -> web.Response:  # pyright: ignore[reportUnusedFunction]
            return web.json_response(await asyncio.to_thread(self.snapshot))

        @r.get("/v1/limits")
        async def limits_get(_: web.Request) -> web.Response:  # pyright: ignore[reportUnusedFunction]
            return web.json_response(self.resources())

        @r.post("/v1/limits")
        async def limits_set(req: web.Request) -> web.Response:  # pyright: ignore[reportUnusedFunction]
            body = await body_of(req)
            if body.get("reset"):
                self.db.put("limit_llm", None)
                self.db.put("limit_cpu", None)
            if body.get("llm") is not None:
                value = int(str(body["llm"]))
                if not 1 <= value <= 32:
                    raise web.HTTPBadRequest(text="llm must be between 1 and 32")
                self.db.put("limit_llm", str(value))
            if body.get("cpu") is not None:
                pct = float(str(body["cpu"]))
                if not 10 <= pct <= 100:
                    raise web.HTTPBadRequest(text="cpu must be between 10 and 100")
                self.db.put("limit_cpu", str(pct))
            self.db.intervention(None, "limits")
            return web.json_response(self.resources())

        @r.get("/v1/monitor-update")
        async def monitor_update(req: web.Request) -> web.Response:  # pyright: ignore[reportUnusedFunction]
            return web.json_response(await asyncio.to_thread(self.monitor_update, req.query.get("sha", "")))

        @r.get("/v1/runtime")
        async def runtime_info(_: web.Request) -> web.Response:  # pyright: ignore[reportUnusedFunction]
            cur, prev = selfupdate.link("current"), selfupdate.link("previous")
            return web.json_response({"sessions": len(self.db.running_stages()), "pid": os.getpid(),
                                      "current": cur.name if cur else None, "previous": prev.name if prev else None,
                                      "pending": self.db.get("self_update_pending")})

        @r.get("/v1/nightly")
        async def nightly_status(_: web.Request) -> web.Response:  # pyright: ignore[reportUnusedFunction]
            return web.json_response(self.db.nightly_run() or {})

        @r.post("/v1/nightly/run")
        async def nightly_run(req: web.Request) -> web.Response:  # pyright: ignore[reportUnusedFunction]
            body = await body_of(req)
            opts = nightly.Options(ref=str(body["ref"]) if body.get("ref") else None,
                                   suites=[str(x) for x in cast("list[object]", body.get("suites") or [])],
                                   ui=bool(body.get("ui", self.config.nightly_ui)), file_tickets=bool(body.get("file_tickets", True)))
            if self.start_nightly(opts) is None:
                raise web.HTTPConflict(text="a nightly is already running")
            return web.json_response({"result": "started"})

        @r.get("/v1/tickets/{n}/log")
        async def tail(req: web.Request) -> web.Response:  # pyright: ignore[reportUnusedFunction]
            return web.json_response({"lines": self.log_tail(int(req.match_info["n"]), int(req.query.get("lines", 60)))})

        @r.get("/v1/events")
        async def events(req: web.Request) -> web.StreamResponse:  # pyright: ignore[reportUnusedFunction]
            after = int(req.query.get("after", req.headers.get("Last-Event-ID", 0)))
            if "text/event-stream" not in req.headers.get("Accept", ""):
                return web.json_response(self.db.events_since(after))
            resp = web.StreamResponse(headers={"Content-Type": "text/event-stream", "Cache-Control": "no-cache"})
            await resp.prepare(req)
            idle = 0
            while True:  # one event per line pair; a comment every 15 s keeps proxies and the client's timeout quiet
                batch = self.db.events_since(after)
                for e in batch:
                    after = e["id"]
                    await resp.write(f"id: {e['id']}\ndata: {json.dumps(e)}\n\n".encode())
                idle = 0 if batch else idle + 1
                if idle and idle % 15 == 0:
                    await resp.write(b": keepalive\n\n")
                await asyncio.sleep(1)

        @r.get("/v1/issues/resolve")
        async def resolve(req: web.Request) -> web.Response:  # pyright: ignore[reportUnusedFunction]
            url = req.query.get("url")
            if not url:
                raise web.HTTPBadRequest(text="url is required")
            return web.json_response(await asyncio.to_thread(self.resolve_issue, url))

        @r.post("/v1/enqueue")
        async def enqueue(req: web.Request) -> web.Response:  # pyright: ignore[reportUnusedFunction]
            body = await body_of(req)
            raw = body.get("numbers")
            items = cast("list[object]", raw) if isinstance(raw, list) else []
            if not items or not all(isinstance(x, int) and not isinstance(x, bool) for x in items):
                raise web.HTTPBadRequest(text="numbers must be a non-empty list of issue numbers")
            numbers = [cast("int", x) for x in items]
            chosen = body.get("models")
            if chosen is None:
                chosen = {}
            if not isinstance(chosen, dict) or not all(isinstance(k, str) and isinstance(v, str)
                                                       for k, v in cast("dict[object, object]", chosen).items()):
                raise web.HTTPBadRequest(text="models must be an object of stage to model name")
            models = cast("dict[str, str]", chosen)
            return web.json_response({"results": await asyncio.to_thread(self.enqueue, numbers, models)})

        @r.post("/v1/tickets/{n}/{action}")
        async def act(req: web.Request) -> web.Response:  # pyright: ignore[reportUnusedFunction]
            body = await body_of(req)
            n = int(req.match_info["n"])
            if req.match_info["action"] == "requeue":
                await asyncio.to_thread(self._close_pr_for_requeue, n)  # the GitHub call off the loop; the state change on it
            return web.json_response({"result": self.mutate(n, req.match_info["action"], body)})

        @r.post("/v1/pause")
        async def pause(req: web.Request) -> web.Response:  # pyright: ignore[reportUnusedFunction]
            body = await body_of(req)
            self.db.put("pause", str(body.get("scope") or "all"))
            return web.json_response({"result": "ok"})

        @r.post("/v1/settings")
        async def settings(req: web.Request) -> web.Response:  # pyright: ignore[reportUnusedFunction]
            body = await body_of(req)
            n = body.get("max_active")
            if isinstance(n, bool) or not isinstance(n, int) or not 1 <= n <= MAX_ACTIVE_CAP:
                raise web.HTTPBadRequest(text=f"max_active must be an integer from 1 to {MAX_ACTIVE_CAP}")
            self.db.put("max_active", str(n))  # lowering it never stops a running ticket, it only stops new claims
            return web.json_response({"result": "ok"})

        @r.post("/v1/mute")
        async def mute(req: web.Request) -> web.Response:  # pyright: ignore[reportUnusedFunction]
            body = await body_of(req)
            muted = body.get("muted")
            if not isinstance(muted, bool):
                raise web.HTTPBadRequest(text="muted must be true or false")
            self.db.put("muted", "1" if muted else "0")  # the daemon db: it survives a restart
            return web.json_response({"result": "ok"})

        @r.post("/v1/resume")
        async def resume(_: web.Request) -> web.Response:  # pyright: ignore[reportUnusedFunction]
            self.db.put("pause", None)
            return web.json_response({"result": "ok"})

        app.add_routes(r)
        return app

    async def run(self) -> None:
        self.reconcile()
        os.environ["STARPIPE_TICKET"] = "daemon"  # the daemon's own heavy jobs queue at pipeline priority
        runner = web.AppRunner(self.app())
        await runner.setup()
        await web.TCPSite(runner, "127.0.0.1", self.config.api_port).start()
        log.info("starpiped up on 127.0.0.1:%d", self.config.api_port)
        try:
            await asyncio.gather(self.supervise("poller", self.poller), self.supervise("scheduler", self.scheduler),
                                 self.supervise("watcher", self.watcher), self.supervise("nightly", self.nightly_loop),
                                 self.supervise("digest", self.digest_loop), self.supervise("update", self.update_loop),
                                 self.supervise("train", self.train.run_forever), self.supervise("cpu", self.cpu_loop))
        finally:
            await runner.cleanup()


def hard_exit(code: int) -> None:
    """Leave now. `sys.exit` unwinds through asyncio and then waits on non-daemon threads (a running check, an SDK
    subprocess pipe), so a self-update could log "exiting" and then hang with the server closed and launchd none the
    wiser. State is all in the database, and `reconcile` picks up whatever was running."""
    logging.shutdown()
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(code)


def resolve_java_home(config: Config) -> str | None:
    """The JDK the desktop builds need: config, then $JAVA_HOME, then the adapter's known locations."""
    from . import adapter_star

    for candidate in (config.java_home, os.environ.get("JAVA_HOME", ""), *adapter_star.JAVA_HOME_CANDIDATES):
        if candidate and (Path(candidate) / "bin" / "java").exists():
            return candidate
    return None


def checkout_root(config: Config, start: Path) -> Path:
    if config.checkout:
        return Path(config.checkout)
    common = gitutil.git(start, "rev-parse", "--path-format=absolute", "--git-common-dir").strip()
    return Path(common).parent


def build(config: Config) -> Daemon:
    from .agent import SdkRunner
    from .announce import SayAnnouncer
    from .engine import check_runner_for
    from .github import GitHub
    from .notify import Notifier

    java = resolve_java_home(config)
    if java:
        os.environ["JAVA_HOME"] = java  # every check the daemon runs, and every session it starts, inherits it
    repo = checkout_root(config, Path.cwd())
    db = Database()
    shim = str(Path(__file__).resolve().parents[2] / "bin" / "starpipe")
    engine = Engine(config, db, GitHub(config), SdkRunner(shim), repo, check_runner_for(), Notifier(db),
                    base_ref=gitutil.resolve_base(repo, None), shim=shim, announcer=SayAnnouncer())
    return Daemon(engine, config)


__all__ = ["Daemon", "activity", "build", "worktrees"]
