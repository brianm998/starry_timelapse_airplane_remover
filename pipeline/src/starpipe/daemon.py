"""starpiped: one asyncio process (plan §5, §14). Supervised tasks: intake poller, scheduler, local API."""

from __future__ import annotations

import asyncio
import logging
import os
import secrets
import time
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import cast

from aiohttp import web

from . import gitutil, ship, worktrees
from .config import Config, token_path
from .db import ACTIVE_STATES, POST_STATES, Database, Ticket
from .engine import STAGE_STATE, Engine
from .github import GitHubError

log = logging.getLogger("starpiped")


def api_token() -> str:
    path = token_path()
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(secrets.token_urlsafe(32))
        path.chmod(0o600)
    return path.read_text().strip()


def activity(db: Database, t: Ticket, now: float | None = None) -> str:
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
    return t.state if t.state != "ready" else "ready to publish"


class Daemon:
    def __init__(self, engine: Engine, config: Config, token: str | None = None) -> None:
        self.engine, self.config, self.db = engine, config, engine.db
        self.token = token or api_token()
        self.tasks: dict[int, asyncio.Task[None]] = {}
        self.started = time.time()
        self.last_poll: float | None = None
        self.last_error: str = ""

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

    async def scheduler(self) -> None:
        while True:
            self.schedule_once()
            await asyncio.sleep(5)

    # API -----------------------------------------------------------------------------------------------------------
    def status(self) -> dict[str, object]:
        from . import heavy

        hv = heavy.status()
        tickets = [{"number": t.number, "title": t.title, "state": t.state, "priority": t.priority,
                    "activity": activity(self.db, t), "blocked_by": self.db.open_blockers(t.number)}
                   for t in self.db.tickets() if t.state not in ("landed", "closed", "cancelled")]
        return {"daemon": {"pid": os.getpid(), "since": self.started, "last_poll": self.last_poll,
                           "error": self.last_error},
                "pause": self.db.get("pause"), "usage_pause_until": self.db.get("usage_pause_until"),
                "heavy": {"holders": [h.__dict__ for h in hv.holders], "queue": [w.__dict__ for w in hv.queue]},
                "tickets": tickets}

    def show(self, n: int) -> dict[str, object] | None:
        t = self.db.ticket(n)
        if t is None:
            return None
        return {"number": t.number, "title": t.title, "state": t.state, "priority": t.priority, "branch": t.branch,
                "park_reason": t.park_reason, "plan": t.plan, "activity": activity(self.db, t),
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
            if stage not in STAGE_STATE:
                raise web.HTTPBadRequest(text=f"stage must be one of {', '.join(STAGE_STATE)}")
            self.db.intervention(n, "retry", stage)
            self.engine.parked.discard(n)
            self.engine._to_state(n, STAGE_STATE[stage])  # pyright: ignore[reportPrivateUsage]
        elif action == "cancel":
            task = self.tasks.get(n)
            if task:
                task.cancel()
            self.db.intervention(n, "cancel", t.state)
            self.engine._to_state(n, "cancelled", str(body.get("reason") or "cancelled by the owner"))  # pyright: ignore[reportPrivateUsage]
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

        @r.get("/v1/events")
        async def events(req: web.Request) -> web.Response:  # pyright: ignore[reportUnusedFunction]
            return web.json_response(self.db.events_since(int(req.query.get("after", 0))))

        @r.post("/v1/tickets/{n}/{action}")
        async def act(req: web.Request) -> web.Response:  # pyright: ignore[reportUnusedFunction]
            body = await body_of(req)
            return web.json_response({"result": self.mutate(int(req.match_info["n"]), req.match_info["action"], body)})

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
            await asyncio.gather(self.supervise("poller", self.poller), self.supervise("scheduler", self.scheduler))
        finally:
            await runner.cleanup()


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

    repo = checkout_root(config, Path.cwd())
    db = Database()
    shim = str(Path(__file__).resolve().parents[2] / "bin" / "starpipe")
    engine = Engine(config, db, GitHub(config), SdkRunner(shim), repo, check_runner_for(), Notifier(db),
                    base_ref=gitutil.resolve_base(repo, None), shim=shim)
    return Daemon(engine, config)


__all__ = ["Daemon", "activity", "build", "worktrees"]
