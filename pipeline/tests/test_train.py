from __future__ import annotations

import asyncio
import json
import threading
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest

from starpipe import train as train_mod
from starpipe.agent import StageOutcome, StageRequest
from starpipe.daemon import activity
from starpipe.db import Ticket
from starpipe.github import GitHubError

from .fakes import Ci, accepted, sh
from .test_engine import Rig
from .test_ship import advance_develop, ready_ticket

PASS: Ci = [("pr-gate", "linux", "completed", "success")]
RED: Ci = [("pr-gate", "linux", "completed", "failure")]


@pytest.fixture
def rig(tmp_path: Path) -> Rig:
    r = Rig(tmp_path)
    r.engine.config.landing_mode = "batch"
    r.engine.config.batch_window_s = 0
    return r


def train_of(rig: Rig) -> train_mod.Train:
    return train_mod.Train(rig.engine)


def develop_has(rig: Rig, path: str) -> bool:
    sh(rig.engine.repo, "git", "fetch", "-q")
    code = __import__("subprocess").run(["git", "-C", str(rig.engine.repo), "cat-file", "-e", f"origin/develop:{path}"],
                                        capture_output=True, check=False).returncode
    return code == 0


async def test_ready_tickets_land_together_through_one_pr_and_one_ci(rig: Rig) -> None:
    for n in (1, 2, 3):
        ready_ticket(rig, n, f"f{n}.md", f"{n}\n")
    ran_ci_for: list[str] = []
    real = rig.gh.workflow_runs

    def watched(sha: str | None = None, branch: str | None = None, per_page: int = 50) -> list[dict[str, Any]]:
        if sha:
            ran_ci_for.append(sha)
        return real(sha=sha, branch=branch, per_page=per_page)

    rig.gh.workflow_runs = watched  # type: ignore[method-assign]
    await train_of(rig).run_until_idle()
    assert [rig.state(n) for n in (1, 2, 3)] == ["landed"] * 3
    assert sorted(rig.announcer.calls) == [("landed", 1), ("landed", 2), ("landed", 3)], "each member announced once"
    assert len(rig.gh.prs) == 1 and len(set(ran_ci_for)) == 1, "one PR, and CI for one commit, for three tickets"
    pr = next(iter(rig.gh.prs.values()))
    assert all(f"Closes #{n}" in pr["body"] for n in (1, 2, 3))
    assert all(develop_has(rig, f"docs/f{n}.md") for n in (1, 2, 3))
    assert all(rig.gh.issues[n]["state"] == "closed" for n in (1, 2, 3))
    assert all("pipe:landed" in {x["name"] for x in rig.gh.issues[n]["labels"]} for n in (1, 2, 3))
    worktrees = sh(rig.engine.repo, "git", "worktree", "list")
    assert "pipe-batch" not in worktrees and "pipe-1" not in worktrees
    batch = rig.db.batch(1)
    assert batch and batch["state"] == "landed" and rig.db.batch_members(1) == [1, 2, 3]
    assert "pipe/batch-1" in rig.gh.deleted


async def test_tickets_that_become_ready_during_ci_make_the_next_batch(rig: Rig) -> None:
    ready_ticket(rig, 1, "f1.md", "1\n")
    real_sleep = rig.engine.sleep
    added: list[int] = []

    async def sleep(s: float) -> None:
        if not added:  # the first batch is in CI: a second ticket finishes meanwhile
            added.append(2)
            ready_ticket(rig, 2, "f2.md", "2\n")
        await real_sleep(s)

    rig.engine.sleep = sleep
    await train_of(rig).run_until_idle()
    assert rig.state(1) == "landed" and rig.state(2) == "landed"
    assert len(rig.gh.prs) == 2 and rig.db.batch_members(1) == [1] and rig.db.batch_members(2) == [2]


async def test_no_more_than_batch_max_tickets_in_one_batch(rig: Rig) -> None:
    rig.engine.config.batch_max = 2
    for n in (1, 2, 3):
        ready_ticket(rig, n, f"f{n}.md", f"{n}\n")
    await train_of(rig).run_until_idle()
    assert [rig.state(n) for n in (1, 2, 3)] == ["landed"] * 3
    assert rig.db.batch_members(1) == [1, 2] and rig.db.batch_members(2) == [3]


async def test_one_ticket_waits_for_the_window_for_company(rig: Rig) -> None:
    rig.engine.config.batch_window_s = 600
    ready_ticket(rig, 1, "f1.md", "1\n")
    t = train_of(rig)
    assert await t.step() is False and rig.state(1) == "ready"
    rig.now += 601
    assert await t.step() is True and rig.state(1) == "ci"


async def test_a_member_that_conflicts_with_an_earlier_one_waits_for_the_next_batch_and_is_caught_up(rig: Rig) -> None:
    ready_ticket(rig, 1, "shared.md", "from one\n")
    ready_ticket(rig, 2, "shared.md", "from two\n")

    def resolve(req: StageRequest) -> StageOutcome:
        wt = req.contract.worktree
        (wt / "docs" / "shared.md").write_text("from one\nfrom two\n")
        sh(wt, "git", "add", "-A")
        sh(wt, "git", "commit", "-q", "--no-edit")
        req.contract.run_checks({})
        req.contract.submit_change({"summary": "resolved"})
        return accepted(req, "S-conflict")

    rig.agent.on("conflict", resolve)
    await train_of(rig).run_until_idle()
    assert rig.state(1) == "landed" and rig.state(2) == "landed"
    assert rig.db.batch_members(1) == [1], "the first rode alone: the second conflicts with it"
    assert rig.db.batch_members(2) == [] and rig.db.batch(2)["state"] == "abandoned"  # type: ignore[index]  # the catch-up round
    assert rig.db.batch_members(3) == [2], "the second rode in a later batch, on the new develop, once caught up"
    assert [r.stage for r in rig.agent.requests] == ["conflict"]
    sh(rig.engine.repo, "git", "fetch", "-q")
    assert sh(rig.engine.repo, "git", "show", "origin/develop:docs/shared.md") == "from one\nfrom two\n"


async def test_the_clean_members_publish_while_a_conflicted_one_is_still_being_caught_up(rig: Rig) -> None:
    ready_ticket(rig, 1, "shared.md", "from one\n")
    ready_ticket(rig, 2, "shared.md", "from two\n")
    seen: list[int] = []
    release = asyncio.Event()

    t = train_of(rig)
    started = asyncio.Event()

    async def catch_up(n: int) -> None:
        seen.append(len(rig.gh.prs))
        started.set()
        await release.wait()

    t._catch_up = catch_up  # pyright: ignore[reportPrivateUsage]
    real_build = t._build  # pyright: ignore[reportPrivateUsage]

    def build(bid: int, tickets: list[Ticket], base: str) -> train_mod.Built:
        built = real_build(bid, tickets, base)
        built.catch_up, built.deferred = built.deferred, []  # as if #2 conflicted with develop itself
        return built

    t._build = build  # pyright: ignore[reportPrivateUsage]
    assert await t.step() is True
    await started.wait()
    assert seen == [1], "the batch with #1 was already published when #2's catch-up began"
    batch = rig.db.active_batch()
    assert batch is not None and batch["state"] == "ci" and rig.db.batch_members(1) == [1]
    release.set()
    await asyncio.wait(t._catch_ups)  # pyright: ignore[reportPrivateUsage]


async def test_a_red_batch_is_split_until_the_culprit_is_alone_and_the_rest_land(rig: Rig) -> None:
    for n in (1, 2, 3, 4):
        ready_ticket(rig, n, f"f{n}.md", f"{n}\n")

    def ci_for(sha: str) -> Ci:
        code = __import__("subprocess").run(["git", "-C", str(rig.gh.origin), "cat-file", "-e", f"{sha}:docs/f3.md"],
                                            capture_output=True, check=False).returncode
        return RED if code == 0 else PASS  # ticket 3's change is the one that breaks CI

    rig.gh.ci_hook = ci_for

    def fix(req: StageRequest) -> StageOutcome:
        wt = req.contract.worktree
        (wt / "docs" / "f3.md").unlink()
        sh(wt, "git", "add", "-A")
        sh(wt, "git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "drop the breaking file")
        req.contract.run_checks({})
        req.contract.submit_change({"summary": "fixed"})
        return accepted(req, "S-fix")

    rig.agent.on("ci-fix", fix)
    t = train_of(rig)
    await t.run_until_idle()
    assert [rig.state(n) for n in (1, 2, 3, 4)] == ["landed"] * 4
    sizes = [len(rig.db.batch_members(b)) for b in range(1, 7)]
    assert sizes == [4, 2, 2, 1, 1, 1], f"[1,2,3,4] red -> [1,2] green, [3,4] red -> [3] red, [4] green, then the fixed [3]: {sizes}"
    assert [rig.db.batch(b)["state"] for b in range(1, 7)] == ["failed", "landed", "failed", "failed", "landed", "landed"]  # type: ignore[index]
    assert [r.stage for r in rig.agent.requests] == ["ci-fix"]
    assert rig.db.get("train_groups") is None
    assert not develop_has(rig, "docs/f3.md") and develop_has(rig, "docs/f1.md") and develop_has(rig, "docs/f4.md")
    assert any("CI red" in c for _, c in rig.gh.closed_prs), "each red batch's PR was closed with the reason"


async def test_a_ticket_cancelled_while_its_batch_is_in_ci_is_left_out_and_the_others_land(rig: Rig) -> None:
    for n in (1, 2, 3):
        ready_ticket(rig, n, f"f{n}.md", f"{n}\n")
    real_sleep = rig.engine.sleep
    done: list[bool] = []

    async def sleep(s: float) -> None:
        if not done:
            done.append(True)
            rig.db.set_state(2, "cancelled", "cancelled by the owner")
        await real_sleep(s)

    rig.engine.sleep = sleep
    await train_of(rig).run_until_idle()
    assert rig.state(1) == "landed" and rig.state(3) == "landed" and rig.state(2) == "cancelled"
    assert not develop_has(rig, "docs/f2.md"), "the cancelled ticket's change did not land"
    assert rig.db.batch(1)["state"] == "abandoned"  # type: ignore[index]


async def test_develop_moving_with_overlapping_changes_rebuilds_the_batch_on_the_new_base(rig: Rig) -> None:
    ready_ticket(rig, 1, "mine.py", "x = 1\n", folder="pipeline/src")
    real_sleep = rig.engine.sleep
    moved: list[bool] = []

    async def sleep(s: float) -> None:
        if not moved:
            moved.append(True)
            advance_develop_in(rig, "pipeline/src/other.py", "y = 2\n")  # a different file, but the same T1 checks
        await real_sleep(s)

    rig.engine.sleep = sleep
    await train_of(rig).run_until_idle()
    assert rig.state(1) == "landed" and len(rig.gh.prs) == 2, "CI ran again on the rebuilt batch"
    assert rig.db.batch(1)["state"] == "abandoned" and "rebuilding" in rig.db.batch(1)["note"]  # type: ignore[index]


def advance_develop_in(rig: Rig, path: str, text: str) -> None:
    clone = rig.engine.repo.parent / "dev-clone"
    if not clone.exists():
        sh(clone.parent, "git", "clone", "-q", str(rig.gh.origin), str(clone))
        sh(clone, "git", "config", "user.email", "t@t")
        sh(clone, "git", "config", "user.name", "t")
        sh(clone, "git", "checkout", "-q", "develop")
    sh(clone, "git", "pull", "-q", "origin", "develop")
    (clone / path).parent.mkdir(parents=True, exist_ok=True)
    (clone / path).write_text(text)
    sh(clone, "git", "add", "-A")
    sh(clone, "git", "commit", "-q", "-m", f"develop: {path}")
    sh(clone, "git", "push", "-q", "origin", "develop")


async def test_develop_moving_without_overlap_does_not_cost_another_ci(rig: Rig) -> None:
    ready_ticket(rig, 1, "f1.md", "1\n")
    real_sleep = rig.engine.sleep
    moved: list[bool] = []

    async def sleep(s: float) -> None:
        if not moved:
            moved.append(True)
            advance_develop(rig, "elsewhere.md", "unrelated\n")
        await real_sleep(s)

    rig.engine.sleep = sleep
    await train_of(rig).run_until_idle()
    assert rig.state(1) == "landed" and len(rig.gh.prs) == 1 and develop_has(rig, "docs/elsewhere.md")


async def test_the_train_holds_while_develop_is_red_or_landing_is_paused(rig: Rig) -> None:
    ready_ticket(rig, 1, "f1.md", "1\n")
    t = train_of(rig)
    rig.db.put("stop_line", "pr-gate/linux")
    assert await t.step() is False and rig.state(1) == "ready" and rig.gh.prs == {}
    rig.db.put("stop_line", None)
    rig.db.put("pause", "landing")
    assert await t.step() is False
    rig.db.put("pause", None)
    await t.run_until_idle()
    assert rig.state(1) == "landed"


async def test_a_batch_that_is_green_waits_to_merge_while_develop_is_red(rig: Rig) -> None:
    ready_ticket(rig, 1, "f1.md", "1\n")
    real_sleep = rig.engine.sleep
    waits: list[float] = []

    async def sleep(s: float) -> None:
        waits.append(s)
        if rig.db.active_batch() and not rig.db.get("stop_line") and len(waits) == 1:
            rig.db.put("stop_line", "pr-gate/linux")  # develop goes red while the batch is in CI
        elif rig.db.get("stop_line") and len(waits) == 4:
            rig.db.put("stop_line", None)
        await real_sleep(s)

    rig.engine.sleep = sleep
    await train_of(rig).run_until_idle()
    assert rig.state(1) == "landed" and len(waits) >= 4


async def test_after_a_restart_the_train_picks_up_a_batch_that_was_in_ci(rig: Rig) -> None:
    for n in (1, 2):
        ready_ticket(rig, n, f"f{n}.md", f"{n}\n")
    first = train_of(rig)
    await first._start([1, 2])  # pyright: ignore[reportPrivateUsage]
    assert rig.db.active_batch()["state"] == "ci" and rig.state(1) == "ci"  # type: ignore[index]
    rig.engine.issue_memo.clear()
    second = train_of(rig)  # a new process: only the database remains
    await second.run_until_idle()
    assert rig.state(1) == "landed" and rig.state(2) == "landed" and len(rig.gh.prs) == 1


async def test_a_batch_found_still_building_after_a_crash_is_abandoned_and_nothing_is_lost(rig: Rig) -> None:
    ready_ticket(rig, 1, "f1.md", "1\n")
    bid = rig.db.batch_create("0" * 40)
    rig.db.batch_add(bid, 1, 0)
    await train_of(rig).step()
    assert rig.db.batch(bid)["state"] == "abandoned" and rig.state(1) == "ready"  # type: ignore[index]
    await train_of(rig).run_until_idle()
    assert rig.state(1) == "landed"


async def test_a_refused_merge_abandons_the_batch_and_it_lands_on_the_next_try(rig: Rig) -> None:
    ready_ticket(rig, 1, "f1.md", "1\n")
    real = rig.gh.merge_pr
    calls: list[int] = []

    def flaky(number: int, sha: str) -> None:
        calls.append(number)
        if len(calls) == 1:
            raise GitHubError("Base branch was modified")
        real(number, sha)

    rig.gh.merge_pr = flaky  # type: ignore[method-assign]
    await train_of(rig).run_until_idle()
    assert rig.state(1) == "landed" and len(calls) == 2 and len(rig.gh.prs) == 2


async def test_a_merge_that_is_not_on_develop_is_a_phantom_landing_for_every_member(rig: Rig) -> None:
    for n in (1, 2):
        ready_ticket(rig, n, f"f{n}.md", f"{n}\n")
    rig.gh.phantom = True
    await train_of(rig).run_until_idle()
    assert rig.state(1) == "failed" and rig.state(2) == "failed"
    assert any(t == "star pipeline: phantom-landing" for t, _ in rig.pages)


async def test_drive_leaves_ready_and_batched_tickets_to_the_train(rig: Rig) -> None:
    ready_ticket(rig, 1, "f1.md", "1\n")
    await rig.engine.drive(1)
    assert rig.state(1) == "ready" and rig.gh.prs == {}
    await train_of(rig)._start([1])  # pyright: ignore[reportPrivateUsage]
    assert rig.state(1) == "ci"
    await rig.engine.drive(1)  # must not run a second, per-ticket CI for a ticket that is in a batch
    assert rig.state(1) == "ci" and len(rig.gh.prs) == 1


async def test_the_activity_line_names_the_batch(rig: Rig) -> None:
    for n in (1, 2):
        ready_ticket(rig, n, f"f{n}.md", f"{n}\n")
    ticket = rig.db.ticket(1)
    assert ticket and activity(rig.db, ticket) == "ready · waiting for the next batch"
    assert activity(rig.db, ticket, mode="single") == "ready to publish"
    await train_of(rig)._start([1, 2])  # pyright: ignore[reportPrivateUsage]
    ticket = rig.db.ticket(1)
    assert ticket and activity(rig.db, ticket) == "CI · batch #1 (2 tickets together)"


async def test_building_publishing_polling_and_merging_never_block_the_event_loop(rig: Rig) -> None:
    for n in (1, 2):
        ready_ticket(rig, n, f"f{n}.md", f"{n}\n")
    loop = asyncio.get_running_loop()
    blocked: dict[str, bool] = {}

    def watched(name: str, real: Callable[..., Any]) -> Callable[..., Any]:
        def wrapper(*args: Any, **kwargs: Any) -> Any:
            ran = threading.Event()
            loop.call_soon_threadsafe(loop.call_later, 0.2, ran.set)
            blocked[name] = blocked.get(name, False) or not ran.wait(5)
            return real(*args, **kwargs)
        return wrapper

    for name in ("create_pr", "workflow_runs", "pr", "merge_pr"):
        setattr(rig.gh, name, watched(name, getattr(rig.gh, name)))
    await train_of(rig).run_until_idle()
    assert rig.state(1) == "landed" and rig.state(2) == "landed"
    assert blocked == {"create_pr": False, "workflow_runs": False, "pr": False, "merge_pr": False}


async def test_in_single_mode_the_train_does_nothing(rig: Rig) -> None:
    rig.engine.config.landing_mode = "single"
    ready_ticket(rig, 1, "f1.md", "1\n")
    assert await train_of(rig).step() is False and rig.state(1) == "ready"


def test_split_groups_survive_in_the_database_as_json(rig: Rig) -> None:
    rig.db.put("train_groups", json.dumps([[1, 2], [3]]))
    ready_ticket(rig, 1, "f1.md", "1\n")
    ready_ticket(rig, 3, "f3.md", "3\n")
    assert train_of(rig)._pick() == [1]  # pyright: ignore[reportPrivateUsage]  # 2 is not ready; the group shrinks to what is
    assert json.loads(rig.db.get("train_groups") or "[]") == [[3]]


async def test_the_window_counts_from_when_the_ticket_became_ready_not_from_the_last_poll(rig: Rig) -> None:
    """Found live: the issue poll rewrote updated_at every minute, so a ticket never looked 'ready for 120 s' and no batch formed."""
    rig.engine.config.batch_window_s = 600
    ready_ticket(rig, 1, "f1.md", "1\n")
    t = train_of(rig)
    for _ in range(3):
        rig.now += 250
        rig.engine.sync_issues()  # the daemon does this every minute, and it used to refresh updated_at
        if rig.now < 750 + (rig.db.state_since(1, "ready") or 0) - 250:
            assert await t.step() is False
    assert rig.db.state_since(1, "ready") is not None
    assert await t.step() is True and rig.state(1) == "ci", "750 s after it became ready the 600 s window has passed"


def test_a_poll_that_changes_nothing_does_not_move_updated_at(rig: Rig) -> None:
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()
    before = rig.db.ticket(7)
    assert before
    rig.now += 500
    rig.engine.sync_issues()
    again = rig.db.ticket(7)
    assert again and again.updated_at == before.updated_at
    rig.gh.issues[7]["title"] = "a new title"
    rig.now += 100
    rig.engine.sync_issues()
    changed = rig.db.ticket(7)
    assert changed and changed.updated_at > before.updated_at and changed.title == "a new title"


async def test_abandoning_a_batch_cancels_its_queued_ci_runs_too(rig: Rig) -> None:
    """Found live: closed PRs left their Gherkin runs queued, ahead of the batch's own, so CI crawled for hours."""
    for n in (1, 2):
        ready_ticket(rig, n, f"f{n}.md", f"{n}\n")
    real_sleep = rig.engine.sleep
    done: list[bool] = []

    async def sleep(s: float) -> None:
        if not done:
            done.append(True)
            rig.db.set_state(2, "cancelled", "cancelled by the owner")
        await real_sleep(s)

    rig.engine.sleep = sleep
    await train_of(rig).run_until_idle()
    assert "pipe/batch-1" in rig.gh.cancelled_branches, "the abandoned batch's runs were cancelled, not just its PR closed"
    assert rig.gh.closed_prs and rig.state(1) == "landed"
