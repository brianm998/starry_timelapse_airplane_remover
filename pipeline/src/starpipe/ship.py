"""PUBLISH, CI, CI-FIX and LAND (plan §7.1, §8.5, §10), plus the post-merge watch and stop-the-line (§10.3).

Functions over an Engine so engine.py stays about the model stages. Everything outside the repo is the engine's injected
GitHub, clock and sleep, so this runs under fakes and a local bare origin.
"""

from __future__ import annotations

import asyncio
import json
import re
from datetime import datetime
from pathlib import Path
from typing import TYPE_CHECKING, Any

from . import ci, gherkin_nightly, gitutil, landing, tickets, trust, worktrees
from .db import Ticket
from .github import GitHubError

if TYPE_CHECKING:
    from .engine import Engine

MAX_CI_FIX = 2
GATE_ERROR_LIMIT = 5  # the same feature-gate error on the same head this many polls in a row parks the ticket
TRANSIENT_ERROR = re.compile(r"HTTP 5\d\d|timed out|timeout|connection|network|temporar|rate limit|could not resolve", re.IGNORECASE)
FEATURE_RUN_WAIT_S = 600.0  # a dispatched feature run that has not appeared by then is dispatched again
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


def fetch_jobs(eng: Engine, sha: str, keep_titles: tuple[str, ...] = ()) -> list[ci.Job]:
    """The PR's jobs. Runs of post-merge-only workflows are ignored and cancelled, except a dispatched run whose display_title is in
    `keep_titles` (a ticket's own Gherkin feature run): feature_gate owns it, so the PR judge neither cancels nor judges it."""
    every = [r for r in eng.gh.workflow_runs(sha=sha)
             if not (r.get("event") == "workflow_dispatch" and r.get("display_title") in keep_titles)]
    runs, post_merge = ci.split_post_merge(every, eng.config.ci_post_merge_workflows)
    for run in post_merge:
        if run.get("status") != "completed":
            eng.gh.cancel_run(int(run["id"]))  # nobody waits for it, and it holds a macOS runner other work needs
    return ci.parse_jobs(runs, {int(r["id"]): eng.gh.run_jobs(int(r["id"]), ci.run_version(r)) for r in runs})


def _infra(eng: Engine, job: ci.Job) -> bool:
    if (job.conclusion or "") in ci.INFRA_CONCLUSIONS:
        return True
    try:
        return bool(ci.INFRA_LOG.search(eng.gh.failed_log(job.run_id)))
    except GitHubError:
        return False


def _judge(eng: Engine, key: int | str, sha: str, reran: set[tuple[str, str]], keep_titles: tuple[str, ...] = ()) -> ci.Verdict:
    """Fetch the PR's jobs and judge them. Network calls: runs in a worker thread, never on the event loop."""
    return ci.judge(fetch_jobs(eng, sha, keep_titles), eng.db.baseline, now=eng.clock(),
                    head_pushed_at=float(eng.db.get(f"pushed_at:{key}") or eng.clock()),
                    settle_s=eng.config.ci_settle_s, blocking_wait_s=eng.config.ci_blocking_wait_s,
                    reran=reran, infra=lambda j: _infra(eng, j))


def _rerun(eng: Engine, number: int | None, jobs: list[ci.Job]) -> list[ci.Job]:
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


def _dispatch_features(eng: Engine, t: Ticket, sha: str, title: str, features: list[str]) -> None:
    """Make the ticket's head exist on origin, then dispatch gherkin.yml there with the features. Worker thread."""
    pushed = push(eng, t)
    if pushed != sha:
        raise RuntimeError(f"the branch head moved from {sha[:10]} to {pushed[:10]} while it was being pushed")
    eng.gh.dispatch_workflow(gherkin_nightly.WORKFLOW_FILE, t.branch or "", {"features": ",".join(features)})
    eng.db.put(f"gherkin_run:{t.number}", json.dumps({"sha": sha, "title": title, "at": eng.clock()}))
    eng.db.put(f"gherkin_reran:{t.number}", None)
    eng.db.event("gherkin-dispatched", t.number, sha=sha, features=features)


def _is_feature_run(run: dict[str, Any], sha: str, title: str, since: float) -> bool:
    """A dispatched run for this head: titled `title`, or, on a branch cut before gherkin.yml had a run-name, titled by the workflow's
    name (the REST API) or path (`gh`) and created no earlier than the dispatch (GitHub's title for a run-name-less workflow; matching only by title redispatched
    every ten minutes and each new run cancelled the last)."""
    if run.get("event") != "workflow_dispatch" or run.get("head_sha") != sha:
        return False
    if run.get("display_title") == title:
        return True
    created = str(run.get("created_at") or "")
    return (run.get("display_title") in (gherkin_nightly.WORKFLOW_PATH, run.get("name")) and bool(created)
            and datetime.fromisoformat(created).timestamp() >= since)


def _feature_verdict(eng: Engine, t: Ticket, sha: str, title: str, since: float, reran: set[tuple[str, str]]) -> ci.Verdict | None:
    """Judge the newest dispatched run for this head and title; None when GitHub does not list one yet. Worker thread."""
    runs = [r for r in eng.gh.workflow_file_runs(gherkin_nightly.WORKFLOW_FILE, t.branch or "") if _is_feature_run(r, sha, title, since)]
    if not runs:
        return None
    run = max(runs, key=lambda r: int(r["id"]))
    rid = int(run["id"])
    jobs = ci.parse_jobs([run], {rid: eng.gh.run_jobs(rid, ci.run_version(run))})
    return ci.judge_feature_run(jobs, reran, run_completed=run.get("status") == "completed",
                                run_conclusion=run.get("conclusion"), run_id=rid)


def _is_transient(message: str) -> bool:
    return bool(TRANSIENT_ERROR.search(message))


def _behind_develop(eng: Engine, wt: Path) -> tuple[str, str] | None:
    """(base, merge-base) when the ticket's head is missing commits of develop, else None. Worker thread."""
    try:
        fetch(eng, wt)
    except RuntimeError:  # offline or no ssh here: judge by the origin/develop we already have
        pass
    base = f"origin/{eng.config.base_branch}"
    mb = gitutil.git(wt, "merge-base", base, "HEAD").strip()
    return None if mb == gitutil.git(wt, "rev-parse", base).strip() else (base, mb)


async def _gate_error(eng: Engine, t: Ticket, sha: str, exc: Exception, rejoin: bool) -> str:
    """The feature gate's dispatch or poll raised. Returns 'sleep' (try again after a poll), 'again' (the head is new: loop at once)
    or 'stop' (parked, or the catch-up did not end well).

    A 422 saying the workflow has no workflow_dispatch trigger is a branch that has fallen behind develop (its gherkin.yml is
    unparsable there): merge develop in, as the train does, and dispatch on the new head. The same error on the same head
    GATE_ERROR_LIMIT polls in a row parks the ticket, except an error that may clear by itself (5xx, network), which retries."""
    n, message = t.number, str(exc)
    eng.db.event("gherkin-poll-failed", n, error=message[:200])
    rec = json.loads(eng.db.get(f"gherkin_err:{n}") or "null")
    count = rec["count"] + 1 if rec and rec["sha"] == sha and rec["error"] == message else 1
    eng.db.put(f"gherkin_err:{n}", json.dumps({"sha": sha, "error": message, "count": count}))
    if _is_transient(message):
        return "sleep"
    if count >= GATE_ERROR_LIMIT:
        eng.db.put(f"gherkin_err:{n}", None)
        eng.park(t, f"the Gherkin feature gate failed {count} times in a row on {sha[:10]}: {message[:300]}")
        return "stop"
    if "workflow_dispatch" in message and "422" in message:
        behind = await asyncio.to_thread(_behind_develop, eng, Path(t.worktree or ""))
        if behind is not None:
            base, mb = behind
            eng.db.event("gherkin-catch-up", n, sha=sha, base=base)
            if not await catch_up(eng, t, base, mb, sha, landing.Overlap([], []), rejoin=rejoin):
                return "stop"
            return "again"
    return "sleep"


async def feature_gate(eng: Engine, t: Ticket, rejoin: bool = False) -> str:
    """Prove the ticket's Gherkin features (its `gherkin:` Pipeline value plus the plan's gherkin_features_to_run) on its own branch.

    'proven': no features, land-now, or the head's feature run is green (the proof is remembered per head sha, kv gherkin_ok:<n>).
    'retry': the run was red twice and CI-FIX changed the branch, so the head is new. 'stop': the ticket left its state or was parked.
    `rejoin` is the landing train: the ticket waits in `ready` and CI-FIX ends with it back there, not on its own PR."""
    n = t.number
    while True:
        cur = eng.db.ticket(n)
        if cur is None or cur.state != ("ready" if rejoin else "ci"):
            return "stop"
        features = tickets.gherkin_features(cur.body, cur.plan)
        if not features or land_now(eng, n):
            return "proven"
        sha = await asyncio.to_thread(gitutil.head_sha, Path(cur.worktree or ""))
        if eng.db.get(f"gherkin_ok:{n}") == sha:
            return "proven"
        title = tickets.feature_title(features)
        rec = json.loads(eng.db.get(f"gherkin_run:{n}") or "null")
        try:
            if not rec or rec["sha"] != sha or rec["title"] != title:
                await asyncio.to_thread(_dispatch_features, eng, cur, sha, title, features)
                eng.db.put(f"gherkin_err:{n}", None)
                continue
            reran = {tuple(k) for k in json.loads(eng.db.get(f"gherkin_reran:{n}") or "[]")}
            verdict = await asyncio.to_thread(_feature_verdict, eng, cur, sha, title, float(rec["at"]) - 60, reran)
        except (GitHubError, RuntimeError) as exc:
            step = await _gate_error(eng, cur, sha, exc, rejoin)
            if step == "stop":
                return "stop"
            if step == "sleep":
                await eng.sleep(eng.config.ci_poll_s)
            continue
        eng.db.put(f"gherkin_err:{n}", None)
        age = eng.clock() - float(rec["at"])
        if verdict is None:
            if age > FEATURE_RUN_WAIT_S:  # dispatched, but no such run ever showed up: dispatch again
                eng.db.put(f"gherkin_run:{n}", None)
            else:
                await eng.sleep(eng.config.ci_poll_s)
        elif verdict.kind == "pending":
            await eng.sleep(ci.poll_delay(age, eng.config.ci_poll_s))
        elif verdict.kind == "rerun":
            ready = await asyncio.to_thread(_rerun, eng, n, [j for j in verdict.rerun if j.run_done])
            reran |= {j.key for j in ready}
            eng.db.put(f"gherkin_reran:{n}", json.dumps(sorted(reran)))
            await eng.sleep(eng.config.ci_poll_s)
        elif verdict.kind == "pass":
            eng.db.put(f"gherkin_ok:{n}", sha)
            eng.db.event("gherkin-proven", n, sha=sha, features=features)
            return "proven"
        else:
            fixed = await ci_fix(eng, cur, verdict, rejoin)
            eng.db.put(f"gherkin_ok:{n}", None)
            return "retry" if fixed else "stop"


async def run_ci(eng: Engine, t: Ticket) -> bool:
    """Judge CI until it passes (-> landing), parks, or needs a CI-FIX. True when the ticket should keep going."""
    while True:
        cur = eng.db.ticket(t.number)
        if cur is None or cur.state != "ci":
            return False
        if land_now(eng, t.number):  # re-read every pass, so a mark set while we sleep in a poll is seen
            await asyncio.to_thread(_finish_ci, eng, cur, ["tests bypassed by the owner (land-now)"])
            return True
        gate = await feature_gate(eng, cur)  # the ticket's own Gherkin features, before its PR's CI is judged
        if gate == "stop":
            return False
        if gate == "retry":
            continue
        sha = gitutil.head_sha(Path(cur.worktree or ""))
        reran = {tuple(k) for k in json.loads(eng.db.get(f"reran:{t.number}") or "[]")}
        keep = (tickets.feature_title(tickets.gherkin_features(cur.body, cur.plan)),)
        try:
            verdict = await asyncio.to_thread(_judge, eng, t.number, sha, reran, keep)
        except GitHubError as exc:
            await eng.sleep(eng.config.ci_poll_s)
            eng.db.event("ci-poll-failed", t.number, error=str(exc))
            continue
        eng.db.record_ci(t.number, sha, verdict.kind, {"reason": verdict.reason})
        if verdict.kind == "pending":
            pushed = float(eng.db.get(f"pushed_at:{t.number}") or eng.clock())
            await eng.sleep(ci.poll_delay(eng.clock() - pushed, eng.config.ci_poll_s))
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


async def ci_fix(eng: Engine, t: Ticket, verdict: ci.Verdict, rejoin: bool = False) -> bool:
    """A model stage fixes what CI said was red. `rejoin` (the landing train) ends with the ticket back in `ready`, to be
    batched again, instead of pushing its own branch and going back to its own CI."""
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
    if rejoin:
        eng.db.put(f"gherkin_ok:{t.number}", None)  # the head changed: the old feature run proves nothing about it
        eng.db.set_fields(t.number, pr_number=None)
        eng._to_state(t.number, "ready")  # pyright: ignore[reportPrivateUsage]
        return True
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


async def catch_up(eng: Engine, t: Ticket, base: str, mb: str, head: str, ov: landing.Overlap, rejoin: bool = False) -> bool:
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
    if rejoin:  # the landing train: back in the queue, to be batched on the new develop
        eng.db.put(f"gherkin_ok:{t.number}", None)  # the head changed (develop merged in): its feature run must be done again
        eng._to_state(t.number, "ready")  # pyright: ignore[reportPrivateUsage]
        return True
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
    """Refresh the develop baseline from the latest run of each workflow that ended success or failure; react to new reds
    (§10.3). Gherkin's baseline is kept but never ticketed here: its nightly full run reruns and files its own (gherkin_nightly.py).
    A run cancelled by a newer push is completed but says nothing about the code, so it is skipped: the workflow's
    earlier success/failure run stays the baseline. So is a job that concluded `skipped` inside an otherwise finished run."""
    base = eng.config.base_branch
    runs = [r for r in eng.gh.workflow_runs(branch=base)
            if r.get("status") == "completed" and r.get("conclusion") in ("success", "failure")]
    latest: dict[str, dict[str, object]] = {}
    for r in runs:  # newest first
        latest.setdefault(str(r.get("name")), r)
    seeding = eng.db.baseline_size() == 0
    for run in latest.values():
        for job in ci.parse_jobs([run], {int(str(run["id"])): eng.gh.run_jobs(int(str(run["id"])), ci.run_version(run))}):
            if job.conclusion == "skipped":
                continue  # the push run skipped it because the batch PR already tested this tree: that result stays the baseline
            before = eng.db.baseline(job.workflow, job.job)
            now = job.conclusion or "failure"
            eng.db.set_baseline(job.workflow, job.job, str(run.get("head_sha")), now)
            pending = f"red_pending:{job.workflow}/{job.job}"
            if job.workflow.lower() == "gherkin":
                eng.db.put(pending, None)
                continue  # the nightly owns Gherkin's tickets
            if seeding or before is None:
                continue  # reds present when the pipeline first started are the known-red ledger, not tickets
            sha = str(run.get("head_sha"))
            infra = (job.conclusion or "failure") in ci.INFRA_CONCLUSIONS  # cancelled / timed out is the runner, not a regression
            if job.red and not infra:
                if job.workflow == ci.GATE:
                    if before == "success":
                        _new_red(eng, job, sha)  # the gate reacts at once: landing stops
                elif before == "success":
                    eng.db.put(pending, sha)  # first sighting: wait for a second, different run to agree before filing a ticket
                elif eng.db.get(pending) not in (None, sha):
                    eng.db.put(pending, None)
                    _new_red(eng, job, sha)
            elif not job.red:
                eng.db.put(pending, None)  # green again: that was a flake
            if job.workflow == ci.GATE and job.conclusion == "success" and eng.db.get("stop_line"):
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
