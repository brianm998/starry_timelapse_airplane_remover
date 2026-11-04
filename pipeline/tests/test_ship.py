from __future__ import annotations

import asyncio
import json
import subprocess
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import pytest

from starpipe import ci, gitutil, landing, ship, worktrees
from starpipe.agent import StageOutcome, StageRequest
from starpipe.github import GitHubError

from .fakes import GOOD_BODY, FakeGitHub, accepted, sh
from .test_engine import Rig

PLAN = json.dumps({"summary": "A planned change.", "acceptance": [{"id": "A1", "check": "review: x"}],
                   "tests": {"none_reason": "docs"}})


@pytest.fixture
def rig(tmp_path: Path) -> Rig:
    return Rig(tmp_path)


def with_gherkin(value: str) -> str:
    """GOOD_BODY with a Pipeline section naming Gherkin features."""
    return f"{GOOD_BODY}\n## Pipeline\ngherkin: {value}\n"


def ready_ticket(rig: Rig, n: int, file: str, text: str, folder: str = "docs", body: str = GOOD_BODY) -> None:
    """A ticket that has finished REVIEW: a worktree with one commit and a plan, in state `ready`."""
    rig.gh.add_issue(n, f"change {file}", body)
    rig.engine.sync_issues()
    t = rig.engine.claim(rig.db.ticket(n))  # type: ignore[arg-type]
    wt = Path(t.worktree or "")
    (wt / folder).mkdir(parents=True, exist_ok=True)
    (wt / folder / file).write_text(text)
    sh(wt, "git", "add", "-A")
    sh(wt, "git", "commit", "-q", "-m", f"change {file}")
    rig.db.set_fields(n, plan_json=PLAN)
    rig.db.set_state(n, "ready")


def advance_develop(rig: Rig, file: str, text: str) -> None:
    clone = rig.engine.repo.parent / "dev-clone"
    if not clone.exists():
        sh(clone.parent, "git", "clone", "-q", str(rig.gh.origin), str(clone))
        sh(clone, "git", "config", "user.email", "t@t")
        sh(clone, "git", "config", "user.name", "t")
        sh(clone, "git", "checkout", "-q", "develop")
    sh(clone, "git", "pull", "-q", "origin", "develop")
    (clone / "docs").mkdir(exist_ok=True)
    (clone / "docs" / file).write_text(text)
    sh(clone, "git", "add", "-A")
    sh(clone, "git", "commit", "-q", "-m", f"develop: {file}")
    sh(clone, "git", "push", "-q", "origin", "develop")


def origin_has(rig: Rig, n: int) -> bool:
    t = rig.db.ticket(n)
    assert t and t.branch
    sh(rig.engine.repo, "git", "fetch", "-q")
    return subprocess.run(["git", "-C", str(rig.engine.repo), "merge-base", "--is-ancestor", f"refs/heads/{t.branch}",
                           "origin/develop"], capture_output=True, check=False).returncode == 0


async def test_two_tickets_land_in_order_and_clean_up(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n")
    ready_ticket(rig, 2, "two.md", "two\n")
    await rig.engine.drive(1)
    assert rig.state(1) == "landed"
    await rig.engine.drive(2)
    assert rig.state(2) == "landed"  # develop moved under it, but the files do not overlap: no retest, no conflict
    log = sh(rig.engine.repo, "git", "log", "--oneline", "origin/develop")
    assert "Merge PR" in log
    assert (rig.engine.repo / ".claude" / "worktrees" / "pipe-1").exists() is False
    assert rig.gh.issues[1]["state"] == "closed" and "pipe:landed" in [x["name"] for x in rig.gh.issues[1]["labels"]]
    assert rig.gh.deleted == ["pipe/1-change-one-md", "pipe/2-change-two-md"]
    assert "Closes #1" in rig.gh.prs[101]["body"]
    assert not [r for r in rig.agent.requests if r.stage == "conflict"]


async def test_a_job_develop_also_fails_does_not_block_and_is_listed(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n")
    rig.db.set_baseline("cli", "windows", "abc", "failure")
    t = rig.db.ticket(1)
    assert t
    sha = gitutil.head_sha(Path(t.worktree or ""))
    rig.gh.ci[sha] = [("pr-gate", "linux", "completed", "success"), ("cli", "windows", "completed", "failure")]
    await rig.engine.drive(1)
    assert rig.state(1) == "landed"
    assert "known red on develop (not blocking): cli/windows" in rig.gh.prs[101]["body"]


async def test_a_new_failure_in_another_workflow_blocks(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n")
    rig.db.set_baseline("cli", "windows", "abc", "success")
    t = rig.db.ticket(1)
    assert t
    rig.gh.ci[gitutil.head_sha(Path(t.worktree or ""))] = [("pr-gate", "linux", "completed", "success"),
                                                          ("cli", "windows", "completed", "failure")]
    await rig.engine.drive(1)
    assert rig.state(1) == "failed"
    assert [r.stage for r in rig.agent.requests].count("ci-fix") == 3  # one attempt ladder, no result


async def test_a_pr_that_breaks_pr_gate_gets_a_ci_fix_and_then_lands(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n")
    t = rig.db.ticket(1)
    assert t
    wt = Path(t.worktree or "")
    broken = gitutil.head_sha(wt)
    rig.gh.ci[broken] = [("pr-gate", "linux", "completed", "failure")]
    rig.gh.logs[1000] = "swift test: testOne failed: expected 1 got 2"

    def fix(req: StageRequest) -> StageOutcome:
        (wt / "docs" / "one.md").write_text("fixed\n")
        sh(wt, "git", "add", "-A")
        sh(wt, "git", "commit", "-q", "-m", "fix ci")
        req.contract.run_checks({})
        req.contract.submit_change({"summary": "fixed"})
        return accepted(req, "S-fix")

    rig.agent.on("ci-fix", fix)
    await rig.engine.drive(1)
    assert rig.state(1) == "landed"
    fixes = [r for r in rig.agent.requests if r.stage == "ci-fix"]
    assert len(fixes) == 1 and "testOne failed" in fixes[0].prompt
    assert (rig.engine.repo / "docs").exists()
    sh(rig.engine.repo, "git", "fetch", "-q")
    assert sh(rig.engine.repo, "git", "show", "origin/develop:docs/one.md") == "fixed\n"


async def test_an_infrastructure_red_is_rerun_once(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n")
    t = rig.db.ticket(1)
    assert t
    sha = gitutil.head_sha(Path(t.worktree or ""))
    rig.gh.ci[sha] = [("pr-gate", "linux", "completed", "cancelled")]
    real = rig.gh.rerun_failed

    def rerun(run_id: int) -> None:
        real(run_id)
        rig.gh.ci[sha] = [("pr-gate", "linux", "completed", "success")]  # the rerun goes green

    rig.gh.rerun_failed = rerun  # type: ignore[method-assign]
    await rig.engine.drive(1)
    assert rig.state(1) == "landed" and rig.gh.reruns == [1000]


async def test_a_second_infrastructure_red_of_the_gate_is_treated_as_real(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n")
    t = rig.db.ticket(1)
    assert t
    rig.gh.ci[gitutil.head_sha(Path(t.worktree or ""))] = [("pr-gate", "linux", "completed", "cancelled")]
    await rig.engine.drive(1)
    assert rig.gh.reruns == [1000] and rig.state(1) == "failed"


async def test_overlapping_develop_change_merges_it_in_retests_and_goes_back_to_ci(rig: Rig) -> None:
    ready_ticket(rig, 1, "shared.md", "mine\n")
    advance_develop(rig, "other.md", "theirs\n")  # a different file: no overlap
    advance_develop(rig, "shared.md", "develop's version\n")  # the same file: conflict
    rig.gh.prs.clear()

    def resolve(req: StageRequest) -> StageOutcome:
        wt = req.contract.worktree
        (wt / "docs" / "shared.md").write_text("develop's version\nmine\n")  # keeps both sides
        sh(wt, "git", "add", "-A")
        sh(wt, "git", "commit", "-q", "--no-edit")
        req.contract.run_checks({})
        req.contract.submit_change({"summary": "resolved"})
        return accepted(req, "S-conflict")

    rig.agent.on("conflict", resolve)
    await rig.engine.drive(1)
    assert rig.state(1) == "landed"
    assert [r.stage for r in rig.agent.requests] == ["conflict"]
    assert sh(rig.engine.repo, "git", "show", "origin/develop:docs/shared.md") == "develop's version\nmine\n"


async def test_a_resolution_that_drops_a_landed_line_is_caught(rig: Rig) -> None:
    ready_ticket(rig, 1, "shared.md", "mine\n")
    advance_develop(rig, "shared.md", "develop's line\n")

    def drop(req: StageRequest) -> StageOutcome:
        wt = req.contract.worktree
        (wt / "docs" / "shared.md").write_text("mine\n")  # develop's line is gone
        sh(wt, "git", "add", "-A")
        if subprocess.run(["git", "rev-parse", "-q", "--verify", "MERGE_HEAD"], check=False, cwd=wt, capture_output=True).returncode == 0:
            sh(wt, "git", "commit", "-q", "--no-edit")  # the first round finishes the merge; the second finds it already committed
        req.contract.run_checks({})
        req.contract.submit_change({"summary": "resolved"})
        return accepted(req, "S-conflict")

    rig.agent.on("conflict", drop, drop)  # the second round, given the line, still does not restore it
    await rig.engine.drive(1)
    assert rig.state(1) == "failed"
    assert [r.stage for r in rig.agent.requests] == ["conflict", "conflict"], "one more round, then parked"
    t = rig.db.ticket(1)
    assert t and "dropped 1 landed line" in (t.park_reason or "") and "develop's line" in (t.park_reason or "")
    assert not origin_has(rig, 1)


async def test_dropped_lines_go_back_to_the_conflict_stage_once(rig: Rig) -> None:
    ready_ticket(rig, 1, "shared.md", "mine\n")
    advance_develop(rig, "shared.md", "develop's line\n")
    prompts: list[str] = []

    def conflict(req: StageRequest) -> StageOutcome:
        prompts.append(req.prompt)
        wt = req.contract.worktree
        # the first round drops develop's line; the second restores it on top of the first resolution
        (wt / "docs" / "shared.md").write_text("mine\n" if len(prompts) == 1 else "develop's line\nmine\n")
        sh(wt, "git", "add", "-A")
        sh(wt, "git", "commit", "-q", "-m", f"round {len(prompts)}")
        req.contract.run_checks({})
        req.contract.submit_change({"summary": "resolved"})
        return accepted(req, "S-conflict")

    rig.agent.on("conflict", conflict, conflict)
    await rig.engine.drive(1)
    assert rig.state(1) == "landed"  # a clean second audit carries on as after a clean first one
    assert [r.stage for r in rig.agent.requests] == ["conflict", "conflict"]
    assert "Conflicts merging" in prompts[0]
    assert "docs/shared.md: develop's line" in prompts[1] and "already committed" in prompts[1] and "restore" in prompts[1].lower()
    assert sh(rig.engine.repo, "git", "show", "origin/develop:docs/shared.md") == "develop's line\nmine\n"


async def test_a_reported_merge_that_is_not_on_develop_is_a_phantom_landing(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n")
    rig.gh.phantom = True
    await rig.engine.drive(1)
    assert rig.state(1) == "failed"
    assert any(k == "star pipeline: phantom-landing" for k, _ in rig.pages)


async def test_landing_waits_while_develop_is_red(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n")
    rig.db.put("stop_line", "pr-gate/linux")
    cleared: list[float] = []
    real_sleep = rig.engine.sleep

    async def sleep(s: float) -> None:
        cleared.append(s)
        if len(cleared) == 3:
            rig.db.put("stop_line", None)
        await real_sleep(s)

    rig.engine.sleep = sleep
    await rig.engine.drive(1)
    assert rig.state(1) == "landed" and len(cleared) >= 3


def pending_ci(rig: Rig, n: int) -> None:
    t = rig.db.ticket(n)
    assert t
    rig.gh.ci[gitutil.head_sha(Path(t.worktree or ""))] = [("pr-gate", "linux", "in_progress", None)]


async def drive_within(rig: Rig, n: int) -> None:
    await asyncio.wait_for(rig.engine.drive(n), 60)  # a land-now that is ignored would wait on CI forever


async def test_land_now_skips_the_ci_wait(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n")
    pending_ci(rig, 1)
    rig.db.put("land_now:1", "1")
    await drive_within(rig, 1)
    assert rig.state(1) == "landed"
    assert rig.db.get("ci_notes:1") == "- tests bypassed by the owner (land-now)"


async def test_land_now_set_while_ci_is_pending_is_seen_on_the_next_poll(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n")
    pending_ci(rig, 1)
    polls: list[float] = []
    real_sleep = rig.engine.sleep

    async def sleep(s: float) -> None:
        polls.append(s)
        if len(polls) == 2:
            rig.db.put("land_now:1", "1")
        await real_sleep(s)

    rig.engine.sleep = sleep
    await drive_within(rig, 1)
    assert rig.state(1) == "landed" and len(polls) >= 2


async def test_land_now_skips_the_overlap_retest_and_the_stop_line(rig: Rig, monkeypatch: pytest.MonkeyPatch) -> None:
    ready_ticket(rig, 1, "one.md", "one\n")
    advance_develop(rig, "other.md", "theirs\n")  # develop moved: normally the overlap is looked at
    asked: list[str] = []

    def overlap(*_: object) -> landing.Overlap:
        asked.append("overlap")
        return landing.Overlap(["docs/other.md"], [])  # would force a catch-up and a re-test

    monkeypatch.setattr(landing, "overlap", overlap)
    rig.db.put("stop_line", "pr-gate/linux")  # never cleared
    rig.db.put("land_now:1", "1")
    await drive_within(rig, 1)
    assert rig.state(1) == "landed" and asked == []
    assert not [r for r in rig.agent.requests]


async def test_land_now_still_waits_for_an_explicit_landing_pause(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n")
    rig.db.put("land_now:1", "1")
    rig.db.put("pause", "landing")
    waits: list[str] = []
    real_sleep = rig.engine.sleep

    async def sleep(s: float) -> None:
        waits.append(rig.state(1))
        if len(waits) == 3:
            rig.db.put("pause", None)
        await real_sleep(s)

    rig.engine.sleep = sleep
    await drive_within(rig, 1)
    assert rig.state(1) == "landed" and waits[:3] == ["landing"] * 3


async def test_land_now_still_sends_a_conflict_to_the_conflict_stage(rig: Rig) -> None:
    ready_ticket(rig, 1, "shared.md", "mine\n")
    advance_develop(rig, "shared.md", "develop's version\n")
    assert ship.publish(rig.engine, rig.db.ticket(1))  # type: ignore[arg-type]
    pr = rig.db.ticket(1)
    assert pr and pr.pr_number
    rig.gh.prs[pr.pr_number]["mergeable"] = False
    rig.db.set_state(1, "landing")
    rig.db.put("land_now:1", "1")

    def resolve(req: StageRequest) -> StageOutcome:
        wt = req.contract.worktree
        (wt / "docs" / "shared.md").write_text("develop's version\nmine\n")
        sh(wt, "git", "add", "-A")
        sh(wt, "git", "commit", "-q", "--no-edit")
        req.contract.run_checks({})
        req.contract.submit_change({"summary": "resolved"})
        return accepted(req, "S-conflict")

    rig.agent.on("conflict", resolve)
    rig.gh.prs[pr.pr_number]["mergeable"] = False
    await drive_within(rig, 1)
    assert [r.stage for r in rig.agent.requests] == ["conflict"]
    assert rig.state(1) == "landed"


async def test_land_now_notes_the_bypass_in_the_pr_body(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n")
    rig.db.put("land_now:1", "1")
    await drive_within(rig, 1)
    bodies = [p["body"] for p in rig.gh.prs.values()]
    assert len(bodies) == 1 and "## Tests bypassed" in bodies[0] and "land-now" in bodies[0]


async def test_a_ticket_without_land_now_has_no_bypass_note(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n")
    await drive_within(rig, 1)
    assert all("Tests bypassed" not in p["body"] for p in rig.gh.prs.values())


async def test_the_pr_head_is_pinned_so_a_late_push_is_not_merged(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n")
    rig.db.set_state(1, "ci")
    t = rig.db.ticket(1)
    assert t
    ship.publish_pr = None  # type: ignore[attr-defined]
    rig.db.set_state(1, "ready")
    assert ship.publish(rig.engine, t)
    pr = rig.db.ticket(1)
    assert pr and pr.pr_number
    with pytest.raises(Exception, match="head changed"):
        rig.gh.merge_pr(pr.pr_number, "f" * 40)


# the judge, alone -----------------------------------------------------------------------------------------------------
def job(wf: str, name: str, status: str = "completed", conclusion: str | None = "success") -> ci.Job:
    return ci.Job(wf, name, status, conclusion, 1)


def judged(jobs: list[ci.Job], base: dict[tuple[str, str], str] | None = None, now: float = 1000.0,
           pushed: float = 0.0, **kw: object) -> ci.Verdict:
    base = base or {}
    return ci.judge(jobs, lambda w, j: base.get((w, j)), now=now, head_pushed_at=pushed, **kw)  # type: ignore[arg-type]


def test_the_judge_waits_for_the_settle_time_and_for_pr_gate() -> None:
    assert judged([job("pr-gate", "l")], now=30).kind == "pending"
    assert judged([job("cli", "x")]).kind == "pending"
    assert judged([job("pr-gate", "l", "in_progress", None)]).kind == "pending"
    assert judged([job("pr-gate", "l")]).kind == "pass"


def test_pr_gate_red_always_blocks_even_if_develop_is_red() -> None:
    v = judged([job("pr-gate", "l", conclusion="failure")], {("pr-gate", "l"): "failure"})
    assert v.kind == "fail"


def test_other_reds_block_only_when_new() -> None:
    jobs = [job("pr-gate", "l"), job("cli", "w", conclusion="failure")]
    assert judged(jobs, {("cli", "w"): "failure"}).kind == "pass"
    assert judged(jobs, {}).kind == "pass"  # no develop data: it was already failing as far as we know
    assert judged(jobs, {("cli", "w"): "success"}).kind == "rerun"  # once, in case it is a flake
    assert judged(jobs, {("cli", "w"): "success"}, reran={("cli", "w")}).kind == "fail"


def test_slow_jobs_stop_blocking_after_the_wait() -> None:
    jobs = [job("pr-gate", "l"), job("cli", "w", "in_progress", None)]
    assert judged(jobs, now=100).kind == "pending"
    v = judged(jobs, now=5 * 3600)
    assert v.kind == "pass" and [j.job for j in v.demoted] == ["w"]


def test_a_new_red_outside_the_gate_is_rerun_once_before_it_counts() -> None:
    jobs = [job("pr-gate", "l"), job("gherkin", "videoBackgroundIdentical", conclusion="failure")]
    base = {("gherkin", "videoBackgroundIdentical"): "success"}
    v = judged(jobs, base)
    assert v.kind == "rerun" and [j.job for j in v.rerun] == ["videoBackgroundIdentical"]
    assert judged(jobs, base, reran={("gherkin", "videoBackgroundIdentical")}).kind == "fail"


def test_a_failure_in_a_run_that_never_finishes_stops_blocking_after_the_wait() -> None:
    stuck = ci.Job("gherkin", "videoBackgroundIdentical", "completed", "failure", 7, run_done=False)
    base = {("gherkin", "videoBackgroundIdentical"): "success"}
    assert judged([job("pr-gate", "l"), stuck], base, now=3600).kind == "rerun"
    v = judged([job("pr-gate", "l"), stuck], base, now=5 * 3600)
    assert v.kind == "pass" and [j.job for j in v.demoted] == ["videoBackgroundIdentical"]


def test_the_judge_reruns_once() -> None:
    jobs = [job("pr-gate", "l", conclusion="timed_out")]
    assert judged(jobs).kind == "rerun"
    assert judged(jobs, reran={("pr-gate", "l")}).kind == "fail"  # the gate always blocks


def test_another_workflow_cancelled_twice_is_infrastructure_not_a_failure() -> None:
    jobs = [job("pr-gate", "l"), job("cli", "macos", conclusion="cancelled")]
    assert judged(jobs, {("cli", "macos"): "success"}).kind == "rerun"
    v = judged(jobs, {("cli", "macos"): "success"}, reran={("cli", "macos")})
    assert v.kind == "pass" and [j.job for j in v.known_red] == ["macos"]


def test_parse_jobs_pairs_runs_with_their_jobs() -> None:
    jobs = ci.parse_jobs([{"id": 5, "name": "pr-gate"}], {5: [{"name": "linux", "status": "completed",
                                                              "conclusion": "success", "completed_at": "2026-10-31T10:00:00Z"}]})
    assert jobs == [ci.Job("pr-gate", "linux", "completed", "success", 5, jobs[0].completed_at)]
    assert jobs[0].completed_at


# landing helpers --------------------------------------------------------------------------------------------------------
def test_dropped_line_audit_and_the_pr_may_remove_its_own_lines(tmp_path: Path) -> None:
    repo = tmp_path / "r"
    sh(tmp_path, "git", "init", "-q", "-b", "develop", str(repo))
    sh(repo, "git", "config", "user.email", "t@t")
    sh(repo, "git", "config", "user.name", "t")
    (repo / "f.txt").write_text("a\nb\n")
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-q", "-m", "base")
    mb = gitutil.head_sha(repo)
    sh(repo, "git", "checkout", "-q", "-b", "pr")
    (repo / "f.txt").write_text("a\nmine\n")  # the PR itself removes `b`
    sh(repo, "git", "commit", "-qam", "pr")
    pr_head = gitutil.head_sha(repo)
    sh(repo, "git", "checkout", "-q", "develop")
    (repo / "f.txt").write_text("a\nb\nnew from develop\n")
    sh(repo, "git", "commit", "-qam", "dev")
    dev = gitutil.head_sha(repo)
    sh(repo, "git", "checkout", "-q", "pr")  # the PR as it stands has lost `new from develop`: a bad resolution
    dropped = landing.audit(repo, mb, dev, pr_head)
    assert [(d.file, d.line) for d in dropped] == [("f.txt", "new from develop")]
    (repo / "f.txt").write_text("a\nmine\nnew from develop\n")
    sh(repo, "git", "commit", "-qam", "good merge")
    assert landing.audit(repo, mb, dev, pr_head) == []


def test_ticket_worktree_and_branch_names() -> None:
    assert worktrees.branch_name(7, "Fix the Thing!") == "pipe/7-fix-the-thing"
    assert FakeGitHub is not None


# post-merge watch and stop-the-line ------------------------------------------------------------------------------------
def test_watch_seeds_the_baseline_then_files_a_p0_for_a_red_pr_gate(rig: Rig) -> None:
    rig.gh.develop_ci = [("pr-gate", "linux", "completed", "success"), ("cli", "windows", "completed", "failure")]
    ship.watch_develop(rig.engine)
    assert rig.db.baseline("cli", "windows") == "failure" and rig.gh.issues == {}  # known red: no ticket

    rig.gh.develop_ci = [("pr-gate", "linux", "completed", "failure"), ("cli", "windows", "completed", "failure")]
    ship.watch_develop(rig.engine)
    assert rig.db.get("stop_line") == "pr-gate/linux"
    (issue,) = rig.gh.issues.values()
    assert issue["title"] == "develop red: pr-gate/linux"
    assert {"pipeline", "p0", "pipe:filed-by-pipeline"} <= {x["name"] for x in issue["labels"]}
    assert any(k == "star pipeline: develop-red" for k, _ in rig.pages)

    rig.gh.develop_ci = [("pr-gate", "linux", "completed", "success"), ("cli", "windows", "completed", "failure")]
    ship.watch_develop(rig.engine)
    assert rig.db.get("stop_line") is None


def test_auto_run_tickets_are_capped(rig: Rig) -> None:
    rig.gh.develop_sha = "d1"
    rig.gh.develop_ci = [(f"w{i}", "j", "completed", "success") for i in range(4)]
    ship.watch_develop(rig.engine)
    rig.gh.develop_ci = [(f"w{i}", "j", "completed", "failure") for i in range(4)]
    for sha in ("d2", "d3"):  # red in two different develop runs: now it is real
        rig.gh.develop_sha = sha
        ship.watch_develop(rig.engine)
    filed = [i for i in rig.gh.issues.values() if i["title"].startswith("regression on develop")]
    assert len(filed) == 2


def test_one_red_run_of_a_non_gate_job_on_develop_files_nothing_until_a_second_run_agrees(rig: Rig) -> None:
    rig.gh.develop_sha = "d1"
    rig.gh.develop_ci = [("gherkin", "desktop", "completed", "success")]
    ship.watch_develop(rig.engine)
    rig.gh.develop_ci = [("gherkin", "desktop", "completed", "failure")]
    for sha in ("d2", "d2", "d2"):  # the same red run, polled again and again
        rig.gh.develop_sha = sha
        ship.watch_develop(rig.engine)
    assert rig.gh.issues == {}, "a single red run might be a flake"
    rig.gh.develop_sha = "d3"
    ship.watch_develop(rig.engine)
    (issue,) = rig.gh.issues.values()
    assert issue["title"] == "regression on develop: gherkin/desktop"
    rig.gh.develop_sha = "d4"
    ship.watch_develop(rig.engine)
    assert len(rig.gh.issues) == 1, "it is filed once, not on every red run"


def test_a_job_that_goes_green_again_was_a_flake_and_resets_the_wait(rig: Rig) -> None:
    rig.gh.develop_sha = "d1"
    rig.gh.develop_ci = [("gherkin", "desktop", "completed", "success")]
    ship.watch_develop(rig.engine)
    for sha, result in (("d2", "failure"), ("d3", "success"), ("d4", "failure")):
        rig.gh.develop_sha = sha
        rig.gh.develop_ci = [("gherkin", "desktop", "completed", result)]
        ship.watch_develop(rig.engine)
    assert rig.gh.issues == {}, "red, green, red: never two reds in a row"


def test_a_red_gate_still_stops_the_line_on_the_first_red_run(rig: Rig) -> None:
    rig.gh.develop_sha = "d1"
    rig.gh.develop_ci = [("pr-gate", "linux", "completed", "success")]
    ship.watch_develop(rig.engine)
    rig.gh.develop_sha = "d2"
    rig.gh.develop_ci = [("pr-gate", "linux", "completed", "failure")]
    ship.watch_develop(rig.engine)
    assert rig.db.get("stop_line") == "pr-gate/linux" and len(rig.gh.issues) == 1


async def test_a_refused_rerun_is_not_fatal_and_waits_for_the_run_to_finish(rig: Rig) -> None:
    from starpipe.github import GitHubError

    ready_ticket(rig, 1, "one.md", "one\n")
    t = rig.db.ticket(1)
    assert t
    sha = gitutil.head_sha(Path(t.worktree or ""))
    rig.gh.ci[sha] = [("pr-gate", "linux", "completed", "cancelled")]
    attempts: list[int] = []

    def refuse_then_accept(run_id: int) -> None:
        attempts.append(run_id)
        if len(attempts) == 1:
            raise GitHubError("This workflow is already running (HTTP 403)")
        rig.gh.ci[sha] = [("pr-gate", "linux", "completed", "success")]

    rig.gh.rerun_failed = refuse_then_accept  # type: ignore[method-assign]
    await rig.engine.drive(1)
    assert rig.state(1) == "landed" and len(attempts) == 2


def test_a_job_of_a_run_still_going_is_not_rerunnable() -> None:
    jobs = ci.parse_jobs([{"id": 5, "name": "cli", "status": "in_progress"}],
                         {5: [{"name": "w", "status": "completed", "conclusion": "cancelled"}]})
    assert jobs[0].run_done is False


def test_a_cancelled_or_timed_out_develop_job_is_not_a_regression(rig: Rig) -> None:
    rig.gh.develop_ci = [("pr-gate", "linux", "completed", "success"), ("cli", "macos", "completed", "success")]
    ship.watch_develop(rig.engine)
    rig.gh.develop_ci = [("pr-gate", "linux", "completed", "cancelled"), ("cli", "macos", "completed", "timed_out")]
    ship.watch_develop(rig.engine)
    assert rig.gh.issues == {} and rig.db.get("stop_line") is None
    assert rig.db.baseline("cli", "macos") == "timed_out"


def test_a_cancelled_newest_develop_run_leaves_baseline_and_stop_line_alone(rig: Rig) -> None:
    rig.gh.develop_ci = [("pr-gate", "linux", "completed", "success"), ("cli", "macos", "completed", "success")]
    ship.watch_develop(rig.engine)
    rig.db.put("stop_line", "pr-gate/linux")  # a stop-the-line from earlier: a cancelled run must not clear it either
    before = {k: rig.db.baseline(*k) for k in (("pr-gate", "linux"), ("cli", "macos"))}
    rig.gh.develop_ci = [("pr-gate", "linux", "completed", "cancelled"), ("cli", "macos", "completed", "cancelled")]
    ship.watch_develop(rig.engine)
    assert rig.gh.issues == {} and rig.db.get("stop_line") == "pr-gate/linux"
    assert {k: rig.db.baseline(*k) for k in before} == before == {("pr-gate", "linux"): "success", ("cli", "macos"): "success"}


def test_a_cancelled_newest_run_keeps_the_older_successful_runs_baseline(rig: Rig) -> None:
    rig.gh.develop_ci = [("cli", "macos", "completed", "success")]
    ship.watch_develop(rig.engine)  # seeds
    rig.gh.develop_ci = [("cli", "macos", "completed", "cancelled")]
    rig.gh.develop_history = [[("cli", "macos", "completed", "success")]]
    ship.watch_develop(rig.engine)
    assert rig.db.baseline("cli", "macos") == "success"
    assert rig.gh.issues == {}


def test_a_newest_develop_run_that_really_failed_still_counts(rig: Rig) -> None:
    rig.gh.develop_ci = [("pr-gate", "linux", "completed", "success"), ("cli", "macos", "completed", "success")]
    ship.watch_develop(rig.engine)
    rig.gh.develop_ci = [("pr-gate", "linux", "completed", "success"), ("cli", "macos", "completed", "failure")]
    rig.gh.develop_history = [[("pr-gate", "linux", "completed", "success"), ("cli", "macos", "completed", "cancelled")]]
    ship.watch_develop(rig.engine)
    assert rig.db.baseline("cli", "macos") == "failure"
    assert rig.gh.issues == {}, "one red run waits for a second to agree"
    rig.gh.develop_sha = "d2"  # a later develop push, also red
    ship.watch_develop(rig.engine)
    (issue,) = rig.gh.issues.values()
    assert issue["title"] == "regression on develop: cli/macos"


def test_a_gradle_download_failure_looks_like_infrastructure_and_a_test_failure_does_not() -> None:
    gradle = ("> Could not resolve all files for configuration ':classpath'.\n"
              "   > Could not resolve com.google.protobuf:protobuf-gradle-plugin:0.9.4.\n"
              "     - https://repo.maven.apache.org/maven2/com/google/gradle/osdetector-gradle-plugin/1.7.3/x.pom")
    assert ci.INFRA_LOG.search(gradle)
    assert ci.INFRA_LOG.search("Could not GET 'https://plugins.gradle.org/m2/x.pom'. Received status code 503")
    assert not ci.INFRA_LOG.search("testFoo failed: expected 1 but was 2\nProcess completed with exit code 1.")
    assert not ci.INFRA_LOG.search("error: cannot find symbol  Could not find method foo")


async def test_publish_ci_polling_and_landing_never_block_the_event_loop(rig: Rig) -> None:
    """Each GitHub call below waits until the event loop has run a callback scheduled from inside the call. Made on the loop
    (synchronously) it could never run, so the wait would time out and be recorded."""
    import asyncio
    import threading
    from collections.abc import Callable

    ready_ticket(rig, 1, "one.md", "one\n")
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
    await rig.engine.drive(1)
    assert rig.state(1) == "landed"
    assert blocked == {"create_pr": False, "workflow_runs": False, "pr": False, "merge_pr": False}


def test_a_hung_gh_call_times_out_instead_of_hanging_the_daemon(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from starpipe import github

    fake = tmp_path / "gh"
    fake.write_text("#!/bin/sh\nsleep 30\n")
    fake.chmod(0o755)
    monkeypatch.setenv("PATH", f"{tmp_path}:/usr/bin:/bin")
    monkeypatch.setattr(github, "GH_TIMEOUT_S", 0.3)
    started = time.monotonic()
    with pytest.raises(github.GitHubError, match="timed out"):
        github.gh_runner(["api", "x"], None)
    assert time.monotonic() - started < 10


async def test_only_max_in_ci_tickets_are_in_ci_at_once_and_the_rest_wait_ready(rig: Rig) -> None:
    import asyncio

    rig.engine.config.max_in_ci = 1
    for n in (1, 2, 3):
        ready_ticket(rig, n, f"f{n}.md", f"{n}\n")
    in_ci_when_published: list[int] = []
    real_create = rig.gh.create_pr

    def create_pr(title: str, body: str, head: str, base: str) -> dict[str, Any]:
        in_ci_when_published.append(len(rig.db.tickets(("ci", "landing"))))
        return real_create(title, body, head, base)

    rig.gh.create_pr = create_pr  # type: ignore[method-assign]
    await asyncio.gather(rig.engine.drive(1), rig.engine.drive(2), rig.engine.drive(3))
    assert [rig.state(n) for n in (1, 2, 3)] == ["landed"] * 3
    assert in_ci_when_published == [0, 0, 0], "each ticket published only when none was in CI or landing"


async def test_a_ticket_waiting_for_room_is_not_published_early_and_waits_as_ready(rig: Rig) -> None:
    rig.engine.config.max_in_ci = 1
    ready_ticket(rig, 1, "one.md", "1\n")
    rig.db.set_state(1, "ci")  # something already occupies the only slot
    ready_ticket(rig, 2, "two.md", "2\n")
    waits: list[float] = []
    real_sleep = rig.engine.sleep

    async def sleep(s: float) -> None:
        waits.append(s)
        if len(waits) == 3:
            rig.db.set_state(1, "landed")  # the slot frees up
        await real_sleep(s)

    rig.engine.sleep = sleep
    ticket = rig.db.ticket(2)
    assert ticket
    assert rig.gh.prs == {}
    await rig.engine._publish_when_room(ticket)  # pyright: ignore[reportPrivateUsage]
    assert len(waits) == 3 and waits[0] == 30, "it waited, and polled every 30 s"
    assert len(rig.gh.prs) == 1 and rig.state(2) == "ci"


def test_a_normal_gherkin_run_still_blocks_and_only_a_longer_one_is_demoted() -> None:
    """Gherkin takes about 3 h (slowest seen 214 min). With the old 3 h limit a batch could land with its matrix unfinished."""
    from starpipe.config import Config

    limit = Config().ci_blocking_wait_s
    assert limit == 4 * 3600
    running = [job("pr-gate", "l"), job("gherkin", "cli (macos-15) · autoHorizonJpeg", "in_progress", None)]
    assert judged(running, now=3.6 * 3600, blocking_wait_s=limit).kind == "pending", "214 minutes in: still waiting for it"
    v = judged(running, now=4.1 * 3600, blocking_wait_s=limit)
    assert v.kind == "pass" and [j.workflow for j in v.demoted] == ["gherkin"]


def test_a_pr_does_not_wait_for_gherkin_and_its_runs_are_cancelled(rig: Rig) -> None:
    """Gherkin takes ~3 h, mostly queueing for macOS runners, so a landing waited hours for it. It is judged after the merge instead:
    the PR's own runs of it are ignored (even a red one) and cancelled, to free the runners; everything else is judged as before."""
    rig.gh.ci["sha1"] = [("pr-gate", "linux", "completed", "success"), ("CLI Build", "macos", "completed", "success"),
                         ("Gherkin", "cli (macos-15) · a", "in_progress", None), ("Gherkin", "desktop (ubuntu-24.04) · b", "completed", "failure")]
    rig.engine.db.put("pushed_at:1", str(rig.engine.clock() - 10000))
    v = ship._judge(rig.engine, 1, "sha1", set())  # pyright: ignore[reportPrivateUsage]
    assert v.kind == "pass" and v.known_red == [] and v.blocking == [] and v.demoted == []
    assert rig.gh.cancelled_runs == [rig.gh.run_ids[("sha1", "Gherkin")]], "only Gherkin's run was cancelled"


SMOKE_JOB = "cli (ubuntu-24.04) · shard 1: autoHorizonJpeg"
FULL_JOB = "desktop (ubuntu-24.04) · shard 1: autoHorizonVideo"


def _judge_pr(rig: Rig, sha: str, reran: set[tuple[str, str]] | None = None) -> ci.Verdict:
    rig.engine.db.put("pushed_at:1", str(rig.engine.clock() - 10000))
    return ship._judge(rig.engine, 1, sha, reran or set())  # pyright: ignore[reportPrivateUsage]


def test_a_red_smoke_job_green_on_develop_is_rerun_then_blocks(rig: Rig) -> None:
    """A PR is gated on "Gherkin smoke": a job red here and green on develop gets one rerun, then blocks. The full matrix next to it,
    still running, is neither waited for nor judged, and is cancelled."""
    rig.gh.ci["sha3"] = [("pr-gate", "linux", "completed", "success"), ("Gherkin smoke", SMOKE_JOB, "completed", "failure"),
                         ("Gherkin", FULL_JOB, "in_progress", None)]
    rig.engine.db.set_baseline("Gherkin smoke", SMOKE_JOB, "x", "success")
    v = _judge_pr(rig, "sha3")
    assert v.kind == "rerun" and [j.key for j in v.rerun] == [("Gherkin smoke", SMOKE_JOB)]
    v = _judge_pr(rig, "sha3", {("Gherkin smoke", SMOKE_JOB)})
    assert v.kind == "fail" and [j.key for j in v.blocking] == [("Gherkin smoke", SMOKE_JOB)]
    assert rig.gh.cancelled_runs and set(rig.gh.cancelled_runs) == {rig.gh.run_ids[("sha3", "Gherkin")]}, "only the full matrix is cancelled"


def test_a_red_smoke_job_that_is_red_on_develop_does_not_block(rig: Rig) -> None:
    rig.gh.ci["sha4"] = [("pr-gate", "linux", "completed", "success"), ("Gherkin smoke", SMOKE_JOB, "completed", "failure")]
    rig.engine.db.set_baseline("Gherkin smoke", SMOKE_JOB, "x", "failure")
    v = _judge_pr(rig, "sha4")
    assert v.kind == "pass" and [j.key for j in v.known_red] == [("Gherkin smoke", SMOKE_JOB)]


def test_a_red_full_gherkin_job_does_not_block_while_smoke_is_green(rig: Rig) -> None:
    """The full matrix is post-merge only: a red job of it on a PR, even one that is green on develop, blocks nothing and the run is
    cancelled if still going. Removing "Gherkin" from ci_post_merge_workflows, or adding "Gherkin smoke" to it, breaks this and the two above."""
    from starpipe.config import Config

    assert Config().ci_post_merge_workflows == ("Gherkin",)
    rig.gh.ci["sha5"] = [("pr-gate", "linux", "completed", "success"), ("Gherkin smoke", SMOKE_JOB, "completed", "success"),
                         ("Gherkin", FULL_JOB, "completed", "failure"), ("Gherkin", "mac gui (macos-15) · ui", "in_progress", None)]
    rig.engine.db.set_baseline("Gherkin", FULL_JOB, "x", "success")
    v = _judge_pr(rig, "sha5")
    assert v.kind == "pass" and v.blocking == [] and v.rerun == [] and v.known_red == []
    assert rig.gh.cancelled_runs == [rig.gh.run_ids[("sha5", "Gherkin")]]


def test_a_red_non_gherkin_job_still_blocks_when_gherkin_is_ignored(rig: Rig) -> None:
    rig.gh.ci["sha2"] = [("pr-gate", "linux", "completed", "success"), ("Kotlin Client", "build", "completed", "failure"),
                         ("Gherkin", "cli (macos-15) · a", "in_progress", None)]
    rig.engine.db.set_baseline("Kotlin Client", "build", "x", "success")
    rig.engine.db.put("pushed_at:1", str(rig.engine.clock() - 10000))
    v = ship._judge(rig.engine, 1, "sha2", set())  # pyright: ignore[reportPrivateUsage]
    assert v.kind in ("rerun", "fail"), "a failing job outside Gherkin is still judged"


def _audit_repo(tmp_path: Path, base: str, develop: str, pr: str, resolved: str) -> list[landing.Dropped]:
    repo = tmp_path / "r"
    sh(tmp_path, "git", "init", "-q", "-b", "develop", str(repo))
    sh(repo, "git", "config", "user.email", "t@t")
    sh(repo, "git", "config", "user.name", "t")
    f = repo / "f.txt"
    f.write_text(base)
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-q", "-m", "base")
    mb = gitutil.head_sha(repo)
    sh(repo, "git", "checkout", "-q", "-b", "pr")
    f.write_text(pr)
    sh(repo, "git", "commit", "-qam", "pr")
    pr_head = gitutil.head_sha(repo)
    sh(repo, "git", "checkout", "-q", "develop")
    f.write_text(develop)
    sh(repo, "git", "commit", "-qam", "dev")
    dev = gitutil.head_sha(repo)
    sh(repo, "git", "checkout", "-q", "pr")
    f.write_text(resolved)
    sh(repo, "git", "commit", "-qam", "resolution")
    return landing.audit(repo, mb, dev, pr_head)


def test_the_audit_accepts_a_line_both_sides_edited_when_its_content_survives(tmp_path: Path) -> None:
    """The case that parked ticket #37: develop added an argument to a call, #37 added a different one; the resolution has both."""
    base = "def f(a, b) -> int:\n    pass\n"
    develop = "def f(a, b, max_open: int = 30, max_proposed: int = 10) -> int:\n    pass\n"
    pr = "def f(a, b, allow_fable: bool = False) -> int:\n    pass\n"
    resolved = "def f(a, b, max_open: int = 30, max_proposed: int = 10, allow_fable: bool = False) -> int:\n    pass\n"
    assert _audit_repo(tmp_path, base, develop, pr, resolved) == []


def test_the_audit_accepts_a_line_that_was_re_wrapped_across_lines(tmp_path: Path) -> None:
    base = "x = call(a)\n"
    develop = "x = call(a, max_open=cfg.max_open_tickets, max_proposed=cfg.max_proposed)\n"
    pr = "x = call(a, extra=1)\n"
    resolved = "x = call(a,\n         max_open=cfg.max_open_tickets, max_proposed=cfg.max_proposed,\n         extra=1)\n"
    assert _audit_repo(tmp_path, base, develop, pr, resolved) == []


def test_the_audit_still_catches_a_line_that_was_really_deleted(tmp_path: Path) -> None:
    base = "a = 1\n"
    develop = "a = 1\nchecked = verify_the_landing(batch, merge_commit, develop_head)\n"
    pr = "a = 2\n"
    resolved = "a = 2\nunrelated = other_thing()\n"
    dropped = _audit_repo(tmp_path, base, develop, pr, resolved)
    assert [d.line for d in dropped] == ["checked = verify_the_landing(batch, merge_commit, develop_head)"]


def test_the_audit_ignores_a_generated_files_source_hash_line(tmp_path: Path) -> None:
    """#113 was parked for this: both sides added features, so the regenerated file carries a new hash, not either side's."""
    base = "let a = 1\n// source-hash: aaaa1111bbbb2222\n"
    develop = "let a = 1\n// source-hash: cccc3333dddd4444\n"
    pr = "let a = 1\nlet b = 2\n// source-hash: eeee5555ffff6666\n"
    resolved = "let a = 1\nlet b = 2\n// source-hash: 99990000aaaabbbb\n"
    assert _audit_repo(tmp_path, base, develop, pr, resolved) == []


def test_a_short_line_must_be_present_exactly(tmp_path: Path) -> None:
    base = "a = 1\n"
    develop = "a = 1\nreturn x\n"  # two words: too little to be matched loosely
    pr = "a = 2\n"
    resolved = "a = 2\nreturn x + 1\n"  # `return` and `x` both appear, but the line itself is gone
    assert [d.line for d in _audit_repo(tmp_path, base, develop, pr, resolved)] == ["return x"]


async def test_landing_announces_each_ticket_once(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n")
    await rig.engine.drive(1)
    assert rig.state(1) == "landed"
    assert rig.announcer.calls == [("landed", 1)]


def test_a_tickets_gherkin_features_are_the_pipeline_value_plus_the_plans_without_duplicates() -> None:
    from starpipe import tickets

    plan = {"gherkin_features_to_run": ["autoHorizonJpeg", "autoMovingTiff16"]}
    assert tickets.gherkin_features(with_gherkin("autoMovingTiff16, selectiveTiff16"), plan) == [
        "autoMovingTiff16", "selectiveTiff16", "autoHorizonJpeg"]
    assert tickets.gherkin_features(with_gherkin("no"), None) == [] and tickets.gherkin_features(GOOD_BODY, {}) == []
    assert tickets.feature_title(["a", "b"]) == "Gherkin: a,b", "the run-name gherkin.yml gives a dispatch with features a,b"


async def test_gherkin_features_are_dispatched_on_the_branch_and_block_landing(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n", body=with_gherkin("autoMovingTiff16"))
    t = rig.db.ticket(1)
    assert t and t.branch
    rig.gh.feature_pending_polls = 2
    during: list[tuple[str, bool]] = []
    real_sleep = rig.engine.sleep

    async def sleep(s: float) -> None:
        during.append((rig.state(1), any(p["merged"] for p in rig.gh.prs.values())))
        await real_sleep(s)

    rig.engine.sleep = sleep  # type: ignore[method-assign]
    await rig.engine.drive(1)
    assert rig.gh.dispatches == [("gherkin.yml", t.branch, {"features": "autoMovingTiff16"})]
    assert rig.gh.feature_runs[5000]["title"] == "Gherkin: autoMovingTiff16"
    assert len(during) >= 2 and set(during) == {("ci", False)}, "it waited for the run in CI and nothing landed meanwhile"
    assert rig.state(1) == "landed" and rig.gh.cancelled_runs == [], "the feature run was not cancelled as a PR's full matrix is"


NO_TRIGGER = "gh api -X POST repos/o/r/actions/workflows/gherkin.yml/dispatches failed: Workflow does not have 'workflow_dispatch' trigger (HTTP 422)"


def failing_dispatch(rig: Rig, errors: list[str]) -> None:
    """The fake's dispatch raises each of `errors` in turn, then works."""
    real = rig.gh.dispatch_workflow
    pending = list(errors)

    def dispatch(file: str, ref: str, inputs: dict[str, str]) -> None:
        if pending:
            raise GitHubError(pending.pop(0))
        real(file, ref, inputs)

    rig.gh.dispatch_workflow = dispatch  # type: ignore[method-assign]


async def test_a_dispatch_422_catches_the_branch_up_then_dispatches_again(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n", body=with_gherkin("autoMovingTiff16"))
    advance_develop(rig, "later.md", "a develop change the branch has not got\n")
    failing_dispatch(rig, [NO_TRIGGER])
    await rig.engine.drive(1)
    assert [d[2] for d in rig.gh.dispatches] == [{"features": "autoMovingTiff16"}], "dispatched once, on the caught-up head"
    assert rig.gh.origin is not None
    ran = sh(rig.gh.origin, "git", "log", "--oneline", rig.gh.feature_runs[5000]["sha"])
    assert "develop: later.md" in ran, "the run is of a head with develop merged in"
    assert rig.state(1) == "landed"
    assert rig.db.get("gherkin_err:1") is None


async def test_a_repeating_gate_error_parks_the_ticket(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n", body=with_gherkin("autoMovingTiff16"))
    failing_dispatch(rig, ["gh: Resource not accessible by integration (HTTP 403)"] * 50)
    await rig.engine.drive(1)
    t = rig.db.ticket(1)
    assert t and t.state == "failed"
    assert "HTTP 403" in (t.park_reason or "") and "5" in (t.park_reason or "")
    assert len(rig.slept) < 20, "it gave up rather than looping"


async def test_a_422_with_nothing_to_catch_up_on_also_parks(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n", body=with_gherkin("autoMovingTiff16"))
    failing_dispatch(rig, [NO_TRIGGER] * 50)
    await rig.engine.drive(1)
    assert rig.state(1) == "failed"
    assert [r for r in rig.agent.requests if r.stage == "conflict"] == []


async def test_a_transient_gate_error_still_retries(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n", body=with_gherkin("autoMovingTiff16"))
    failing_dispatch(rig, ["gh: Bad Gateway (HTTP 502)"] * 8 + ["gh api timed out after 120s"] * 3)  # more than the parking limit
    await rig.engine.drive(1)
    assert rig.state(1) == "landed"
    assert len(rig.gh.dispatches) == 1


async def test_a_feature_run_red_twice_goes_back_to_ci_fix_with_the_log(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n", body=with_gherkin("autoMovingTiff16"))
    t = rig.db.ticket(1)
    assert t
    wt = Path(t.worktree or "")
    rig.gh.feature_attempts = [[("cli (macos-15) · autoMovingTiff16", "failure")]] * 2  # the first attempt and its rerun
    rig.gh.logs[5000] = "Then the trail is removed\n  expected 3 stars, got 1"

    def fix(req: StageRequest) -> StageOutcome:
        (wt / "docs" / "one.md").write_text("fixed\n")
        sh(wt, "git", "add", "-A")
        sh(wt, "git", "commit", "-q", "-m", "fix the feature")
        rig.gh.feature_attempts = [[("cli (macos-15) · autoMovingTiff16", "success")]]  # the new head's run is green
        req.contract.run_checks({})
        req.contract.submit_change({"summary": "fixed"})
        return accepted(req, "S-fix")

    rig.agent.on("ci-fix", fix)
    await rig.engine.drive(1)
    fixes = [r for r in rig.agent.requests if r.stage == "ci-fix"]
    assert len(fixes) == 1 and "expected 3 stars, got 1" in fixes[0].prompt and "feature run red twice" in fixes[0].prompt
    assert rig.gh.reruns == [5000], "rerun once, not more"
    assert [d[2] for d in rig.gh.dispatches] == [{"features": "autoMovingTiff16"}] * 2, "the fixed head was dispatched again"
    assert rig.gh.feature_runs[5000]["sha"] != rig.gh.feature_runs[5001]["sha"]
    assert rig.state(1) == "landed"


async def test_a_feature_run_red_twice_with_no_fix_parks_the_ticket(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n", body=with_gherkin("autoMovingTiff16"))
    rig.gh.feature_attempts = [[("cli (macos-15) · autoMovingTiff16", "failure")]]
    await rig.engine.drive(1)
    assert rig.state(1) == "failed" and not any(p["merged"] for p in rig.gh.prs.values())


async def test_a_feature_run_red_then_green_passes(rig: Rig) -> None:
    ready_ticket(rig, 1, "one.md", "one\n", body=with_gherkin("autoMovingTiff16"))
    rig.gh.feature_attempts = [[("cli (macos-15) · autoMovingTiff16", "failure")], [("cli (macos-15) · autoMovingTiff16", "success")]]
    await rig.engine.drive(1)
    assert rig.state(1) == "landed" and rig.gh.reruns == [5000]
    assert len(rig.gh.dispatches) == 1 and not [r for r in rig.agent.requests if r.stage == "ci-fix"]


async def test_full_matrix_gherkin_runs_are_still_cancelled_and_featureless_tickets_unchanged(rig: Rig) -> None:
    # a PR's full-matrix Gherkin run is cancelled and not waited for; a dispatched feature run with the ticket's title is left alone
    rig.gh.ci["sha1"] = [("pr-gate", "linux", "completed", "success"), ("Gherkin", "cli (macos-15) · a", "in_progress", None)]
    rig.gh.feature_runs[5000] = {"id": 5000, "branch": "b", "sha": "sha1", "attempt": 1, "title": "Gherkin: x", "polls": 5}
    rig.engine.db.put("pushed_at:1", str(rig.engine.clock() - 10000))
    v = ship._judge(rig.engine, 1, "sha1", set(), ("Gherkin: x",))  # pyright: ignore[reportPrivateUsage]
    assert v.kind == "pass", "neither the full matrix nor the feature run is waited for by the PR judge"
    assert rig.gh.cancelled_runs == [rig.gh.run_ids[("sha1", "Gherkin")]], "the full matrix was cancelled, the feature run was not"
    ship._judge(rig.engine, 1, "sha1", set())  # pyright: ignore[reportPrivateUsage]
    assert 5000 in rig.gh.cancelled_runs, "a run that is not the ticket's own feature run is cancelled, whatever its title"
    # tickets with no features (nothing named, or `gherkin: no`) dispatch nothing and land as before
    ready_ticket(rig, 2, "two.md", "two\n")
    ready_ticket(rig, 3, "three.md", "three\n", body=with_gherkin("no"))
    await rig.engine.drive(2)
    await rig.engine.drive(3)
    assert rig.state(2) == "landed" and rig.state(3) == "landed" and rig.gh.dispatches == []


def test_a_feature_run_on_a_branch_without_a_run_name_is_matched_by_its_path_title_and_time() -> None:
    sha, title, path = "abc", "Gherkin: uiX", ".github/workflows/gherkin.yml"
    dispatched = datetime(2026, 11, 2, 12, 0, 0, tzinfo=UTC).timestamp()

    def run(display_title: str, created: str | None, head: str = sha, event: str = "workflow_dispatch") -> dict[str, Any]:
        return {"id": 1, "event": event, "head_sha": head, "display_title": display_title, "created_at": created}

    assert ship._is_feature_run(run(title, None), sha, title, dispatched)  # type: ignore[reportPrivateUsage]
    assert ship._is_feature_run(run(path, "2026-11-02T12:00:05Z"), sha, title, dispatched)  # type: ignore[reportPrivateUsage]
    assert not ship._is_feature_run(run(path, "2026-11-02T11:50:00Z"), sha, title, dispatched)  # type: ignore[reportPrivateUsage]
    named = {**run("Gherkin", "2026-11-02T12:00:05Z"), "name": "Gherkin"}  # what the REST API returns for a run-name-less workflow
    assert ship._is_feature_run(named, sha, title, dispatched)  # type: ignore[reportPrivateUsage]
    assert not ship._is_feature_run(run("Gherkin", "2026-11-02T12:00:05Z"), sha, title, dispatched)  # type: ignore[reportPrivateUsage]
    assert not ship._is_feature_run(run(path, None), sha, title, dispatched)  # type: ignore[reportPrivateUsage]
    assert not ship._is_feature_run(run(path, "2026-11-02T12:00:05Z", head="other"), sha, title, dispatched)  # type: ignore[reportPrivateUsage]
    assert not ship._is_feature_run(run(path, "2026-11-02T12:00:05Z", event="push"), sha, title, dispatched)  # type: ignore[reportPrivateUsage]
    assert not ship._is_feature_run(run("Some PR title", "2026-11-02T12:00:05Z"), sha, title, dispatched)  # type: ignore[reportPrivateUsage]


def test_a_skipped_develop_job_keeps_its_baseline(rig: Rig) -> None:
    rig.gh.develop_ci = [("pr-gate", "linux", "completed", "success"), ("cli", "macos", "completed", "success")]
    ship.watch_develop(rig.engine)
    rig.db.set_baseline("cli", "macos", "tested-by-pr", "success")
    rig.db.put("red_pending:cli/macos", "earlier")
    rig.gh.develop_sha = "d2"  # the push run skipped its jobs: the batch PR had already tested this tree
    rig.gh.develop_ci = [("pr-gate", "linux", "completed", "skipped"), ("cli", "macos", "completed", "skipped")]
    ship.watch_develop(rig.engine)
    assert rig.db.baseline("cli", "macos") == "success" and rig.db.baseline_sha("cli", "macos") == "tested-by-pr"
    assert rig.db.baseline("pr-gate", "linux") == "success" and rig.db.baseline_sha("pr-gate", "linux") != "d2"
    assert rig.db.get("red_pending:cli/macos") == "earlier", "no red/green transition was recorded"
    assert rig.gh.issues == {} and rig.db.get("stop_line") is None
