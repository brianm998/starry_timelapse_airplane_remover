"""GitHub's limit is 5,000 requests an hour per token, and every ticket in CI polls. These keep the pipeline's share small."""

from __future__ import annotations

import json
from collections.abc import Sequence
from pathlib import Path
from typing import Any

import pytest

from starpipe import ci, gitutil
from starpipe.config import Config
from starpipe.github import GitHub

from .test_engine import Rig
from .test_ship import ready_ticket


class Counting:
    """A gh runner that answers `actions/runs/<id>/jobs` and counts the calls."""

    def __init__(self) -> None:
        self.paths: list[str] = []

    def __call__(self, args: Sequence[str], stdin: str | None) -> str:
        path = args[-1]
        self.paths.append(path)
        return json.dumps({"jobs": [{"name": "j", "status": "completed", "conclusion": "success"}]})


def test_a_completed_runs_jobs_are_fetched_once_per_version() -> None:
    runner = Counting()
    gh = GitHub(Config(), runner)
    version = ci.run_version({"status": "completed", "run_attempt": 1, "updated_at": "2026-10-31T10:00:00Z"})
    assert version == "1:2026-10-31T10:00:00Z"
    for _ in range(5):
        assert gh.run_jobs(7, version)[0]["name"] == "j"
    assert len(runner.paths) == 1

    rerun = ci.run_version({"status": "completed", "run_attempt": 2, "updated_at": "2026-10-31T11:00:00Z"})
    gh.run_jobs(7, rerun)
    assert len(runner.paths) == 2, "a rerun changes the attempt, so the old answer is not reused"


def test_a_run_that_is_still_going_is_never_cached() -> None:
    runner = Counting()
    gh = GitHub(Config(), runner)
    assert ci.run_version({"status": "in_progress", "run_attempt": 1, "updated_at": "x"}) is None
    gh.run_jobs(7, None)
    gh.run_jobs(7, None)
    assert len(runner.paths) == 2


def test_the_ci_poll_interval_grows_with_the_age_of_the_push() -> None:
    delays = [ci.poll_delay(age, 60) for age in (0, 9 * 60, 11 * 60, 29 * 60, 31 * 60, 119 * 60, 121 * 60, 10 * 3600)]
    assert delays == [60, 60, 120, 120, 180, 180, 300, 300]


class CountingGitHub:
    """Wraps the fake so tests can see which per-issue calls the sync makes."""

    @staticmethod
    def wrap(rig: Rig) -> dict[str, int]:
        calls = {"timeline": 0, "blocked_by": 0}
        real_timeline, real_blocked = rig.gh.timeline, rig.gh.blocked_by

        def timeline(n: int) -> list[dict[str, Any]]:
            calls["timeline"] += 1
            return real_timeline(n)

        def blocked_by(n: int) -> list[int]:
            calls["blocked_by"] += 1
            return real_blocked(n)

        rig.gh.timeline = timeline  # type: ignore[method-assign]
        rig.gh.blocked_by = blocked_by  # type: ignore[method-assign]
        return calls


@pytest.fixture
def rig(tmp_path: Path) -> Rig:
    return Rig(tmp_path)


def test_an_unchanged_issue_costs_no_timeline_or_dependency_calls(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.gh.issues[7]["updated_at"] = "2026-10-31T10:00:00Z"
    calls = CountingGitHub.wrap(rig)
    for _ in range(4):
        rig.engine.sync_issues()
    assert calls == {"timeline": 1, "blocked_by": 1}
    assert rig.db.ticket(7) is not None

    rig.gh.issues[7]["updated_at"] = "2026-10-31T10:05:00Z"  # something changed on GitHub
    rig.engine.sync_issues()
    assert calls == {"timeline": 2, "blocked_by": 2}


def test_losing_the_label_is_still_noticed_through_the_memo(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.gh.issues[7]["updated_at"] = "2026-10-31T10:00:00Z"
    rig.engine.sync_issues()
    rig.gh.issues[7]["labels"] = []  # the owner removes `pipeline`: the issue also drops out of the labelled listing
    rig.gh.issues[7]["updated_at"] = "2026-10-31T10:10:00Z"
    rig.engine.sync_issues()
    assert rig.state(7) == "cancelled"


def test_an_outsiders_issue_stays_untrusted_through_the_memo(rig: Rig) -> None:
    rig.gh.add_issue(8, "from outside", author="stranger")
    rig.gh.timelines[8] = []
    rig.gh.issues[8]["updated_at"] = "2026-10-31T10:00:00Z"
    for _ in range(3):
        rig.engine.sync_issues()
    assert rig.db.ticket(8) is None


async def test_ci_polling_backs_off_while_pending_and_still_lands(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n")
    t = rig.db.ticket(1)
    assert t
    sha = gitutil.head_sha(Path(t.worktree or ""))
    rig.gh.ci[sha] = [("pr-gate", "linux", "in_progress", None)]
    real_sleep = rig.engine.sleep
    waits: list[float] = []

    async def sleep(s: float) -> None:
        waits.append(s)
        if sum(waits) > 3 * 3600:  # CI finally finishes, three hours after the push
            rig.gh.ci[sha] = [("pr-gate", "linux", "completed", "success")]
        await real_sleep(s)

    rig.engine.sleep = sleep
    await rig.engine.drive(1)
    assert rig.state(1) == "landed"
    assert waits[0] == 60 and max(waits) == 300 and 120 in waits and 180 in waits
    assert waits == sorted(waits), "it only ever backs off"
    assert len(waits) < 80, "an hour-by-hour poll at 60 s would have taken 180+ calls"
