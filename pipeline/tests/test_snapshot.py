from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
from typing import Any

import pytest
from aiohttp.test_utils import TestClient, TestServer

from starpipe import heavy
from starpipe.config import Config
from starpipe.daemon import Daemon, group_of

from .test_engine import Rig

FIXTURE = Path(__file__).resolve().parents[1] / "monitor" / "Tests" / "StarPipeMonitorTests" / "Fixtures" / "snapshot.json"
AUTH = {"Authorization": "Bearer tok"}


@pytest.fixture
def rig(tmp_path: Path) -> Rig:
    return Rig(tmp_path)


def populate(rig: Rig) -> Daemon:
    """One ticket in every sidebar group."""
    for n, title in [(1, "needs an answer"), (2, "being developed"), (3, "waiting in CI"), (4, "in the queue"),
                     (5, "landed this morning"), (6, "gave up")]:
        rig.gh.add_issue(n, title)
    rig.engine.sync_issues()
    rig.db.add_question(1, "explore", "Which of the two?", {})
    rig.db.set_state(1, "needs-input", "waiting on the owner")
    rig.db.set_state(2, "developing")
    sid = rig.db.begin_stage(2, "develop", 1, "opus")
    rig.db.set_session(sid, "abc")
    rig.db.set_state(3, "ci")
    rig.db.set_state(5, "landed")
    rig.db.set_state(6, "failed", "CI still red after 2 fix cycles")
    rig.db.set_baseline("pr-gate", "linux", "abc", "success")
    rig.db.set_baseline("cli", "windows", "abc", "failure")
    rig.db.intervention(1, "answer", "explore")
    return Daemon(rig.engine, Config(), token="tok")


def test_group_assignment(rig: Rig) -> None:
    d = populate(rig)
    snap = d.snapshot()
    groups = {t["number"]: t["group"] for t in snap["tickets"]}  # type: ignore[index, union-attr]
    assert groups == {1: "needs_you", 2: "running", 3: "waiting", 4: "queued", 5: "landed_today", 6: "failed"}


def test_a_stage_waiting_for_the_heavy_lock_is_waiting_not_running(rig: Rig, monkeypatch: pytest.MonkeyPatch) -> None:
    d = populate(rig)
    queued = heavy.Waiter(1, 0.0, 4242, 0.0, "2", "swift test")
    monkeypatch.setattr(heavy, "status", lambda: heavy.Status([], [queued]))
    groups = {t["number"]: t["group"] for t in d.snapshot()["tickets"]}  # type: ignore[index, union-attr]
    assert groups[2] == "waiting"


def test_old_landed_and_failed_tickets_drop_off(rig: Rig) -> None:
    rig.gh.add_issue(1, "old")
    rig.engine.sync_issues()
    t = rig.db.ticket(1)
    assert t
    assert group_of(t, False, 10 * 24 * 3600.0, 0.0) == "queued"  # queued is always shown...
    rig.db.set_state(1, "landed")
    t = rig.db.ticket(1)
    assert t
    assert group_of(t, False, 3 * 24 * 3600.0, 0.0) is None  # ...but landed only for a day
    assert group_of(t, False, 3600.0, 0.0) == "landed_today"


def test_the_snapshot_carries_develop_landing_and_interventions(rig: Rig) -> None:
    d = populate(rig)
    rig.db.put("stop_line", "pr-gate/linux")
    snap = d.snapshot()
    assert snap["develop"] == {"gate": {"linux": "success"}, "known_red": 1}
    assert snap["landing"] == {"paused": False, "stop_line": "pr-gate/linux"}
    assert snap["interventions_week"] == {"answer": 1}
    assert snap["events_cursor"] >= 1  # type: ignore[operator]


def test_the_snapshot_has_the_shape_the_monitors_fixture_records(rig: Rig) -> None:
    """The Swift tests decode FIXTURE. If the daemon's snapshot gains or loses a key, this fails until the fixture and the
    Swift models are updated together. Regenerate with STARPIPE_REGEN_FIXTURE=1."""
    snap = json.loads(json.dumps(populate(rig).snapshot()))
    snap["heavy"] = {"holders": [{"pid": 4242, "ticket": "2", "cmd": "swift test --package-path StarCore", "since": 1.0}],
                     "queue": [{"priority": 1, "enqueued_at": 2.0, "pid": 4343, "started": 2.0, "ticket": "3",
                                "cmd": "xcodebuild -scheme star"}]}
    snap["daemon"] = {"pid": 1, "since": 1000.0, "last_poll": 1100.0, "error": ""}
    snap["runtime"] = {"sha": "abc1234", "behind_develop": 2}
    snap["now"] = 2000.0
    for t in snap["tickets"]:
        t["worktree"] = f"/work/pipe-{t['number']}" if t["worktree"] else None
        for s in t["stages"]:
            s["started"], s["ended"] = 1000.0, (1060.0 if s["ended"] else None)
    if os.environ.get("STARPIPE_REGEN_FIXTURE"):
        FIXTURE.write_text(json.dumps(snap, indent=2, sort_keys=True) + "\n")
    recorded: dict[str, Any] = json.loads(FIXTURE.read_text())

    def shape(value: Any) -> Any:
        if isinstance(value, dict):
            return {k: shape(v) for k, v in sorted(value.items())}  # pyright: ignore[reportUnknownVariableType, reportUnknownArgumentType]
        if isinstance(value, list):
            return [shape(value[0])] if value else []  # pyright: ignore[reportUnknownArgumentType]
        return type(value).__name__ if value is not None else "null"

    top = {k for k in recorded} ^ {k for k in snap}
    assert top == set(), f"top-level keys differ: {top}"
    ticket_keys = set(snap["tickets"][0]) ^ set(recorded["tickets"][0])
    assert ticket_keys == set(), f"ticket keys differ: {ticket_keys}"
    ours = next(t for t in snap["tickets"] if t["stages"])["stages"][0]
    assert set(ours) ^ set(next(t for t in recorded["tickets"] if t["stages"])["stages"][0]) == set()
    assert shape(recorded["heavy"]) == shape(snap["heavy"])


async def test_snapshot_endpoint_and_log_tail(rig: Rig) -> None:
    d = populate(rig)
    logs = Path(os.environ["STARPIPE_HOME"]) / "tickets" / "2" / "transcripts"
    logs.mkdir(parents=True)
    (logs / "develop-1.jsonl").write_text(
        "\n".join(json.dumps({"t": 1000.0 + i, "type": "AssistantMessage", "repr": f"line {i}"}) for i in range(5)) + "\n")
    client = TestClient(TestServer(d.app()))
    await client.start_server()
    try:
        data = await (await client.get("/v1/snapshot", headers=AUTH)).json()
        assert [t["number"] for t in data["tickets"]][:2] == [1, 2] and "runtime" in data
        tail = await (await client.get("/v1/tickets/2/log?lines=3", headers=AUTH)).json()
        assert len(tail["lines"]) == 3 and tail["lines"][-1].endswith("line 4")
        assert (await client.get("/v1/snapshot")).status == 401
    finally:
        await client.close()


async def test_the_event_stream_delivers_new_events_and_resumes_from_an_id(rig: Rig) -> None:
    d = populate(rig)
    first = rig.db.events_since(0)[0]["id"]
    client = TestClient(TestServer(d.app()))
    await client.start_server()
    try:
        resp = await client.get(f"/v1/events?after={first}", headers={**AUTH, "Accept": "text/event-stream"})
        assert resp.headers["Content-Type"].startswith("text/event-stream")
        got: list[dict[str, Any]] = []

        async def read() -> None:
            async for raw in resp.content:
                line = raw.decode().strip()
                if line.startswith("data: "):
                    got.append(json.loads(line[6:]))
                    if len(got) >= 2:
                        return

        await asyncio.wait_for(read(), 10)
        assert got[0]["id"] > first, "events at or before the resume id are not replayed"
        rig.db.event("probe", 2, note="live")
        resp.close()
    finally:
        await client.close()
