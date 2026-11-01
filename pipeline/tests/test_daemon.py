from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Any

import pytest
from aiohttp.test_utils import TestClient, TestServer

from starpipe import selfupdate
from starpipe.agent import StageOutcome, StageRequest
from starpipe.config import Config
from starpipe.daemon import Daemon, activity

from .fakes import accepted, plan_args, sh
from .test_engine import Rig, explore_ok
from .test_selfupdate import Launchctl, fake_plist, noop_sync, ok_test


@pytest.fixture
def rig(tmp_path: Path) -> Rig:
    return Rig(tmp_path)


async def api(rig: Rig) -> tuple[TestClient[Any, Any], Daemon]:
    d = Daemon(rig.engine, Config(), token="tok")
    client = TestClient(TestServer(d.app()))
    await client.start_server()
    return client, d


AUTH = {"Authorization": "Bearer tok"}


async def test_the_api_requires_the_token(rig: Rig) -> None:
    client, _ = await api(rig)
    try:
        assert (await client.get("/v1/status")).status == 401
        assert (await client.get("/v1/status", headers={"Authorization": "Bearer nope"})).status == 401
        assert (await client.get("/v1/status", headers=AUTH)).status == 200
    finally:
        await client.close()


async def test_status_and_show_report_the_ticket_and_its_activity(rig: Rig) -> None:
    rig.gh.add_issue(7, "Tidy the docs")
    rig.engine.sync_issues()
    client, _ = await api(rig)
    try:
        data = await (await client.get("/v1/status", headers=AUTH)).json()
        assert data["tickets"][0]["number"] == 7 and data["tickets"][0]["activity"] == "queued"
        shown = await (await client.get("/v1/tickets/7", headers=AUTH)).json()
        assert shown["title"] == "Tidy the docs" and shown["stages"] == []
        assert (await client.get("/v1/tickets/99", headers=AUTH)).status == 404
    finally:
        await client.close()


async def test_answer_retry_cancel_prio_and_pause(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    qid = rig.db.add_question(7, "explore", "which?", {})
    rig.db.set_state(7, "needs-input", "waiting")
    client, d = await api(rig)
    try:
        r = await client.post("/v1/tickets/7/answer", json={"text": "the first"}, headers=AUTH)
        assert r.status == 200 and rig.state(7) == "exploring"
        assert rig.db.open_question(7) is None and qid
        assert (await client.post("/v1/tickets/7/answer", json={"text": "x"}, headers=AUTH)).status == 409

        await client.post("/v1/tickets/7/retry", json={"stage": "develop"}, headers=AUTH)
        assert rig.state(7) == "developing"
        assert (await client.post("/v1/tickets/7/retry", json={"stage": "nope"}, headers=AUTH)).status == 400

        await client.post("/v1/tickets/7/prio", json={"priority": 0}, headers=AUTH)
        t = rig.db.ticket(7)
        assert t and t.priority == 0

        await client.post("/v1/pause", json={"scope": "claims"}, headers=AUTH)
        rig.db.set_state(7, "queued")
        assert rig.engine.claimable() is None
        await client.post("/v1/resume", headers=AUTH)
        assert rig.engine.claimable() is not None

        await client.post("/v1/tickets/7/cancel", json={"reason": "no"}, headers=AUTH)
        assert rig.state(7) == "cancelled"
        kinds = [r["kind"] for r in rig.db._all("SELECT kind FROM interventions")]  # pyright: ignore[reportPrivateUsage]
        assert kinds == ["answer", "retry", "cancel"]
        assert d
    finally:
        await client.close()


async def test_restart_resumes_an_interrupted_stage_by_session_id(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    t = rig.engine.claim(rig.engine.claimable() or rig.db.tickets()[0])
    sid = rig.db.begin_stage(7, "explore", 1, "opus")
    rig.db.set_session(sid, "S-old")  # the daemon died here: the stage row never ended
    daemon = Daemon(rig.engine, Config(), token="tok")
    daemon.reconcile()
    assert rig.db.running_stages() == []
    assert rig.db.stages(7)[0]["outcome"] == "interrupted"

    seen: list[StageRequest] = []

    def explore(req: StageRequest) -> StageOutcome:
        seen.append(req)
        req.contract.submit_plan(plan_args())
        return accepted(req, "S-old")

    rig.agent.on("explore", explore)
    rig.agent.on("develop", lambda r: StageOutcome("no-result"))
    await rig.engine.drive(t.number)
    assert seen[0].resume == "S-old"


async def test_a_task_that_dies_is_restarted(rig: Rig) -> None:
    d = Daemon(rig.engine, Config(), token="tok")
    calls = {"n": 0}

    async def flaky() -> None:
        calls["n"] += 1
        if calls["n"] < 3:
            raise RuntimeError("boom")

    await d.supervise("flaky", flaky, delay=0.0)
    assert calls["n"] == 3 and "flaky died" in d.last_error


async def test_schedule_once_claims_one_ticket_and_runs_it(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    rig.agent.on("explore", explore_ok)
    rig.agent.on("develop", lambda r: StageOutcome("no-result"))
    d = Daemon(rig.engine, Config(), token="tok")
    d.schedule_once()
    await asyncio.gather(*d.tasks.values())
    assert rig.db.stages(7)[0]["stage"] == "explore"


def test_activity_line(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    t = rig.db.ticket(7)
    assert t
    rig.db.begin_stage(7, "develop", 2, "opus")
    t = rig.engine.claim(t)
    rig.db.set_state(7, "developing")
    t = rig.db.ticket(7)
    assert t and activity(rig.db, t, rig.now + 600).startswith("developing · attempt 2/3 · 10m")


async def test_the_session_id_is_recorded_as_soon_as_it_is_known_so_a_kill_can_resume(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    seen: list[StageRequest] = []

    def killed_mid_stage(req: StageRequest) -> StageOutcome:
        seen.append(req)
        req.on_session("S-early")  # the SDK reported the id; the run then died without a result message
        return StageOutcome("crash")

    def resumed(req: StageRequest) -> StageOutcome:
        seen.append(req)
        req.contract.submit_plan(plan_args())
        return accepted(req, "S-early")

    rig.agent.on("explore", killed_mid_stage, resumed)
    rig.agent.on("develop", lambda r: StageOutcome("no-result"))
    await rig.engine.drive(7)
    assert seen[1].resume == "S-early"
    assert rig.db.stages(7, "explore")[0]["session_id"] == "S-early"


def commit_under(repo: Path, rel: str, text: str) -> str:
    """Commit one file to the working clone's develop and publish it to the bare origin; return the new sha."""
    (repo / rel).parent.mkdir(parents=True, exist_ok=True)
    (repo / rel).write_text(text)
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-q", "-m", f"edit {rel}")
    sh(repo, "git", "push", "-q", "origin", "HEAD:develop")
    sh(repo, "git", "fetch", "-q")
    return sh(repo, "git", "rev-parse", "HEAD").strip()


async def monitor_update(client: TestClient[Any, Any], sha: str) -> dict[str, Any]:
    resp = await client.get("/v1/monitor-update", params={"sha": sha}, headers=AUTH)
    assert resp.status == 200
    return await resp.json()  # type: ignore[no-any-return]


async def test_monitor_update_reports_commits_behind_under_pipeline_monitor_and_the_latest_sha(rig: Rig) -> None:
    repo = rig.engine.repo
    built = commit_under(repo, "pipeline/monitor/a.swift", "one\n")
    commit_under(repo, "pipeline/monitor/a.swift", "two\n")
    newest = commit_under(repo, "pipeline/monitor/b.swift", "three\n")
    assert sh(repo, "git", "rev-parse", "origin/develop").strip() == newest
    client, _ = await api(rig)
    try:
        assert await monitor_update(client, built) == {"behind": 2, "latest": newest}
    finally:
        await client.close()


async def test_monitor_update_is_zero_behind_when_up_to_date_and_ignores_other_paths(rig: Rig) -> None:
    repo = rig.engine.repo
    built = commit_under(repo, "pipeline/monitor/a.swift", "one\n")
    commit_under(repo, "docs/b.md", "elsewhere\n")
    commit_under(repo, "pipeline/src/x.py", "daemon only\n")
    client, _ = await api(rig)
    try:
        assert await monitor_update(client, built) == {"behind": 0, "latest": built}
    finally:
        await client.close()


async def test_monitor_update_for_an_unknown_sha_is_behind_null_not_an_error(rig: Rig) -> None:
    latest = commit_under(rig.engine.repo, "pipeline/monitor/a.swift", "one\n")
    client, _ = await api(rig)
    try:
        for sha in ("deadbeef" * 5, "", "--output=x", "HEAD"):
            assert await monitor_update(client, sha) == {"behind": None, "latest": latest}
    finally:
        await client.close()


# self-update ---------------------------------------------------------------------------------------------------------
def commit_to_origin(repo: Path, rel: str, text: str) -> str:
    """A commit on develop in the working clone, sent to the (local, bare) origin. Returns its sha."""
    path = repo / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-q", "-m", f"change {rel}")
    sh(repo, "git", "push", "-q", "origin", "HEAD:develop")
    return sh(repo, "git", "rev-parse", "HEAD").strip()


class Pinned:
    """A daemon running from a pinned runtime built at origin/develop's tip, with origin free to move on."""

    def __init__(self, rig: Rig, tmp: Path) -> None:
        self.rig, self.repo = rig, rig.engine.repo
        self.base = commit_to_origin(self.repo, "pipeline/bin/starpipe", "#!/bin/bash\necho starpipe\n")
        self.plist = fake_plist(tmp)
        selfupdate.switch(selfupdate.build(self.repo, self.base, noop_sync), self.plist, Launchctl(), now=1.0, restart=False)
        self.daemon = Daemon(rig.engine, Config(remote="origin"), token="t")
        self.exits: list[int] = []
        self.daemon.exit = self.exits.append
        self.built: list[Path] = []
        self.tested: list[Path] = []

    def sync(self, rt: Path) -> None:
        self.built.append(rt)
        noop_sync(rt)

    def check(self, rt: Path) -> tuple[bool, str]:
        self.tested.append(rt)
        return ok_test(rt)

    def once(self, test: Any = None) -> str | None:
        return self.daemon.self_update_once(self.plist, sync=self.sync, test=test or self.check)

    def current_sha(self) -> str | None:
        cur = selfupdate.link("current")
        return selfupdate.runtime_sha(cur) if cur else None


async def test_a_passing_smoke_check_holds_new_work_and_swaps_only_when_idle(rig: Rig, tmp_path: Path) -> None:
    pin = Pinned(rig, tmp_path)
    rig.gh.add_issue(1, "running")
    rig.gh.add_issue(2, "waiting")
    rig.engine.sync_issues()
    assert rig.engine.claimable() is not None
    rig.db.begin_stage(1, "develop", 1, "sonnet")  # a stage is mid-session
    target = commit_to_origin(pin.repo, "pipeline/src/new.py", "x = 1\n")

    assert pin.once() == "pending"
    assert rig.db.get("self_update_pending") == target and len(pin.tested) == 1, "staged and smoke-checked"
    assert pin.current_sha() == pin.base and not pin.exits, "the swap waits for the running stage"
    assert rig.db.get("pause") is None, "the hold is not the owner's pause flag"
    assert rig.engine.claimable() is None, "no claims while an update is pending"
    assert pin.once() == "pending" and len(pin.tested) == 1, "still waiting, and not smoke-checked again"

    await pin.daemon.update_step(pin.plist, pin.sync, pin.check)
    assert pin.exits == [] and pin.current_sha() == pin.base

    rig.db.end_stage(rig.db.running_stages()[0]["id"], "accepted")
    await pin.daemon.update_step(pin.plist, pin.sync, pin.check)
    assert pin.exits == [0], "the daemon exits 0 for launchd to restart it"
    assert pin.current_sha() == target and selfupdate.link("previous") == selfupdate.runtime_dir(pin.base).resolve()
    events = [e for e in rig.db.events_since() if e["kind"] == "self-update"]
    assert len(events) == 1 and events[0]["data"] == {"old": pin.base, "new": target}

    pin.daemon.reconcile()  # the restarted process: no hold, claims resume
    assert rig.db.get("self_update_pending") is None and rig.engine.claimable() is not None


async def test_a_pending_update_holds_the_next_model_stage(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    rig.db.put("self_update_pending", "abc")
    requests_when_released: list[int] = []

    async def release(_seconds: float) -> None:
        requests_when_released.append(len(rig.agent.requests))
        rig.db.put("self_update_pending", None)

    rig.engine.sleep = release  # type: ignore[assignment]
    rig.agent.on("explore", explore_ok)
    rig.agent.on("develop", lambda r: StageOutcome("no-result"))
    await rig.engine.drive(7)
    assert requests_when_released == [0], "no stage began while the update was pending"
    assert rig.db.stages(7)[0]["stage"] == "explore", "and it began once the hold cleared"


async def test_a_failing_smoke_check_keeps_the_running_version_and_is_not_retried(rig: Rig, tmp_path: Path) -> None:
    pin = Pinned(rig, tmp_path)
    target = commit_to_origin(pin.repo, "pipeline/src/new.py", "import nope\n")
    calls: list[Path] = []

    def bad(rt: Path) -> tuple[bool, str]:
        calls.append(rt)
        return False, "ModuleNotFoundError: nope"

    assert pin.once(bad) == "failed"
    assert pin.current_sha() == pin.base and not pin.exits
    assert rig.db.get("self_update_pending") is None
    events = [e for e in rig.db.events_since() if e["kind"] == "self-update-failed"]
    assert len(events) == 1 and events[0]["data"]["sha"] == target and "ModuleNotFoundError" in events[0]["data"]["output"]
    assert not selfupdate.runtime_dir(target).exists(), "the failed staging copy is removed"
    assert any(t == "star pipeline: self-update-failed" for t, _ in rig.pages)
    client, _ = await api(rig)
    try:
        status = await (await client.get("/v1/status", headers=AUTH)).json()
    finally:
        await client.close()
    assert target[:10] in status["daemon"]["error"] and "ModuleNotFoundError" in status["daemon"]["error"]
    assert status["self_update"]["failed"]["sha"] == target

    assert pin.once(bad) is None and len(calls) == 1, "the same sha is not tried again"
    newer = commit_to_origin(pin.repo, "pipeline/src/newer.py", "y = 2\n")
    assert pin.once() == "swapped" and pin.current_sha() == newer, "a later sha gets its own try"
    assert rig.db.get("self_update_failed") is None


async def test_a_build_that_raises_counts_as_a_failed_smoke_check(rig: Rig, tmp_path: Path) -> None:
    pin = Pinned(rig, tmp_path)
    target = commit_to_origin(pin.repo, "pipeline/src/new.py", "x = 1\n")

    def broken_sync(_rt: Path) -> None:
        raise RuntimeError("uv sync failed")

    assert pin.daemon.self_update_once(pin.plist, sync=broken_sync, test=pin.check) == "failed"
    assert pin.current_sha() == pin.base and not pin.tested
    assert "uv sync failed" in str(rig.db.get("self_update_failed")) and target in str(rig.db.get("self_update_failed"))


async def test_no_update_during_a_nightly_or_for_non_pipeline_changes(rig: Rig, tmp_path: Path) -> None:
    pin = Pinned(rig, tmp_path)
    commit_to_origin(pin.repo, "docs/b.md", "docs only\n")
    commit_to_origin(pin.repo, "pipeline/monitor/App.swift", "// the monitor app is not the daemon\n")
    assert pin.once() is None and not pin.built and not pin.tested, "only non-pipeline paths changed"
    assert rig.db.get("self_update_pending") is None

    commit_to_origin(pin.repo, "pipeline/src/new.py", "x = 1\n")
    gate = asyncio.Event()

    async def nightly() -> int:
        await gate.wait()
        return 0

    pin.daemon.nightly_task = asyncio.create_task(nightly())
    assert pin.once() is None and not pin.built and not pin.tested, "a nightly is running: nothing is staged"
    assert rig.db.get("self_update_pending") is None and pin.current_sha() == pin.base

    gate.set()
    await pin.daemon.nightly_task
    assert pin.once() == "swapped" and pin.built


def test_with_no_pinned_runtime_nothing_updates(rig: Rig) -> None:
    d = Daemon(rig.engine, Config(remote="origin"), token="t")
    assert d.self_update_once(Path("/nonexistent.plist"), sync=noop_sync, test=ok_test) is None
