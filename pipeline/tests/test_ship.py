from __future__ import annotations

import json
import subprocess
import time
from pathlib import Path

import pytest

from starpipe import ci, gitutil, landing, ship, worktrees
from starpipe.agent import StageOutcome, StageRequest

from .fakes import FakeGitHub, accepted, sh
from .test_engine import Rig

PLAN = json.dumps({"summary": "A planned change.", "acceptance": [{"id": "A1", "check": "review: x"}],
                   "tests": {"none_reason": "docs"}})


@pytest.fixture
def rig(tmp_path: Path) -> Rig:
    return Rig(tmp_path)


def ready_ticket(rig: Rig, n: int, file: str, text: str) -> None:
    """A ticket that has finished REVIEW: a worktree with one commit and a plan, in state `ready`."""
    rig.gh.add_issue(n, f"change {file}")
    rig.engine.sync_issues()
    t = rig.engine.claim(rig.db.ticket(n))  # type: ignore[arg-type]
    wt = Path(t.worktree or "")
    (wt / "docs").mkdir(exist_ok=True)
    (wt / "docs" / file).write_text(text)
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
        sh(wt, "git", "commit", "-q", "--no-edit")
        req.contract.run_checks({})
        req.contract.submit_change({"summary": "resolved"})
        return accepted(req, "S-conflict")

    rig.agent.on("conflict", drop)
    await rig.engine.drive(1)
    assert rig.state(1) == "failed"
    t = rig.db.ticket(1)
    assert t and "dropped 1 landed line" in (t.park_reason or "") and "develop's line" in (t.park_reason or "")
    assert not origin_has(rig, 1)


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
    v = judged(jobs, now=4 * 3600)
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
    v = judged([job("pr-gate", "l"), stuck], base, now=4 * 3600)
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
    rig.gh.develop_ci = [(f"w{i}", "j", "completed", "success") for i in range(4)]
    ship.watch_develop(rig.engine)
    rig.gh.develop_ci = [(f"w{i}", "j", "completed", "failure") for i in range(4)]
    ship.watch_develop(rig.engine)
    filed = [i for i in rig.gh.issues.values() if i["title"].startswith("regression on develop")]
    assert len(filed) == 2


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
    from typing import Any

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
