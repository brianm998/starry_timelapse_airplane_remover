"""PUBLISH, CI, CI-FIX and LAND (plan §7.1, §8.5, §10), plus the post-merge watch and stop-the-line (§10.3).

Functions over an Engine so engine.py stays about the model stages. Everything outside the repo is the engine's injected
GitHub, clock and sleep, so this runs under fakes and a local bare origin.
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import TYPE_CHECKING

from . import ci, gitutil, landing, trust, worktrees
from .db import Ticket
from .github import GitHubError

if TYPE_CHECKING:
    from .engine import Engine

MAX_CI_FIX = 2
LANDING_STATES = ("ci", "landing")
BYPASS_NOTE = "The owner landed this with land-now: CI, the overlap re-test and the stop-line wait were bypassed."


def land_now(eng: Engine, n: int) -> bool:
    """The owner's land-now mark (db kv, set by the monitor): stop waiting for tests and land."""
    return bool(eng.db.get(f"land_now:{n}"))


def pr_body(eng: Engine, t: Ticket) -> str:
    plan = t.plan or {}
    checks = eng.db.checks(t.number, gitutil.head_sha(Path(t.worktree or "")))
    rows = "\n".join(f"| {c['check_id']} | {c['result']} | {json.loads(c['counts']).get('executed', 0)} |" for c in checks)
    controls = json.loads(eng.db.get(f"controls:{t.number}") or "[]")
    acceptance = "\n".join(f"- {a['id']}: {a['check']}" for a in plan.get("acceptance", []))
    notes = eng.db.get(f"ci_notes:{t.number}") or ""
    return (f"{trust.marker('pr', t.number)}\nCloses #{t.number}\n\n## Plan\n{plan.get('summary', '')}\n\n"
            f"## Acceptance\n{acceptance}\n\n## Local checks at HEAD\n| check | result | tests |\n|---|---|---|\n{rows}\n\n"
            f"## Negative control\n{json.dumps(controls) if controls else 'none planned'}\n"
            + (f"\n## CI notes\n{notes}\n" if notes else "")
            + (f"\n## Tests bypassed\n{BYPASS_NOTE}\n" if land_now(eng, t.number) else "")
            + "\nOpened by the star pipeline.\n")


def push(eng: Engine, t: Ticket) -> str:
    wt = Path(t.worktree or "")
    if eng.config.remote == "https":
        gitutil.remote_push(wt, eng.config.owner, eng.config.repo, t.branch or "")
    else:
        gitutil.git(wt, "push", "--quiet", "origin", f"HEAD:refs/heads/{t.branch}")
    eng.db.put(f"pushed_at:{t.number}", str(eng.clock()))
    return gitutil.head_sha(wt)


def publish(eng: Engine, t: Ticket) -> bool:
    try:
        push(eng, t)
        pr = eng.gh.find_pr(t.branch or "")
        if pr is None:
            pr = eng.gh.create_pr(t.title, pr_body(eng, t), t.branch or "", eng.config.base_branch)
        else:
            eng.gh.update_pr(int(pr["number"]), pr_body(eng, t))
    except (GitHubError, RuntimeError) as exc:
        eng.park(t, f"publish failed: {exc}")
        return False
    eng.db.set_fields(t.number, pr_number=int(pr["number"]))
    eng.db.event("published", t.number, pr=pr["number"])
    eng._to_state(t.number, "ci")  # pyright: ignore[reportPrivateUsage]
    return True


def fetch_jobs(eng: Engine, sha: str) -> list[ci.Job]:
    runs = eng.gh.workflow_runs(sha=sha)
    return ci.parse_jobs(runs, {int(r["id"]): eng.gh.run_jobs(int(r["id"])) for r in runs})


def _infra(eng: Engine, job: ci.Job) -> bool:
    if (job.conclusion or "") in ci.INFRA_CONCLUSIONS:
        return True
    try:
        return bool(ci.INFRA_LOG.search(eng.gh.failed_log(job.run_id)))
    except GitHubError:
        return False


def _judge(eng: Engine, number: int, sha: str, reran: set[tuple[str, str]]) -> ci.Verdict:
    """Fetch the PR's jobs and judge them. Network calls: runs in a worker thread, never on the event loop."""
    return ci.judge(fetch_jobs(eng, sha), eng.db.baseline, now=eng.clock(),
                    head_pushed_at=float(eng.db.get(f"pushed_at:{number}") or eng.clock()),
                    settle_s=eng.config.ci_settle_s, blocking_wait_s=eng.config.ci_blocking_wait_s,
                    reran=reran, infra=lambda j: _infra(eng, j))


def _rerun(eng: Engine, number: int, jobs: list[ci.Job]) -> list[ci.Job]:
    """Rerun the failed jobs of each finished run; the jobs whose rerun GitHub refused are left for the next poll."""
    ready = list(jobs)
    for run_id in {j.run_id for j in jobs}:
        try:
            eng.gh.rerun_failed(run_id)
        except GitHubError as exc:  # still running, or already rerun: look again next poll
            eng.db.event("rerun-refused", number, run=run_id, error=str(exc)[:200])
            ready = [j for j in ready if j.run_id != run_id]
    return ready


def _finish_ci(eng: Engine, cur: Ticket, notes: list[str]) -> None:
    eng.db.put(f"ci_notes:{cur.number}", "\n".join(f"- {n}" for n in notes) or None)
    if notes and cur.pr_number:
        eng.gh.update_pr(cur.pr_number, pr_body(eng, cur))
    eng._to_state(cur.number, "landing")  # pyright: ignore[reportPrivateUsage]


async def run_ci(eng: Engine, t: Ticket) -> bool:
    """Judge CI until it passes (-> landing), parks, or needs a CI-FIX. True when the ticket should keep going."""
    while True:
        cur = eng.db.ticket(t.number)
        if cur is None or cur.state != "ci":
            return False
        if land_now(eng, t.number):  # re-read every pass, so a mark set while we sleep in a poll is seen
            await asyncio.to_thread(_finish_ci, eng, cur, ["tests bypassed by the owner (land-now)"])
            return True
        sha = gitutil.head_sha(Path(cur.worktree or ""))
        reran = {tuple(k) for k in json.loads(eng.db.get(f"reran:{t.number}") or "[]")}
        try:
            verdict = await asyncio.to_thread(_judge, eng, t.number, sha, reran)
        except GitHubError as exc:
            await eng.sleep(eng.config.ci_poll_s)
            eng.db.event("ci-poll-failed", t.number, error=str(exc))
            continue
        eng.db.record_ci(t.number, sha, verdict.kind, {"reason": verdict.reason})
        if verdict.kind == "pending":
            await eng.sleep(eng.config.ci_poll_s)
        elif verdict.kind == "rerun":
            ready = await asyncio.to_thread(_rerun, eng, t.number, [j for j in verdict.rerun if j.run_done])
            reran |= {j.key for j in ready}
            eng.db.put(f"reran:{t.number}", json.dumps(sorted(reran)))
            await eng.sleep(eng.config.ci_poll_s)
        elif verdict.kind == "pass":
            notes = [f"known red on develop (not blocking): {j.workflow}/{j.job}" for j in verdict.known_red]
            notes += [f"still running after {eng.config.ci_blocking_wait_s / 3600:g} h (demoted to the post-merge watch): "
                      f"{j.workflow}/{j.job}" for j in verdict.demoted]
            await asyncio.to_thread(_finish_ci, eng, cur, notes)
            return True
        else:
            if not await ci_fix(eng, cur, verdict):
                return False


async def ci_fix(eng: Engine, t: Ticket, verdict: ci.Verdict) -> bool:
    if len(eng.db.stages(t.number, "ci-fix")) >= MAX_CI_FIX:
        eng.park(t, f"CI still red after {MAX_CI_FIX} fix cycles: {verdict.reason}")
        return False
    first = verdict.blocking[0]
    try:
        log = await asyncio.to_thread(eng.gh.failed_log, first.run_id)
    except GitHubError as exc:
        log = f"(could not fetch the log: {exc})"
    prompt = (f"{eng._ticket_text(t)}\n\nCI failed on the PR: {verdict.reason}\n\nFailing log (trimmed):\n{log}")  # pyright: ignore[reportPrivateUsage]
    result, _ = await eng.model_stage(t, "ci-fix", prompt, fresh=True)
    if not result.ok:
        return False
    failure = await asyncio.to_thread(eng._run_verification, t, Path(t.worktree or ""))  # pyright: ignore[reportPrivateUsage]
    if failure:
        eng.park(t, f"CI-FIX did not pass local verification: {failure[:300]}")
        return False
    await asyncio.to_thread(push, eng, t)
    return True


def fetch(eng: Engine, wt: Path) -> None:
    if eng.config.remote == "https":
        gitutil.remote_fetch(wt, eng.config.owner, eng.config.repo, eng.config.base_branch)
    else:
        gitutil.git(wt, "fetch", "--quiet", "origin")


def _remote(eng: Engine, wt: Path) -> str:
    fetch(eng, wt)
    return f"origin/{eng.config.base_branch}"


async def land(eng: Engine, t: Ticket) -> bool:
    """LAND (§10.1). One ticket at a time. True when the ticket should keep going (back to CI after a catch-up)."""
    async with eng.land_lock:
        while eng.db.get("pause") in ("all", "landing") or (eng.db.get("stop_line") and not land_now(eng, t.number)):
            await eng.sleep(eng.config.ci_poll_s)
        cur = eng.db.ticket(t.number)
        if cur is None or cur.state != "landing":
            return False
        step = await asyncio.to_thread(_prepare_land, eng, cur)
        if step[0] == "catch_up":
            return await catch_up(eng, cur, step[1], step[2], step[3], step[4])
        return await asyncio.to_thread(merge, eng, cur, step[3])


def _prepare_land(eng: Engine, cur: Ticket) -> tuple[str, str, str, str, landing.Overlap]:
    """Fetch, look at the PR, and decide: merge it as it is, or merge develop into it first. Network and git: worker thread."""
    wt = Path(cur.worktree or "")
    base = _remote(eng, wt)
    pr = eng.gh.pr(cur.pr_number or 0)
    head = pr["head"]["sha"]
    mb = gitutil.git(wt, "merge-base", base, head).strip()
    none = landing.Overlap([], [])
    if mb != gitutil.git(wt, "rev-parse", base).strip():
        pr_files = [p for p in gitutil.git(wt, "diff", "--name-only", f"{mb}..{head}").splitlines() if p]
        bypass = land_now(eng, cur.number)
        ov = none if bypass and pr.get("mergeable") is not False else landing.overlap(wt, mb, base, pr_files)
        if ov.any or pr.get("mergeable") is False:
            return ("catch_up", base, mb, head, ov)
    return ("merge", base, mb, head, none)


def _merge_develop(wt: Path, base: str) -> tuple[str, list[str]]:
    done = gitutil.git(wt, "merge", "--no-edit", base, check=False)
    return done, gitutil.git(wt, "diff", "--name-only", "--diff-filter=U").split()


async def catch_up(eng: Engine, t: Ticket, base: str, mb: str, head: str, ov: landing.Overlap) -> bool:
    wt = Path(t.worktree or "")
    done, conflicted = await asyncio.to_thread(_merge_develop, wt, base)
    if conflicted or "CONFLICT" in done:
        prompt = (f"{eng._ticket_text(t)}\n\nConflicts merging {base}:\n" + "\n".join(conflicted))  # pyright: ignore[reportPrivateUsage]
        result, _ = await eng.model_stage(t, "conflict", prompt, fresh=True)
        if not result.ok:
            return False
    dropped = await asyncio.to_thread(landing.audit, wt, mb, base, head)
    if dropped:
        shown = "; ".join(f"{d.file}: {d.line.strip()[:80]}" for d in dropped[:5])
        eng.park(t, f"conflict resolution dropped {len(dropped)} landed line(s): {shown}")
        return False
    failure = None if land_now(eng, t.number) else await asyncio.to_thread(eng._run_verification, t, wt)  # pyright: ignore[reportPrivateUsage]
    if failure:
        eng.park(t, f"after catching up with develop, verification failed: {failure[:300]}")
        return False
    await asyncio.to_thread(push, eng, t)
    eng._to_state(t.number, "ci")  # pyright: ignore[reportPrivateUsage]
    return True


def merge(eng: Engine, t: Ticket, head: str) -> bool:
    n = t.pr_number or 0
    try:
        eng.gh.merge_pr(n, head)
    except GitHubError as exc:
        eng.park(t, f"merge refused: {exc}")
        return False
    wt = Path(t.worktree or "")
    fetch(eng, wt)
    merged = eng.gh.pr(n)
    sha = merged.get("merge_commit_sha") or ""
    base = f"origin/{eng.config.base_branch}"
    reachable = bool(sha) and gitutil.is_ancestor(wt, sha, base)
    if not (reachable and merged.get("merged")):
        eng.notifier.alert("phantom-landing", t.number, f"#{t.number}: merge reported but {sha[:10]} is not on {base}")
        eng.park(t, "landing could not be verified: the merge commit is not on origin/develop")
        return False
    if eng.gh.issue(t.number).get("state") != "closed":
        eng.gh.close_issue(t.number, "completed")
    eng.gh.delete_branch(t.branch or "")
    eng.gh.add_labels(t.number, ["pipe:landed"])
    worktrees.remove(eng.repo, t.number, keep_branch=False, branch=t.branch)
    eng._to_state(t.number, "landed")  # pyright: ignore[reportPrivateUsage]
    eng.db.event("landed", t.number, merge=sha)
    return True


# post-merge watch and stop-the-line ---------------------------------------------------------------------------------
def watch_develop(eng: Engine) -> None:
    """Refresh the develop baseline from the latest completed run of each workflow; react to new reds (§10.3)."""
    base = eng.config.base_branch
    runs = [r for r in eng.gh.workflow_runs(branch=base) if r.get("status") == "completed"]
    latest: dict[str, dict[str, object]] = {}
    for r in runs:  # newest first
        latest.setdefault(str(r.get("name")), r)
    seeding = eng.db.baseline_size() == 0
    for run in latest.values():
        for job in ci.parse_jobs([run], {int(str(run["id"])): eng.gh.run_jobs(int(str(run["id"])))}):
            before = eng.db.baseline(job.workflow, job.job)
            now = job.conclusion or "failure"
            eng.db.set_baseline(job.workflow, job.job, str(run.get("head_sha")), now)
            if seeding or before is None:
                continue  # reds present when the pipeline first started are the known-red ledger, not tickets
            if before == "success" and job.red and (job.conclusion or "failure") not in ci.INFRA_CONCLUSIONS:
                _new_red(eng, job, str(run.get("head_sha")))  # cancelled / timed out is the runner, not a regression
            elif job.workflow == ci.GATE and job.conclusion == "success" and eng.db.get("stop_line"):
                eng.db.put("stop_line", None)
                eng.notifier.clear("develop-red", None)
                eng.db.event("stop-line-cleared", None, job=job.job)


def _auto_open(eng: Engine) -> int:
    return len([i for i in eng.gh.paged("issues?state=open&labels=pipe:filed-by-pipeline&per_page=100")
                if any(lab["name"] == "pipeline" for lab in i.get("labels", []))])


def _new_red(eng: Engine, job: ci.Job, sha: str) -> None:
    gate = job.workflow == ci.GATE
    if gate:
        eng.db.put("stop_line", f"{job.workflow}/{job.job}")
        eng.notifier.alert("develop-red", None, f"{job.workflow}/{job.job} is red on develop at {sha[:10]}")
    if _auto_open(eng) >= eng.config.max_auto_tickets:
        eng.db.event("auto-ticket-capped", None, job=f"{job.workflow}/{job.job}")
        return
    log = ""
    try:
        log = eng.gh.failed_log(job.run_id, 4000)
    except GitHubError:
        pass
    title = f"develop red: {job.workflow}/{job.job}" if gate else f"regression on develop: {job.workflow}/{job.job}"
    body = (f"## Goal\nMake {job.workflow}/{job.job} green on develop again.\n\n## Context\nIt was green and is now red at "
            f"{sha}. Run {job.run_id}.\n\n```\n{log}\n```\n\n## Acceptance criteria\n- A1: {job.workflow}/{job.job} passes on "
            f"develop — check: review: CI run on the fix PR\n\n## Tests\nnone: restores an existing check\n\n## Out of scope\n"
            f"Unrelated failures.\n")
    n = eng.gh.create_issue(title, body)
    eng.gh.add_labels(n, ["pipe:filed-by-pipeline", "pipeline", "p0" if gate else "p1"])
