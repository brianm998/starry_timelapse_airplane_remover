"""Fakes at the pipeline's edges (plan §14.6): GitHub, the agent, the check runner, and a real temp git repo."""

from __future__ import annotations

import subprocess
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

from starpipe import gitutil
from starpipe.agent import StageOutcome, StageRequest
from starpipe.checks import impact, ledger
from starpipe.config import Config
from starpipe.github import GitHub

OWNER = "brianm998"
GOOD_BODY = """## Goal
Do it.

## Context
c

## Acceptance criteria
- A1: works — check: FooTests

## Tests
none: docs only

## Out of scope
x
"""


def sh(cwd: Path, *args: str) -> str:
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True, check=True).stdout


def make_repo(tmp: Path) -> Path:
    """origin (bare) + a working clone on develop, so `origin/develop` resolves."""
    origin, repo = tmp / "origin.git", tmp / "repo"
    sh(tmp, "git", "init", "-q", "--bare", "-b", "develop", str(origin))
    sh(tmp, "git", "clone", "-q", str(origin), str(repo))
    sh(repo, "git", "config", "user.email", "t@t")
    sh(repo, "git", "config", "user.name", "t")
    (repo / "docs").mkdir()
    (repo / "docs" / "a.md").write_text("one\n")
    (repo / ".gitignore").write_text(".claude/worktrees/\n")
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-q", "-m", "init")
    sh(repo, "git", "push", "-q", "origin", "HEAD:develop")
    sh(repo, "git", "fetch", "-q")
    return repo


class FakeGitHub(GitHub):
    def __init__(self, config: Config | None = None) -> None:
        super().__init__(config or Config())
        self.issues: dict[int, dict[str, Any]] = {}
        self.timelines: dict[int, list[dict[str, Any]]] = {}
        self.comment_list: dict[int, list[dict[str, Any]]] = {}
        self.deps: dict[int, list[int]] = {}
        self.next_id = 1000

    def add_issue(self, number: int, title: str, body: str = GOOD_BODY, author: str = OWNER,
                  labels: tuple[str, ...] = ("pipeline",)) -> None:
        self.issues[number] = {"number": number, "title": title, "body": body, "state": "open",
                               "user": {"login": author}, "labels": [{"name": n} for n in labels]}
        self.timelines[number] = [{"event": "labeled", "label": {"name": "pipeline"}, "actor": {"login": OWNER}}]
        self.comment_list[number] = []

    def say(self, number: int, user: str, body: str) -> int:
        self.next_id += 1
        self.comment_list[number].append({"id": self.next_id, "user": {"login": user}, "body": body})
        return self.next_id

    def paged(self, path: str) -> list[dict[str, Any]]:
        if path.startswith("issues?state=open"):
            return [i for i in self.issues.values() if i["state"] == "open"]
        return []

    def issue(self, number: int) -> dict[str, Any]:
        return self.issues[number]

    def timeline(self, number: int) -> list[dict[str, Any]]:
        return self.timelines[number]

    def comments(self, number: int) -> list[dict[str, Any]]:
        return self.comment_list[number]

    def blocked_by(self, number: int) -> list[int]:
        return self.deps.get(number, [])

    def comment(self, number: int, body: str) -> int:
        return self.say(number, OWNER, body)  # the pipeline posts with the owner's token

    def set_state_label(self, number: int, state: str) -> None:
        labels = [lab for lab in self.issues[number]["labels"] if not lab["name"].startswith("pipe:")]
        self.issues[number]["labels"] = [*labels, {"name": f"pipe:{state}"}]

    def create_issue(self, title: str, body: str) -> int:
        n = max(self.issues, default=0) + 1
        self.add_issue(n, title, body, labels=())
        return n

    def add_labels(self, number: int, labels: list[str]) -> None:
        self.issues[number]["labels"] += [{"name": n} for n in labels]

    def close_issue(self, number: int, reason: str = "not_planned") -> None:
        self.issues[number]["state"] = "closed"

    def state_label(self, number: int) -> str | None:
        names = [lab["name"] for lab in self.issues[number]["labels"] if lab["name"].startswith("pipe:")]
        return names[-1] if names else None


Script = Callable[[StageRequest], Awaitable[StageOutcome] | StageOutcome]


class FakeAgent:
    """A scripted agent: per stage, a queue of behaviours. Each gets the request and may drive the contract."""

    def __init__(self) -> None:
        self.scripts: dict[str, list[Script]] = {}
        self.requests: list[StageRequest] = []

    def on(self, stage: str, *behaviours: Script) -> None:
        self.scripts.setdefault(stage, []).extend(behaviours)

    async def run(self, req: StageRequest) -> StageOutcome:
        self.requests.append(req)
        queue = self.scripts.get(req.stage, [])
        if not queue:
            return StageOutcome("no-result")
        out = queue.pop(0)(req)
        if isinstance(out, StageOutcome):
            return out
        return await out


def accepted(req: StageRequest, session: str = "S") -> StageOutcome:
    return StageOutcome("accepted" if req.contract.result else "no-result", session_id=session)


def plan_args(**over: Any) -> dict[str, Any]:
    base: dict[str, Any] = {"summary": "Add a line to the docs file.", "approach": ["edit docs/a.md"],
                            "tests": {"none_reason": "docs only"},
                            "acceptance": [{"id": "A1", "check": "review: docs/a.md"}]}
    return {**base, **over}


def commit_change(req: StageRequest, text: str = "two\n") -> None:
    wt = req.contract.worktree
    (wt / "docs" / "a.md").write_text(text)
    sh(wt, "git", "add", "-A")
    sh(wt, "git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "change")


def green_runner(worktree: Path, base: str) -> list[ledger.Result]:
    sha = gitutil.head_sha(worktree)
    plan = impact.plan_for(gitutil.changed_paths(worktree, base))
    out = [ledger.Result(c, "pass", sha, 0.0, executed=1) for c in [*plan.t0, *plan.t1()]]
    for r in out:
        ledger.record(r)
    return out
