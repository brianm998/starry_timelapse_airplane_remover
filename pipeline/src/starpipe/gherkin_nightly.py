"""The nightly dispatch of the full Gherkin matrix on GitHub (not T4, the local nightly in nightly.py).

The "Gherkin" workflow takes 3-4 hours, so a push to the base branch no longer starts it. Once a day, at `gherkin_nightly_start`,
the daemon decides whether a full run is worth it, and dispatches one when it is:

* a full run already queued or running: skip;
* the newest finished full run (green or red, not cancelled) tested exactly the current tip: skip, there is nothing new to learn;
* no green full run ever: dispatch;
* otherwise diff the last green full run's sha against the tip and dispatch only if a file matches the workflow's own
  `on.pull_request.paths` globs (read from gherkin.yml at the tip, so the list lives in one place).

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

from . import gitutil
from .config import Config
from .db import Database
from .github import GitHub, GitHubError

WORKFLOW_FILE = "gherkin.yml"
WORKFLOW_PATH = f".github/workflows/{WORKFLOW_FILE}"
FULL_TITLE = "Gherkin: full"
IN_FLIGHT = ("queued", "in_progress", "waiting", "pending", "requested")
FINISHED = ("success", "failure")  # a cancelled run tested nothing
RETRY_AFTER_ERROR_S = 600.0


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
    except (GitHubError, RuntimeError, ValueError, OSError) as exc:
        decision = Decision("error", str(exc)[:300])
    db.event("gherkin-nightly", None, action=decision.action, reason=decision.reason, base_sha=decision.base_sha,
             run_id=decision.run_id, tip=decision.tip, forced=force)
    db.put("gherkin_nightly_last", json.dumps({"at": clock(), "action": decision.action, "reason": decision.reason,
                                               "base_sha": decision.base_sha, "run_id": decision.run_id,
                                               "green_at": decision.green_at, "tip": decision.tip, "forced": force}))
    return decision


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


__all__ = ["Decision", "Source", "decide", "git_source", "is_full", "last_green_full", "path_matches", "relevant_globs", "run_once",
           "summary_line"]
