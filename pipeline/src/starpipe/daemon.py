"""starpiped: one asyncio process (plan §5, §14). Supervised tasks: intake poller, scheduler, local API."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import secrets
import subprocess
import time
from collections.abc import Awaitable, Callable
from datetime import datetime
from pathlib import Path
from typing import Any, cast

from aiohttp import web

from . import digest as digest_mod
from . import gitutil, heavy, nightly, selfupdate, ship, train, watch, worktrees
from .config import Config, home, token_path
from .db import ACTIVE_STATES, POST_STATES, Database, Ticket
from .engine import RETRY_STATE, STAGE_STATE, Engine
from .github import GitHubError

log = logging.getLogger("starpiped")


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
    if last and last["ended"] is None:
        spent = int((now - last["started"]) / 60)
        return f"{t.state} · attempt {last['attempt']}/3 · {spent}m" + (
            f" (+{int(last['lock_wait_s'] / 60)}m lock wait)" if last["lock_wait_s"] >= 60 else "")
    if t.state in ("ci", "landing") and (batch := db.batch_of(t.number)) is not None:
        return f"CI · batch #{batch} ({len(db.batch_members(batch))} tickets together)"
    if t.state == "ready":
        return "ready · waiting for the next batch" if mode == "batch" else "ready to publish"
    return t.state


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

    # supervision ---------------------------------------------------------------------------------------------------
    def reconcile(self) -> None:
        """Mark stages that were running when the daemon died; drive() resumes them by session id."""
        for s in self.db.running_stages():
            self.db.end_stage(s["id"], "interrupted", detail="daemon restarted")
        self.engine.parked.clear()

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

    def auto_update_once(self, plist: Path, launchctl: selfupdate.Launchctl = selfupdate.real_launchctl) -> str | None:
        """After a landing that changed pipeline/ (and only when idle), switch to a runtime built from develop's tip."""
        wanted = self.db.get("self_update_wanted")
        if not (self.config.auto_self_update and wanted) or self.db.running_stages():
            return None
        try:
            selfupdate.update(self.engine.repo, f"origin/{self.config.base_branch}", plist,
                              sessions=lambda: len(self.db.running_stages()), wait_s=0, launchctl=launchctl)
        except (RuntimeError, subprocess.SubprocessError, OSError) as exc:
            self.db.put("self_update_wanted", None)  # one try per landing: a broken build must not retry in a loop
            self.engine.notifier.alert("self-update-failed", None, f"self-update to {wanted[:10]} failed: {exc}")
            return f"failed: {exc}"
        self.db.put("self_update_wanted", None)
        return "updated"

    async def update_loop(self) -> None:
        plist = Path.home() / "Library" / "LaunchAgents" / f"{selfupdate.LABEL}.plist"
        while True:
            await asyncio.to_thread(self.auto_update_once, plist)
            await asyncio.sleep(120)

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
                           "error": self.last_error},
                "pause": self.db.get("pause"), "usage_pause_until": self.db.get("usage_pause_until"),
                "heavy": {"holders": [h.__dict__ for h in hv.holders], "queue": [w.__dict__ for w in hv.queue]},
                "tickets": tickets}

    def runtime(self) -> dict[str, object]:
        """The checkout the daemon runs from and how far behind origin/develop its pipeline/ is (cached 30 s)."""
        now = time.time()
        if self._runtime and now - float(str(self._runtime["at"])) < 30:
            return self._runtime
        root = self.engine.repo
        sha = gitutil.git(root, "rev-parse", "--short", "HEAD", check=False).strip()
        behind = gitutil.git(root, "rev-list", "--count", f"HEAD..origin/{self.config.base_branch}", "--",
                             "pipeline", check=False).strip()
        self._runtime = {"sha": sha, "behind_develop": int(behind or 0), "at": now}
        return self._runtime

    def snapshot(self) -> dict[str, object]:
        """Everything the monitor shows, in one document. The daemon decides groups and activity lines, not the client."""
        base = self.status()
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
            tickets.append({"number": t.number, "title": t.title, "state": t.state, "priority": t.priority,
                            "group": group, "activity": activity(self.db, t, now, self.config.landing_mode), "blocked_by": self.db.open_blockers(t.number),
                            "pr_number": t.pr_number, "branch": t.branch, "worktree": t.worktree,
                            "park_reason": t.park_reason, "question": question["text"] if question else None,
                            "stages": [{k: s[k] for k in ("stage", "attempt", "model", "started", "ended", "lock_wait_s", "outcome")}
                                       for s in stages]})
        gate = [r for r in self.db._all("SELECT job, conclusion FROM develop_baseline WHERE workflow='pr-gate'")]  # pyright: ignore[reportPrivateUsage]
        reds = self.db._all("SELECT COUNT(*) AS n FROM develop_baseline WHERE conclusion NOT IN ('success','skipped','neutral')")  # pyright: ignore[reportPrivateUsage]
        week = self.db._all("SELECT kind, COUNT(*) AS n FROM interventions WHERE at > ? GROUP BY kind", (now - 7 * 86400,))  # pyright: ignore[reportPrivateUsage]
        cursor = self.db._all("SELECT COALESCE(MAX(id),0) AS m FROM events")[0]["m"]  # pyright: ignore[reportPrivateUsage]
        return {**base, "tickets": tickets, "groups": list(GROUPS), "runtime": {k: v for k, v in self.runtime().items() if k != "at"},
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
        except GitHubError:
            pass  # it is requeued either way; an open stale PR is harmless

    def show(self, n: int) -> dict[str, object] | None:
        t = self.db.ticket(n)
        if t is None:
            return None
        return {"number": t.number, "title": t.title, "state": t.state, "priority": t.priority, "branch": t.branch,
                "park_reason": t.park_reason, "plan": t.plan, "activity": activity(self.db, t, mode=self.config.landing_mode),
                "stages": self.db.stages(n), "checks": self.db.checks(n), "question": self.db.open_question(n)}

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
            self.engine.parked.discard(n)
            self.engine._to_state(n, RETRY_STATE[stage])  # pyright: ignore[reportPrivateUsage]
        elif action == "cancel":
            task = self.tasks.get(n)
            if task:
                task.cancel()
            self.db.intervention(n, "cancel", t.state)
            self.engine._to_state(n, "cancelled", str(body.get("reason") or "cancelled by the owner"))  # pyright: ignore[reportPrivateUsage]
        elif action == "requeue":
            if t.state not in ("ci", "landing") or self.db.batch_of(n) is not None:
                raise web.HTTPConflict(text=f"#{n} is {t.state}: only a ticket in its own CI can be moved onto the train")
            self.db.set_fields(n, pr_number=None)
            self.db.intervention(n, "requeue", t.state)
            self.engine._to_state(n, "ready")  # pyright: ignore[reportPrivateUsage]
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
            data = self.show(int(req.match_info["n"]))
            if data is None:
                raise web.HTTPNotFound()
            return web.json_response(data)

        @r.get("/v1/snapshot")
        async def snapshot(_: web.Request) -> web.Response:  # pyright: ignore[reportUnusedFunction]
            return web.json_response(await asyncio.to_thread(self.snapshot))

        @r.get("/v1/runtime")
        async def runtime_info(_: web.Request) -> web.Response:  # pyright: ignore[reportUnusedFunction]
            cur, prev = selfupdate.link("current"), selfupdate.link("previous")
            return web.json_response({"sessions": len(self.db.running_stages()), "pid": os.getpid(),
                                      "current": cur.name if cur else None, "previous": prev.name if prev else None,
                                      "wanted": self.db.get("self_update_wanted")})

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
                                 self.supervise("train", self.train.run_forever))
        finally:
            await runner.cleanup()


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
                    base_ref=gitutil.resolve_base(repo, None), shim=shim)
    return Daemon(engine, config)


__all__ = ["Daemon", "activity", "build", "worktrees"]
