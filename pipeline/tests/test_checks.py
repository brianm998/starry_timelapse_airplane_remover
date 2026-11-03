from __future__ import annotations

import sys
from pathlib import Path

import pytest

from starpipe import adapter_star as star
from starpipe import heavy, worktrees
from starpipe.checks import runner
from starpipe.config import Config
from starpipe.contracts import Contract
from starpipe.db import Database

from .fakes import GOOD_BODY, make_repo

FAST = Config(heavy_idle_kill_s=1.0, heavy_idle_grace_s=1.0, heavy_idle_poll_s=0.2)


def test_hung_check_is_reported_as_hung(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(heavy, "load", lambda: FAST)
    repo = make_repo(tmp_path)
    db = Database(tmp_path / "s.db")
    db.upsert_ticket(7, "Tidy docs", GOOD_BODY, "brianm998", 2, [])
    wt, branch = worktrees.create(repo, 7, "Tidy docs", "origin/develop")
    db.set_fields(7, worktree=str(wt), branch=branch)
    ticket = db.ticket(7)
    assert ticket
    spec = star.CheckSpec("test:wedged", "a wedged suite", (sys.executable, "-c", "import time;time.sleep(60)"))

    result = runner.run_spec(spec, wt, "origin/develop", tmp_path)
    assert result.status == "hung" and not result.green
    assert "made no progress" in result.detail and "time.sleep(60)" in result.detail and "rerun run_checks" in result.detail
    assert heavy.status().holders == [], "the lock was released"

    told = Contract(ticket, wt, "origin/develop", db, check_runner=lambda _w, _b: [result]).run_checks({})
    assert told.startswith("HUNG test:wedged") and "rerun run_checks" in told
    assert db.checks(7)[0]["result"] == "hung"
