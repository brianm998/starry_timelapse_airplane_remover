#!/usr/bin/env python3
"""Decide whether tonight's full Gherkin run is worth dispatching (a port of starpipe's gherkin_nightly.decide()).

Rules, in order:
* a full run already queued or running: skip;
* the newest finished full run (success or failure, not cancelled) tested exactly the tip: skip;
* --force: dispatch;
* no green full run ever: dispatch;
* otherwise dispatch only if a file changed since the last green full run's sha matches the
  `on.pull_request.paths` globs of gherkin-smoke.yml (an unreachable sha means dispatch).

A "full" run is one named `Gherkin: full`, or a push run. Prints `dispatch` or `skip` on the first line and the reason on the
second; the workflow step acts on the first line. Self-contained: no pipeline/ import, no PyYAML."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections.abc import Callable
from typing import Any

WORKFLOW_FILE = "gherkin.yml"
PATHS_PATH = ".github/workflows/gherkin-smoke.yml"
FULL_TITLE = "Gherkin: full"
IN_FLIGHT = ("queued", "in_progress", "waiting", "pending", "requested")
FINISHED = ("success", "failure")


def relevant_globs(yml_text: str) -> list[str]:
    """`on.pull_request.paths` of a workflow file (block-list form). An empty or missing list raises."""
    path: list[tuple[int, str]] = []
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
        path.append((indent, text.split(":", 1)[0].strip()))
    if not found:
        raise ValueError(f"no on.pull_request.paths list in {PATHS_PATH}")
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


def is_full(run: dict[str, Any]) -> bool:
    return run.get("event") == "push" or run.get("display_title") == FULL_TITLE


def _newest(runs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(runs, key=lambda r: int(r["id"]), reverse=True)


def last_green_full(runs: list[dict[str, Any]]) -> dict[str, Any] | None:
    return next((r for r in _newest(runs) if is_full(r) and r.get("status") == "completed" and r.get("conclusion") == "success"), None)


def decide(runs: list[dict[str, Any]], tip: str, globs: list[str], changed: Callable[[str], list[str] | None],
           force: bool = False) -> tuple[str, str]:
    """(action, reason). `changed(sha)`: files that differ from `sha` to the tip, None when the sha is not in the repo."""
    full = [r for r in _newest(runs) if is_full(r)]
    flying = next((r for r in full if r.get("status") in IN_FLIGHT), None)
    if flying is not None:
        return "skip", f"a full run is already in flight (run {flying['id']})"
    last = next((r for r in full if r.get("status") == "completed" and r.get("conclusion") in FINISHED), None)
    if last is not None and last["head_sha"] == tip:
        return "skip", f"the tip {tip[:10]} was already tested (run {last['id']}: {last['conclusion']})"
    if force:
        return "dispatch", "forced"
    green = last_green_full(runs)
    if green is None:
        return "dispatch", "no green full run yet"
    base = green["head_sha"]
    files = changed(base)
    if files is None:
        return "dispatch", f"the last green full run's sha {base[:10]} is not in the repo; cannot tell what changed"
    hits = [f for f in files if path_matches(f, globs)]
    if not hits:
        return "skip", f"nothing relevant changed since the last green full run {base[:10]} ({len(files)} files, none match)"
    return "dispatch", f"{len(hits)} relevant file(s) changed since the last green full run {base[:10]}, e.g. {hits[0]}"


def git_changed(sha: str) -> list[str] | None:
    have = subprocess.run(["git", "cat-file", "-e", f"{sha}^{{commit}}"], capture_output=True, check=False)
    if have.returncode != 0:
        return None
    out = subprocess.run(["git", "diff", "--name-only", sha, "HEAD"], capture_output=True, text=True, check=True)
    return out.stdout.splitlines()


def fetch_runs(repo: str) -> list[dict[str, Any]]:
    out = subprocess.run(["gh", "api", f"repos/{repo}/actions/workflows/{WORKFLOW_FILE}/runs?branch=develop&per_page=50"],
                         capture_output=True, text=True, check=True)
    return json.loads(out.stdout)["workflow_runs"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="owner/name")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    tip = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    with open(PATHS_PATH, encoding="utf-8") as fh:
        globs = relevant_globs(fh.read())
    action, reason = decide(fetch_runs(args.repo), tip, globs, git_changed, args.force)
    print(action)
    print(reason)
    return 0


if __name__ == "__main__":
    sys.exit(main())
