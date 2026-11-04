from __future__ import annotations

import asyncio
import json
import threading
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest

from starpipe import ci as ci_mod
from starpipe import ship
from starpipe import train as train_mod
from starpipe.agent import StageOutcome, StageRequest
from starpipe.daemon import activity
from starpipe.db import Ticket
from starpipe.github import GitHubError

from .fakes import Ci, accepted, sh
from .test_engine import Rig
from .test_ship import advance_develop, ready_ticket, with_gherkin

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


async def test_every_ready_ticket_joins_one_batch(rig: Rig) -> None:
    for n in range(1, 9):
        ready_ticket(rig, n, f"f{n}.md", f"{n}\n")
    await train_of(rig).run_until_idle()
    assert [rig.state(n) for n in range(1, 9)] == ["landed"] * 8
    assert rig.db.batch_members(1) == list(range(1, 9))


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


async def test_develop_moving_with_a_clean_overlap_keeps_the_batch_and_its_pr(rig: Rig) -> None:
    ready_ticket(rig, 1, "mine.py", "x = 1\n", folder="pipeline/src")
    real_sleep = rig.engine.sleep
    moved: list[bool] = []
    first_head: list[str] = []

    async def sleep(s: float) -> None:
        if not moved:
            moved.append(True)
            first_head.append(str(rig.db.batch(1)["head_sha"]))  # type: ignore[index]
            advance_develop_in(rig, "pipeline/src/other.py", "y = 2\n")  # a different file, but the same T1 checks
        await real_sleep(s)

    rig.engine.sleep = sleep
    await train_of(rig).run_until_idle()
    batch = rig.db.batch(1)
    assert batch and batch["state"] == "landed" and rig.db.batch_members(1) == [1], "the same batch landed"
    assert rig.db.batch(2) is None and len(rig.gh.prs) == 1, "no rebuild and no second PR"
    assert batch["head_sha"] != first_head[0], "the batch head is the merge of develop"
    assert rig.state(1) == "landed" and develop_has(rig, "pipeline/src/mine.py") and develop_has(rig, "pipeline/src/other.py")


async def test_develop_moving_with_a_conflicting_overlap_abandons_and_names_the_file(rig: Rig) -> None:
    ready_ticket(rig, 1, "mine.py", "x = 1\n", folder="pipeline/src")
    real_sleep = rig.engine.sleep
    moved: list[bool] = []

    async def sleep(s: float) -> None:
        if not moved:
            moved.append(True)
            advance_develop_in(rig, "pipeline/src/mine.py", "x = 2\n")  # the same file, differently
        await real_sleep(s)

    rig.engine.sleep = sleep
    t = train_of(rig)
    await t.step()
    await t.drain()  # the batch's driver ends with the batch given up; no step follows, so nothing rebuilds it
    batch = rig.db.batch(1)
    assert batch and batch["state"] == "abandoned" and "rebuilding" in batch["note"]
    assert "pipeline/src/mine.py" in batch["note"], "the note names the overlapping file"
    assert rig.gh.prs[int(batch["pr_number"])]["state"] == "closed"
    assert rig.state(1) == "ready"
    status = sh(batch_wt(rig, 1), "git", "status", "--porcelain") if batch_wt(rig, 1).exists() else ""
    assert "UU" not in status and not (batch_wt(rig, 1) / ".git").is_dir()


def batch_wt(rig: Rig, bid: int) -> Path:
    return train_mod.batch_worktree(rig.engine.repo, bid)


def test_the_overlap_note_names_at_most_five_files() -> None:
    files = [f"pipeline/src/f{i}.py" for i in range(7)]
    note = train_mod.overlap_note(train_mod.landing.Overlap(files, ["t1"]))
    assert all(f in note for f in files[:5]) and not any(f in note for f in files[5:]) and note.endswith("and 2 more")
    assert train_mod.overlap_note(train_mod.landing.Overlap(files[:1], [])) == files[0]
    assert "same checks: t1" == train_mod.overlap_note(train_mod.landing.Overlap([], ["t1"]))


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
    t = train_of(rig)
    await t.step()  # the driver gives the batch up while step is looking at the queue, so the ticket is batched again at once
    await t.run_until_idle()
    assert rig.db.batch(bid)["state"] == "abandoned" and rig.state(1) == "landed"  # type: ignore[index]


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


async def test_members_are_recorded_while_building_and_deferred_ones_dropped(rig: Rig) -> None:
    ready_ticket(rig, 1, "same.md", "one\n")
    ready_ticket(rig, 2, "same.md", "two\n")  # conflicts with #1: it waits for the next batch
    ready_ticket(rig, 3, "f3.md", "3\n")
    seen: list[list[int]] = []
    t = train_of(rig)
    real = t._build  # pyright: ignore[reportPrivateUsage]

    def watched(bid: int, tickets: list[Any], base: str) -> Any:
        seen.append(rig.db.batch_members(bid))  # what the monitor reads while the batch is `building`
        return real(bid, tickets, base)

    t._build = watched  # type: ignore[method-assign]  # pyright: ignore[reportPrivateUsage]
    await t._start([1, 2, 3])  # pyright: ignore[reportPrivateUsage]
    assert seen == [[1, 2, 3]]
    assert rig.db.batch_members(1) == [1, 3], "the deferred ticket is no longer shown in the batch"
    assert rig.db.batch_of(2) is None


async def test_the_activity_line_names_the_batch(rig: Rig) -> None:
    for n in (1, 2):
        ready_ticket(rig, n, f"f{n}.md", f"{n}\n")
    ticket = rig.db.ticket(1)
    assert ticket and activity(rig.db, ticket, config=rig.engine.config) == "ready · waiting for the next batch (starting)"
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


async def test_a_feature_run_happens_per_ticket_before_batching_not_per_batch(rig: Rig) -> None:
    ready_ticket(rig, 1, "f1.md", "1\n", body=with_gherkin("autoMovingTiff16"))
    ready_ticket(rig, 2, "f2.md", "2\n", body=with_gherkin("autoHorizonJpeg"))
    rig.gh.feature_pending_polls = 2
    t1, t2 = rig.db.ticket(1), rig.db.ticket(2)
    assert t1 and t2
    at_publish: list[list[tuple[str, str, dict[str, str]]]] = []
    real_create = rig.gh.create_pr

    def create_pr(title: str, body: str, head: str, base: str) -> dict[str, Any]:
        at_publish.append(list(rig.gh.dispatches))
        return real_create(title, body, head, base)

    rig.gh.create_pr = create_pr  # type: ignore[method-assign]
    await train_of(rig).run_until_idle()
    assert sorted((ref, inputs["features"]) for _, ref, inputs in rig.gh.dispatches) == sorted(
        [(t1.branch, "autoMovingTiff16"), (t2.branch, "autoHorizonJpeg")]), "one run per ticket, each on its own branch"
    assert len(at_publish) == 1 and len(at_publish[0]) == 2, "both feature runs were done before the one batch was published"
    assert [rig.state(n) for n in (1, 2)] == ["landed"] * 2 and len(rig.gh.prs) == 1, "still one PR and one CI for the two"
    assert rig.gh.cancelled_runs == []


def test_jobs_carry_their_runner_labels() -> None:
    runs = [{"id": 5, "name": "pr-gate"}]
    jobs = ci_mod.parse_jobs(runs, {5: [{"name": "mac", "status": "queued", "conclusion": None, "labels": ["macos-15"]},
                                         {"name": "linux", "status": "queued", "conclusion": None}]})
    assert [j.labels for j in jobs] == [("macos-15",), ()], "labels come from the job JSON, and are empty when it has none"
    assert [j.queued_for_macos for j in jobs] == [True, False]


async def test_feature_gates_wait_while_batch_macos_jobs_are_queued(rig: Rig) -> None:
    ready_ticket(rig, 1, "b1.md", "1\n")
    rig.gh.job_labels["macos"] = ["macos-15"]
    polls: list[int] = []  # feature runs dispatched so far, at each poll of the batch's CI

    def hook(_sha: str) -> Ci:
        polls.append(len(rig.gh.dispatches))
        linux: Ci = [("pr-gate", "linux", "completed", "success")]
        if len(polls) <= 3:  # a macOS job still waiting for a runner
            return [*linux, ("pr-gate", "macos", "queued", None)]
        if len(polls) <= 5:  # running now: no longer queued
            return [*linux, ("pr-gate", "macos", "in_progress", None)]
        return PASS

    rig.gh.ci_hook = hook
    real_sleep = rig.engine.sleep
    added: list[int] = []

    async def sleep(s: float) -> None:
        if not added:  # the batch is in CI: a ticket that owes a feature run becomes ready meanwhile
            added.append(2)
            ready_ticket(rig, 2, "f2.md", "2\n", body=with_gherkin("autoMovingTiff16"))
        await real_sleep(s)

    rig.engine.sleep = sleep
    await train_of(rig).run_until_idle()
    assert polls[:4] == [0, 0, 0, 0], f"no feature run started while a macOS job was queued: {polls}"
    assert polls[-1] == 1, f"it started once nothing was queued, while the batch was still in CI: {polls}"
    assert len(rig.gh.dispatches) == 1 and rig.gh.cancelled_runs == [], "dispatched once, never cancelled or redone"
    deferred = [e for e in rig.db.events_since() if e["kind"] == "gate-deferred"]
    assert [(e["ticket"], e["data"]["batch"], e["data"]["queued_macos"]) for e in deferred] == [(2, 1, 1)], "reported once"
    assert [rig.state(n) for n in (1, 2)] == ["landed", "landed"]


async def test_a_feature_run_already_going_is_left_alone_while_macos_jobs_are_queued(rig: Rig) -> None:
    ready_ticket(rig, 1, "f1.md", "1\n", body=with_gherkin("autoMovingTiff16"))
    train = train_of(rig)
    batch = rig.db.batch_create("base")
    train._macos_queued[batch] = 2  # pyright: ignore[reportPrivateUsage]
    going = asyncio.get_running_loop().create_future()
    train._gates[1] = going  # type: ignore[assignment]  # pyright: ignore[reportPrivateUsage]
    train._start_gates()  # pyright: ignore[reportPrivateUsage]
    assert train._gates[1] is going and not going.cancelled() and rig.gh.dispatches == []  # pyright: ignore[reportPrivateUsage]
    del train._gates[1]  # pyright: ignore[reportPrivateUsage]
    rig.db.batch_update(batch, state="abandoned")  # no batch active: nothing holds the run back
    train._start_gates()  # pyright: ignore[reportPrivateUsage]
    assert 1 in train._gates  # pyright: ignore[reportPrivateUsage]
    await asyncio.wait(list(train._gates.values()))  # pyright: ignore[reportPrivateUsage]


async def test_a_ticket_still_owing_a_feature_run_is_not_batched(rig: Rig) -> None:
    ready_ticket(rig, 1, "f1.md", "1\n", body=with_gherkin("autoMovingTiff16"))
    train = train_of(rig)
    assert train._gated(rig.db.ticket(1)) and train._pick() == []  # type: ignore[arg-type]  # pyright: ignore[reportPrivateUsage]
    rig.db.put("gherkin_ok:1", "x")
    assert train._pick() == [1]  # pyright: ignore[reportPrivateUsage]


def _land_one(rig: Rig, ci: Ci) -> None:
    ready_ticket(rig, 1, "f1.md", "1\n")
    rig.gh.ci_hook = lambda sha: ci


def _merge_sha(rig: Rig) -> str:
    return str(next(iter(rig.gh.prs.values()))["merge_commit_sha"])


async def test_a_landed_batch_seeds_the_develop_baseline_from_its_pr(rig: Rig) -> None:
    _land_one(rig, [*PASS, ("cli", "macos", "completed", "success"), ("cli", "windows", "completed", "skipped"),
                    ("Gherkin", "full", "completed", "failure"), ("cli", "linux", "completed", "success")])
    rig.db.set_baseline("cli", "linux", "old", "failure")
    await train_of(rig).run_until_idle()
    merge = _merge_sha(rig)
    assert rig.state(1) == "landed"
    assert (rig.db.baseline("pr-gate", "linux"), rig.db.baseline_sha("pr-gate", "linux")) == ("success", merge)
    assert (rig.db.baseline("cli", "macos"), rig.db.baseline_sha("cli", "macos")) == ("success", merge)
    assert rig.db.baseline("cli", "linux") == "success", "an older baseline is replaced"
    assert rig.db.baseline("cli", "windows") is None, "a skipped job says nothing"
    assert rig.db.baseline("Gherkin", "full") is None, "post-merge-only workflows are not seeded"
    # a develop run newer than the merge is not overwritten, and running the bookkeeping again changes nothing
    advance_develop(rig, "later.md", "later\n")
    sh(rig.engine.repo, "git", "fetch", "-q")
    later = sh(rig.engine.repo, "git", "rev-parse", "origin/develop").strip()
    rig.db.set_baseline("cli", "macos", later, "failure")
    train_of(rig)._finish(1, merge)  # pyright: ignore[reportPrivateUsage]
    assert (rig.db.baseline("cli", "macos"), rig.db.baseline_sha("cli", "macos")) == ("failure", later)
    assert (rig.db.baseline("pr-gate", "linux"), rig.db.baseline_sha("pr-gate", "linux")) == ("success", merge)


async def test_a_red_pr_job_seeded_on_landing_files_no_regression(rig: Rig) -> None:
    _land_one(rig, [*PASS, ("cli", "macos", "completed", "failure")])
    rig.db.set_baseline("cli", "macos", "old", "failure")  # red on develop already: that is why the PR was judged green
    rig.db.set_baseline("pr-gate", "linux", "old", "success")
    await train_of(rig).run_until_idle()
    assert rig.state(1) == "landed" and rig.db.baseline("cli", "macos") == "failure"
    rig.gh.develop_sha = _merge_sha(rig)
    rig.gh.develop_ci = [*PASS, ("cli", "macos", "completed", "failure")]
    ship.watch_develop(rig.engine)
    assert rig.db.get("red_pending:cli/macos") is None and rig.db.get("stop_line") is None
    assert list(rig.gh.issues) == [1], "only the ticket itself: no regression ticket was filed"


async def test_land_now_skips_the_window_ci_and_the_stop_line(rig: Rig) -> None:
    rig.engine.config.batch_window_s = 10_000  # nothing would batch for hours
    rig.gh.ci_hook = lambda sha: RED  # and CI would fail
    rig.db.put("stop_line", "pr-gate/linux")
    ready_ticket(rig, 1, "f1.md", "1\n")
    t = train_of(rig)
    assert await t.step() is False and rig.state(1) == "ready", "without the mark the ticket waits"
    rig.db.put("land_now:1", "1")
    await t.run_until_idle()
    assert rig.state(1) == "landed" and develop_has(rig, "docs/f1.md")


async def test_a_land_now_ticket_does_not_wait_for_the_ci_of_unflagged_batch_mates(rig: Rig) -> None:
    rig.engine.config.batch_window_s = 10_000
    rig.gh.ci_hook = lambda sha: RED
    for n in (1, 2):
        ready_ticket(rig, n, f"f{n}.md", f"{n}\n")
    t = train_of(rig)
    await t._start([1, 2])  # pyright: ignore[reportPrivateUsage]
    rig.db.put("land_now:2", "1")
    await t.step()
    await t.run_until_idle()  # the mixed batch is given up and the flagged ticket goes alone
    assert rig.db.batch(1)["state"] == "abandoned" and rig.db.batch_members(2) == [2]  # type: ignore[index]
    assert rig.state(2) == "landed" and rig.state(1) != "landed"


# two batches at once -------------------------------------------------------------------------------------------------
PENDING: Ci = [("pr-gate", "linux", "in_progress", None)]


def has_file(rig: Rig, sha: str, path: str) -> bool:
    return __import__("subprocess").run(["git", "-C", str(rig.gh.origin), "cat-file", "-e", f"{sha}:{path}"],
                                        capture_output=True, check=False).returncode == 0


def hold_polls(rig: Rig) -> asyncio.Event:
    """Every sleep (the CI poll above all) blocks until the returned event is set, so a batch stays in CI while the test looks."""
    gate = asyncio.Event()
    real_sleep = rig.engine.sleep

    async def sleep(s: float) -> None:
        await gate.wait()
        await real_sleep(s)

    rig.engine.sleep = sleep
    return gate


async def test_a_disjoint_batch_starts_while_another_is_in_ci(rig: Rig) -> None:
    ready_ticket(rig, 1, "f1.md", "1\n")
    rig.gh.ci_hook = lambda sha: PENDING
    gate = hold_polls(rig)
    t = train_of(rig)
    assert await t.step() is True
    assert [b["id"] for b in rig.db.active_batches()] == [1] and rig.db.batch(1)["state"] == "ci"  # type: ignore[index]
    ready_ticket(rig, 2, "f2.md", "2\n")  # finishes while batch 1 is in CI, and shares no file with it
    assert await t.step() is True
    assert [(b["id"], b["state"]) for b in rig.db.active_batches()] == [(1, "ci"), (2, "ci")]
    assert rig.db.batch_members(1) == [1] and rig.db.batch_members(2) == [2] and len(rig.gh.prs) == 2
    assert batch_wt(rig, 1).is_dir() and batch_wt(rig, 2).is_dir() and batch_wt(rig, 1) != batch_wt(rig, 2)
    assert {rig.db.batch(b)["branch"] for b in (1, 2)} == {"pipe/batch-1", "pipe/batch-2"}  # type: ignore[index]
    ready_ticket(rig, 3, "f3.md", "3\n")
    assert await t.step() is False and rig.state(3) == "ready", "a third batch is never formed: batch_parallel is 2"
    rig.gh.ci_hook = lambda sha: PASS
    gate.set()
    await t.run_until_idle()
    assert [rig.state(n) for n in (1, 2, 3)] == ["landed"] * 3 and rig.db.batch_members(3) == [3], "#3 rode once a slot was free"


async def test_batch_parallel_one_keeps_the_train_single_file(rig: Rig) -> None:
    rig.engine.config.batch_parallel = 1
    ready_ticket(rig, 1, "f1.md", "1\n")
    rig.gh.ci_hook = lambda sha: PENDING
    gate = hold_polls(rig)
    t = train_of(rig)
    await t.step()
    ready_ticket(rig, 2, "f2.md", "2\n")
    assert await t.step() is False and [b["id"] for b in rig.db.active_batches()] == [1] and rig.state(2) == "ready"
    rig.gh.ci_hook = lambda sha: PASS
    gate.set()
    await t.run_until_idle()
    assert rig.state(1) == "landed" and rig.state(2) == "landed" and rig.db.batch_members(2) == [2]


async def test_an_overlapping_ticket_waits_for_the_batch_in_ci(rig: Rig) -> None:
    ready_ticket(rig, 1, "shared.md", "one\n")
    rig.gh.ci_hook = lambda sha: PENDING
    gate = hold_polls(rig)
    t = train_of(rig)
    await t.step()
    ready_ticket(rig, 2, "shared.md", "two\n")  # the same file batch 1 changes
    ready_ticket(rig, 3, "f3.md", "3\n")
    assert await t.step() is True
    assert rig.db.batch_members(2) == [3], "the disjoint ticket went beside batch 1; the overlapping one stayed out"
    assert rig.state(2) == "ready" and rig.db.batch_of(2) is None
    rig.gh.ci_hook = lambda sha: PASS
    gate.set()
    await t.drain()
    assert rig.state(1) == "landed" and rig.state(3) == "landed" and rig.state(2) == "ready"
    assert rig.db.batch(3) is None, "no batch for #2 was formed while it overlapped one in flight"


async def test_a_split_group_overlapping_a_batch_in_flight_waits_for_it(rig: Rig) -> None:
    ready_ticket(rig, 1, "shared.md", "one\n")
    ready_ticket(rig, 2, "f2.md", "2\n")
    ready_ticket(rig, 3, "f3.md", "3\n")
    bid = rig.db.batch_create("0" * 40)
    rig.db.batch_update(bid, state="ci")
    rig.db.batch_add(bid, 3, 0)
    rig.db.set_state(3, "ci")
    rig.db.put("train_groups", json.dumps([[1, 2]]))
    t = train_of(rig)
    assert t._pick({1: frozenset({"docs/shared.md"}), 2: frozenset({"docs/f2.md"}), 3: frozenset({"docs/shared.md"})}) == []  # pyright: ignore[reportPrivateUsage]
    assert json.loads(rig.db.get("train_groups") or "[]") == [[1, 2]], "the group is kept whole"
    assert t._pick({1: frozenset({"docs/f1.md"}), 2: frozenset({"docs/f2.md"}), 3: frozenset({"docs/f3.md"})}) == [1, 2]  # pyright: ignore[reportPrivateUsage]
    assert rig.db.get("train_groups") is None


@pytest.mark.parametrize("first,folder", [(1, "docs"), (2, "docs"), (1, "pipeline/src"), (2, "pipeline/src")])
async def test_two_batches_land_in_either_order(rig: Rig, first: int, folder: str) -> None:
    ext = "md" if folder == "docs" else "py"
    files = {1: f"{folder}/f1.{ext}", 2: f"{folder}/f2.{ext}"}
    ready_ticket(rig, 1, f"f1.{ext}", "1\n", folder=folder)
    # CI for the batch that must land second stays pending until the other has landed (its catch-up merge then carries the other's file)
    rig.gh.ci_hook = lambda sha: PASS if has_file(rig, sha, files[first]) or rig.state(first) == "landed" else PENDING
    gate = hold_polls(rig)
    t = train_of(rig)
    await t.step()
    ready_ticket(rig, 2, f"f2.{ext}", "2\n", folder=folder)
    await t.step()
    assert len(rig.db.active_batches()) == 2
    gate.set()
    await t.run_until_idle()
    assert rig.state(1) == "landed" and rig.state(2) == "landed"
    assert [rig.db.batch(b)["state"] for b in (1, 2)] == ["landed", "landed"] and rig.db.batch(3) is None  # type: ignore[index]
    assert len(rig.gh.prs) == 2 and develop_has(rig, files[1]) and develop_has(rig, files[2])
    assert not batch_wt(rig, 1).exists() and not batch_wt(rig, 2).exists()
    caught_up = [e["data"]["batch"] for e in rig.db.events_since() if e["kind"] == "batch-caught-up"]
    late = 2 if first == 1 else 1
    # the same T1 checks under pipeline/src: develop moved under the second batch with overlapping checks, so it ran CI again
    assert caught_up == ([late] if folder == "pipeline/src" else [])


async def test_restart_resumes_both_batches(rig: Rig) -> None:
    ready_ticket(rig, 1, "f1.md", "1\n")
    rig.gh.ci_hook = lambda sha: PENDING
    real_sleep = rig.engine.sleep
    hold_polls(rig)
    first = train_of(rig)
    await first.step()
    ready_ticket(rig, 2, "f2.md", "2\n")
    await first.step()
    assert [b["state"] for b in rig.db.active_batches()] == ["ci", "ci"]
    for task in list(first._drivers.values()):  # pyright: ignore[reportPrivateUsage]
        task.cancel()  # the daemon dies
    await asyncio.gather(*first._drivers.values(), return_exceptions=True)  # pyright: ignore[reportPrivateUsage]
    rig.engine.issue_memo.clear()
    rig.engine.sleep = real_sleep
    rig.gh.ci_hook = lambda sha: PASS
    second = train_of(rig)  # a new process: only the database and the worktrees remain
    assert await second.step() is True and len(second._drivers) == 2  # pyright: ignore[reportPrivateUsage]
    await second.run_until_idle()
    assert rig.state(1) == "landed" and rig.state(2) == "landed" and len(rig.gh.prs) == 2 and rig.db.batch(3) is None
