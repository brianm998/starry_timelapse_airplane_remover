"""The nightly dispatch of the full Gherkin matrix on GitHub (not T4, the local nightly in nightly.py).

The "Gherkin" workflow takes 3-4 hours, so a push to the base branch no longer starts it. Once a day, at `gherkin_nightly_start`,
the daemon decides whether a full run is worth it, and dispatches one when it is:

* a full run already queued or running: skip;
* the newest finished full run (green or red, not cancelled) tested exactly the current tip: skip, there is nothing new to learn;
* no green full run ever: dispatch;
* otherwise diff the last green full run's sha against the tip and dispatch only if a file matches the workflow's own
  `on.pull_request.paths` globs (read from gherkin.yml at the tip, so the list lives in one place).

Then `follow_once` acts on the dispatched run's results: the failed jobs are rerun once, a job that fails again is red (one fix
ticket per feature, legs grouped), one that passes on the rerun is flaky (recorded, and a ticket to make it reliable). A job the
runner cancelled is rerun and never ticketed.

A "full" run is one named `Gherkin: full` (a dispatch with no `features`) or a push (older base-branch pushes had no run-name and ran
everything). A green subset run (`Gherkin: a,b`) is never a green full run. Every outside effect is injected, so the tests run it
in milliseconds.
"""

from __future__ import annotations

import json
import re
import subprocess
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from . import ci, gitutil
from .config import Config
from .db import Database
from .github import GitHub, GitHubError
from .notify import Notifier
from .tickets import FilingError, file_ticket

WORKFLOW_FILE = "gherkin.yml"
WORKFLOW_PATH = f".github/workflows/{WORKFLOW_FILE}"
FULL_TITLE = "Gherkin: full"
IN_FLIGHT = ("queued", "in_progress", "waiting", "pending", "requested")
FINISHED = ("success", "failure")  # a cancelled run tested nothing
RETRY_AFTER_ERROR_S = 600.0
FOLLOW_KEY = "gherkin_nightly_follow"
FOLLOW_GIVE_UP_S = 3 * 86400.0  # a followed run that never shows up completed is dropped after this
LOG_TAIL_LINES = 40


@dataclass
class Decision:
    action: str  # "dispatch", "skip" or "error"
    reason: str
    base_sha: str | None = None  # the last green full run's sha
    run_id: int | str | None = None  # the dispatched run, or the one in flight
    green_at: str | None = None  # when that green run was created
    tip: str | None = None


# the workflow's path list ---------------------------------------------------------------------------------------------
def relevant_globs(yml_text: str) -> list[str]:
    """`on.pull_request.paths` of a workflow file: the one list of what Gherkin covers.

    A small indentation-aware reader for the block-list form (there is no YAML library in the pinned runtime). An empty or missing
    list raises: treating that as "everything is relevant" would turn the nightly into a nightly dispatch regardless."""
    path: list[tuple[int, str]] = []  # (indent, key) of the open mappings
    found: list[str] = []
    for raw in yml_text.splitlines():
        line = raw.split(" #")[0].rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        text = line.strip()
        if text.startswith("- "):
            if [k for _, k in path] == ["on", "pull_request", "paths"]:
                found.append(text[2:].strip().strip("'\""))
            continue
        while path and path[-1][0] >= indent:
            path.pop()
        key = text.split(":", 1)[0].strip()
        path.append((indent, key))
    if not found:
        raise ValueError(f"no on.pull_request.paths list in {WORKFLOW_PATH}")
    return found


def _glob_regex(glob: str) -> re.Pattern[str]:
    out, i = "", 0
    while i < len(glob):
        if glob.startswith("**", i):
            out += ".*"
            i += 2
            if glob.startswith("/", i) and out.endswith(".*"):  # `a/**/b` also matches `a/b`
                out = out[:-2] + "(?:.*/)?"
                i += 1
        elif glob[i] == "*":
            out += "[^/]*"
            i += 1
        elif glob[i] == "?":
            out += "[^/]"
            i += 1
        else:
            out += re.escape(glob[i])
            i += 1
    return re.compile(out + r"\Z")


def path_matches(path: str, globs: list[str]) -> bool:
    """GitHub path-filter semantics: `**` crosses `/`, `*` does not."""
    return any(_glob_regex(g).match(path) for g in globs)


# runs ---------------------------------------------------------------------------------------------------------------
def is_full(run: dict[str, Any]) -> bool:
    return run.get("event") == "push" or run.get("display_title") == FULL_TITLE


def _newest(runs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(runs, key=lambda r: int(r["id"]), reverse=True)


def last_green_full(runs: list[dict[str, Any]]) -> dict[str, Any] | None:
    return next((r for r in _newest(runs) if is_full(r) and r.get("status") == "completed" and r.get("conclusion") == "success"), None)


def decide(runs: list[dict[str, Any]], tip: str, globs: list[str], changed: Callable[[str], list[str] | None],
           force: bool = False) -> Decision:
    """`runs`: the workflow's runs on the base branch. `changed(sha)`: files that differ from `sha` to the tip, None when the
    sha is not in the local repo."""
    full = [r for r in _newest(runs) if is_full(r)]
    green = last_green_full(runs)
    base = green["head_sha"] if green else None
    green_at = (green.get("created_at") or "")[:10] if green else None

    def out(action: str, reason: str, run_id: int | str | None = None) -> Decision:
        return Decision(action, reason, base, run_id, green_at, tip)

    flying = next((r for r in full if r.get("status") in IN_FLIGHT), None)
    if flying is not None:
        return out("skip", "a full run is already in flight", flying["id"])
    if not force:
        last = next((r for r in full if r.get("status") == "completed" and r.get("conclusion") in FINISHED), None)
        if last is not None and last["head_sha"] == tip:
            return out("skip", f"the tip {tip[:10]} was already tested (run {last['id']}: {last['conclusion']})", last["id"])
    if force:
        return out("dispatch", "forced")
    if base is None:
        return out("dispatch", "no green full run yet")
    files = changed(base)
    if files is None:
        return out("dispatch", f"the last green full run's sha {base[:10]} is not in the repo; cannot tell what changed")
    hits = [f for f in files if path_matches(f, globs)]
    if not hits:
        return out("skip", f"nothing relevant changed since the last green full run {base[:10]} ({len(files)} files, none match)")
    return out("dispatch", f"{len(hits)} relevant file(s) changed since the last green full run {base[:10]}, e.g. {hits[0]}")


# the outside world -----------------------------------------------------------------------------------------------------
@dataclass
class Source:
    """What the decision needs from git, replaceable in tests."""

    fetch: Callable[[], None]
    tip: Callable[[], str]
    workflow_text: Callable[[], str]
    changed: Callable[[str], list[str] | None]


def git_source(repo: Path, base: str, fetch: Callable[[Path], None]) -> Source:
    ref = f"origin/{base}"

    def changed(sha: str) -> list[str] | None:
        have = subprocess.run(["git", "-C", str(repo), "cat-file", "-e", f"{sha}^{{commit}}"], capture_output=True, check=False)
        if have.returncode != 0:
            return None
        return gitutil.git(repo, "diff", "--name-only", sha, ref).splitlines()

    return Source(lambda: fetch(repo), lambda: gitutil.git(repo, "rev-parse", ref).strip(),
                  lambda: gitutil.git(repo, "show", f"{ref}:{WORKFLOW_PATH}"), changed)


def _dispatched_run(gh: GitHub, base: str, before: set[int], sleep: Callable[[float], None]) -> int | str:
    """A dispatch answers 204 with no run id: find the new run, which can take a few seconds to appear."""
    for attempt in range(4):
        if attempt:
            sleep(3.0)
        new = [r for r in gh.workflow_file_runs(WORKFLOW_FILE, base) if r.get("event") == "workflow_dispatch" and int(r["id"]) not in before]
        if new:
            return int(_newest(new)[0]["id"])
    return "unknown"


def run_once(db: Database, gh: GitHub, config: Config, source: Source, force: bool = False,
             sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.time) -> Decision:
    """One decision, acted on and recorded. An error is recorded too and returned as action "error": the caller does not mark the
    day done."""
    base = config.base_branch
    try:
        source.fetch()
        tip = source.tip()
        globs = relevant_globs(source.workflow_text())
        runs = gh.workflow_file_runs(WORKFLOW_FILE, base)
        decision = decide(runs, tip, globs, source.changed, force)
        if decision.action == "dispatch":
            before = {int(r["id"]) for r in runs}
            gh.dispatch_workflow(WORKFLOW_FILE, base, {"features": ""})
            decision.run_id = _dispatched_run(gh, base, before, sleep)
            if decision.run_id != "unknown":
                db.put(FOLLOW_KEY, json.dumps({"run_id": decision.run_id, "phase": "await1", "at": clock(), "failures": []}))
    except (GitHubError, RuntimeError, ValueError, OSError) as exc:
        decision = Decision("error", str(exc)[:300])
    db.event("gherkin-nightly", None, action=decision.action, reason=decision.reason, base_sha=decision.base_sha,
             run_id=decision.run_id, tip=decision.tip, forced=force)
    db.put("gherkin_nightly_last", json.dumps({"at": clock(), "action": decision.action, "reason": decision.reason,
                                               "base_sha": decision.base_sha, "run_id": decision.run_id,
                                               "green_at": decision.green_at, "tip": decision.tip, "forced": force}))
    return decision


# the results: rerun once, then red or flaky -------------------------------------------------------------------------------
def split_job(name: str) -> tuple[str, str]:
    """(leg, feature) of a job named `<client> (<os>) · <label>`. The label is `shard N: a, b` or `ui`; the shard number goes, since
    it changes between nights when the matrix is rebalanced. A name with no ` · ` is its own feature on no named leg."""
    leg, sep, label = name.partition(" · ")
    if not sep:
        return "", name.strip()
    return leg.strip(), re.sub(r"^shard \d+:\s*", "", label.strip())


def log_tail(log: str, job_name: str) -> str:
    """The end of the failed log for one job (`gh run view --log-failed` prefixes each line with the job name and a tab)."""
    lines = log.splitlines()
    mine = [ln.split("\t", 2)[-1] for ln in lines if ln.startswith(job_name + "\t")]
    text = "\n".join((mine or lines)[-LOG_TAIL_LINES:]).strip().replace("```", "'''")  # never close the ticket's own fence
    return text or "(no log available)"


def _find_run(gh: GitHub, base: str, run_id: int | str) -> dict[str, Any] | None:
    return next((r for r in gh.workflow_file_runs(WORKFLOW_FILE, base) if str(r["id"]) == str(run_id)), None)


def _run_url(config: Config, run_id: int | str) -> str:
    return f"https://github.com/{config.owner}/{config.repo}/actions/runs/{run_id}"


def _failed_log(gh: GitHub, run_id: int | str) -> str:
    try:
        return gh.failed_log(int(run_id))
    except GitHubError:
        return ""  # expired or not available: the ticket says so


@dataclass
class Item:
    """One feature that needs a ticket (or a comment on an open one) tonight, with its legs."""

    kind: str  # "red" or "flaky"
    feature: str
    first: dict[str, str]  # leg -> log tail of attempt 1
    second: dict[str, str]  # leg -> log tail of the rerun (red only: a flaky job passed on it)

    @property
    def title(self) -> str:
        if self.kind == "red":
            return f"Gherkin nightly red: {self.feature}"
        return f"Gherkin flaky: {self.feature} ({', '.join(self.first)})"

    @property
    def legs(self) -> str:
        return ", ".join(leg or "(no leg)" for leg in self.first)


def _tails(tails: dict[str, str], heading: str = "###") -> str:
    return "\n\n".join(f"{heading} {leg or '(no leg)'}\n```\n{tail}\n```" for leg, tail in tails.items())


def red_body(item: Item, run_id: int | str, sha: str, url: str) -> str:
    return (f"## Goal\nMake the Gherkin feature `{item.feature}` pass again on develop. It failed in the nightly full run on both "
            f"attempts, on: {item.legs}.\n\n"
            f"## Context\nNightly full Gherkin run {run_id} ({url}) at develop {sha[:10]}. Each failed job was rerun once and failed "
            f"again, so this is not a one-off. The log tail of the rerun, per leg:\n\n{_tails(item.second)}\n\n"
            f"## Acceptance criteria\n- A1: `{item.feature}` passes on every listed leg ({item.legs}) — check: the next nightly "
            f"Gherkin run is green for it\n\n"
            f"## Tests\nnone: restores an existing check\n\n"
            f"## Pipeline\ngherkin: {item.feature}\n\n"
            f"## Out of scope\nFeatures other than `{item.feature}`; weakening or deleting the scenario to make it pass.\n")


def flaky_body(item: Item, run_id: int | str, sha: str, url: str, history: list[dict[str, Any]]) -> str:
    past = "\n".join(f"- {h['day']}: {h['leg'] or '(no leg)'} (run {h['run_id']})" for h in history) or "- none recorded"
    return (f"## Goal\nFind out why the Gherkin feature `{item.feature}` fails intermittently on {item.legs}, and fix the cause in "
            f"the test or the product. Candidates: a race, a fixed sleep, a timeout too tight for the runner, a hang in stard or the "
            f"app, state shared between scenarios, runner resource limits. A retry or a longer timeout alone is not a fix, unless "
            f"the investigation shows the timeout itself is wrong.\n\n"
            f"## Context\nNightly full Gherkin run {run_id} ({url}) at develop {sha[:10]}: the job failed on the first attempt and "
            f"passed on the rerun (a passing job has no failure log). Log tail of the failed attempt, per leg:\n\n"
            f"{_tails(item.first)}\n\n"
            f"Flake history of `{item.feature}`, from the pipeline database:\n{past}\n\n"
            f"## Acceptance criteria\n- A1: the cause of the intermittent failure is identified and removed, not hidden — check: "
            f"review: the change names the cause and fixes it in the test or the product; a retry or longer timeout alone is "
            f"rejected\n\n"
            f"## Tests\nnone: the fix is verified by the following nightly Gherkin runs staying green for it\n\n"
            f"## Pipeline\ngherkin: {item.feature}\n\n"
            f"## Out of scope\nFeatures other than `{item.feature}`.\n")


def _comment_text(item: Item, run_id: int | str, url: str) -> str:
    what = "failed again on the rerun" if item.kind == "red" else "failed, then passed on the rerun (flaky)"
    shown = item.second if item.kind == "red" else item.first
    return f"Gherkin nightly run {run_id} ({url}): `{item.feature}` {what} on {item.legs}.\n\n{_tails(shown, '####')}\n"


def covering_issue(gh: GitHub, item: Item) -> dict[str, Any] | None:
    """An open issue with this ticket's title, or one that names the feature (or any feature of its shard)."""
    names = [n for n in (x.strip() for x in item.feature.split(",")) if len(n) >= 4]  # `ui` would match anything
    patterns = [re.compile(rf"(?<![\w-]){re.escape(n)}(?![\w-])") for n in names]
    for issue in gh.paged("issues?state=open&per_page=100"):
        if "pull_request" in issue:
            continue
        title = issue.get("title") or ""
        if title.lower() == item.title.lower() or any(p.search(f"{title}\n{issue.get('body') or ''}") for p in patterns):
            return issue
    return None


def _open_pipeline_count(gh: GitHub) -> int:
    return len([i for i in gh.paged("issues?state=open&labels=pipeline&per_page=100") if "pull_request" not in i])


def classify(failures: list[dict[str, Any]], second: dict[str, ci.Job], second_log: str) -> tuple[list[Item], list[Item], int]:
    """(red items, flaky items, failures with no verdict) from attempt 1's failures and the rerun's jobs, one item per feature.

    A job the runner cancelled on attempt 1 is never ticketed, and neither is one the rerun did not finish or cancelled."""
    red: dict[str, Item] = {}
    flaky: dict[str, Item] = {}
    unjudged = 0
    for f in failures:
        job = second.get(f["name"])
        if f["conclusion"] == "cancelled" or job is None or not job.done or job.conclusion == "cancelled":
            unjudged += 1
            continue
        leg, feature = split_job(f["name"])
        if job.red:
            item = red.setdefault(feature, Item("red", feature, {}, {}))
            item.second[leg] = log_tail(second_log, f["name"])
        else:
            item = flaky.setdefault(feature, Item("flaky", feature, {}, {}))
        item.first[leg] = f["log"]
    return list(red.values()), list(flaky.values()), unjudged


def _file(db: Database, gh: GitHub, config: Config, items: list[Item], run_id: int | str, sha: str) -> tuple[dict[str, int], list[Item]]:
    """File or comment each item, red before flaky. Returns ({title: issue number}, the items left unfiled)."""
    url = _run_url(config, run_id)
    numbers: dict[str, int] = {}
    left: list[Item] = []
    new = 0
    open_now = _open_pipeline_count(gh)
    for item in items:
        covering = covering_issue(gh, item)
        if covering is not None:
            gh.comment(int(covering["number"]), _comment_text(item, run_id, url))
            numbers[item.title] = int(covering["number"])
            continue
        if new >= config.gherkin_nightly_max_tickets or open_now >= config.max_open_tickets:
            left.append(item)
            continue
        if item.kind == "red":
            body, priority = red_body(item, run_id, sha, url), "p1"
        else:
            body, priority = flaky_body(item, run_id, sha, url, db.flake_history(item.feature)), "p2"
        try:
            number = file_ticket(gh, item.title, body, priority=priority, by="pipeline", force=True, max_open=config.max_open_tickets)
            gh.add_labels(number, ["pipe:filed-by-pipeline"])
        except (FilingError, GitHubError) as exc:
            db.event("gherkin-nightly-file-failed", None, title=item.title, error=str(exc)[:300])
            left.append(item)
            continue
        numbers[item.title] = number
        new += 1
        open_now += 1
    return numbers, left


def _finish(db: Database, notifier: Notifier, run_id: int | str, text: str, **data: Any) -> None:
    db.put(FOLLOW_KEY, None)
    db.event("gherkin-nightly-result", None, run_id=run_id, text=text, **data)
    notifier.alert("gherkin-nightly", int(run_id) if str(run_id).isdigit() else None, f"Gherkin nightly {run_id}: {text}")


def _summary(red: list[Item], flaky: list[Item], numbers: dict[str, int], left: list[Item], unjudged: int) -> str:
    def group(label: str, items: list[Item]) -> str:
        placed = [f"#{numbers[i.title]}" for i in items if i.title in numbers]
        return f"{len(items)} {label}" + (f" ({', '.join(placed)})" if placed else "")

    parts = [group(label, items) for label, items in (("red", red), ("flaky", flaky)) if items]
    if unjudged:
        parts.append(f"{unjudged} job(s) cancelled or unfinished, not ticketed")
    if left:
        parts.append("left unfiled: " + ", ".join(i.feature for i in left))
    return ", ".join(parts) or "green"


def follow_once(db: Database, gh: GitHub, config: Config, notifier: Notifier, clock: Callable[[], float] = time.time) -> str | None:
    """Move the followed nightly run one step. Returns what it did ("green", "rerun", "done", "abandoned", "dropped") or None when
    there is nothing to do yet. The state is in the database, so a daemon restart between the steps loses nothing."""
    raw = db.get(FOLLOW_KEY)
    if raw is None:
        return None
    state: dict[str, Any] = json.loads(raw)
    run_id = state["run_id"]
    run = _find_run(gh, config.base_branch, run_id)
    if run is None:
        if clock() - float(state["at"]) > FOLLOW_GIVE_UP_S:
            db.put(FOLLOW_KEY, None)
            db.event("gherkin-nightly-result", None, run_id=run_id, text="run not found, dropped")
            return "dropped"
        return None
    if run.get("status") != "completed":
        return None
    attempt = int(run.get("run_attempt") or 1)

    if state["phase"] == "await1":
        if attempt != 1:  # someone reran it by hand: attempt 1's failures are gone, so there is nothing to compare
            _finish(db, notifier, run_id, "was rerun by hand; not classified")
            return "abandoned"
        failed = [j for j in ci.parse_jobs([run], {int(run["id"]): gh.run_jobs(int(run["id"]))}) if j.red]
        if not failed:
            _finish(db, notifier, run_id, "green")
            return "green"
        log = _failed_log(gh, run_id)  # attempt 1 is gone from the API once the rerun starts: take what is needed now
        failures = [{"name": j.job, "conclusion": j.conclusion or "failure", "log": log_tail(log, j.job)} for j in failed]
        try:
            gh.rerun_failed(int(run_id))
        except GitHubError:
            now = _find_run(gh, config.base_branch, run_id)
            if now is not None and now.get("status") == "completed" and int(now.get("run_attempt") or 1) < 2:
                return None  # refused and still at attempt 1: try again on the next tick
        db.put(FOLLOW_KEY, json.dumps({**state, "phase": "await2", "failures": failures}))
        db.event("gherkin-nightly-rerun", None, run_id=run_id, failed=[f["name"] for f in failures])
        return "rerun"

    if attempt < 2:  # the completed attempt 1 is still what GitHub reports: the rerun has not started yet
        return None
    second = {j.job: j for j in ci.parse_jobs([run], {int(run["id"]): gh.run_jobs(int(run["id"]))})}
    failures = state["failures"]
    red, flaky, unjudged = classify(failures, second, _failed_log(gh, run_id) if any(j.red for j in second.values()) else "")
    day = time.strftime("%Y-%m-%d", time.localtime(clock()))
    for item in flaky:
        for leg in item.first:
            db.add_flake(item.feature, leg, run_id, day)
    numbers, left = _file(db, gh, config, [*red, *flaky], run_id, str(run.get("head_sha") or ""))
    _finish(db, notifier, run_id, _summary(red, flaky, numbers, left, unjudged), red=[i.feature for i in red],
            flaky=[i.feature for i in flaky], unfiled=[i.feature for i in left])
    return "done"


def summary_line(info: dict[str, Any] | None) -> str:
    """The `starpipe status` line, from the kv the last decision left."""
    if not info:
        return "gherkin nightly: no decision yet"
    when = time.strftime("%a %H:%M", time.localtime(float(info["at"])))
    parts = [f"{info['action']} ({info['reason']}) {when}"]
    parts.append(f"last green full {info['base_sha'][:10]} {info['green_at']}" if info.get("base_sha") else "no green full run")
    if info.get("run_id") is not None:
        parts.append(f"run {info['run_id']}")
    return "gherkin nightly: " + " · ".join(parts)


__all__ = ["Decision", "Item", "Source", "classify", "covering_issue", "decide", "follow_once", "git_source", "is_full", "last_green_full",
           "log_tail", "path_matches", "relevant_globs", "run_once", "split_job", "summary_line"]
