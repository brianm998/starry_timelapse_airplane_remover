"""Fakes at the pipeline's edges (plan §14.6): GitHub, the agent, the check runner, and a real temp git repo."""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

from starpipe import gitutil
from starpipe.agent import StageOutcome, StageRequest
from starpipe.checks import impact, ledger
from starpipe.config import Config
from starpipe.github import GitHub, GitHubError

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


_template: Path | None = None


def _build_repo(tmp: Path) -> Path:
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


def make_repo(tmp: Path) -> Path:
    """origin (bare) + a working clone on develop, so `origin/develop` resolves. Built once per run, copied per test."""
    global _template
    if _template is None:
        _template = Path(tempfile.mkdtemp(prefix="starpipe-template-"))
        _build_repo(_template)
    shutil.copytree(_template / "origin.git", tmp / "origin.git", symlinks=True)
    shutil.copytree(_template / "repo", tmp / "repo", symlinks=True)
    sh(tmp / "repo", "git", "remote", "set-url", "origin", str(tmp / "origin.git"))
    return tmp / "repo"


Ci = list[tuple[str, str, str, str | None]]  # (workflow, job, status, conclusion)
DEFAULT_CI: Ci = [("pr-gate", "linux", "completed", "success")]


class FakeGitHub(GitHub):
    def __init__(self, config: Config | None = None, origin: Path | None = None) -> None:
        super().__init__(config or Config())
        self.origin = origin
        self.prs: dict[int, dict[str, Any]] = {}
        self.ci: dict[str, Ci] = {}
        self.develop_ci: Ci = []
        self.develop_history: list[Ci] = []  # older develop runs, newest first, after develop_ci
        self.logs: dict[int, str] = {}
        self.reruns: list[int] = []
        self.deleted: list[str] = []
        self.phantom = False
        self.run_ids: dict[tuple[str, str], int] = {}
        self.run_jobs_by_id: dict[int, list[dict[str, Any]]] = {}
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
            wanted = {x.split("=", 1)[1] for x in path.split("&") if x.startswith("labels=")}
            return [i for i in self.issues.values() if i["state"] == "open"
                    and all(w in {lab["name"] for lab in i["labels"]} for w in wanted)]
        return []

    def issue(self, number: int) -> dict[str, Any]:
        if number not in self.issues:
            raise GitHubError(f"gh api issues/{number} failed: HTTP 404: Not Found")
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
        self.timelines[number] += [{"event": "labeled", "label": {"name": n}, "actor": {"login": OWNER}} for n in labels]

    def close_issue(self, number: int, reason: str = "not_planned") -> None:
        self.issues[number]["state"] = "closed"

    def set_body(self, number: int, body: str) -> None:
        self.issues[number]["body"] = body

    # pull requests and CI ---------------------------------------------------------------------------------------------
    def _head(self, branch: str) -> str:
        assert self.origin
        return sh(self.origin, "git", "rev-parse", f"refs/heads/{branch}").strip()

    def create_pr(self, title: str, body: str, head: str, base: str) -> dict[str, Any]:
        n = 100 + len(self.prs) + 1
        self.prs[n] = {"number": n, "title": title, "body": body, "branch": head, "merged": False, "mergeable": True,
                       "merge_commit_sha": None}
        return self.prs[n]

    def update_pr(self, number: int, body: str) -> None:
        self.prs[number]["body"] = body

    def pr(self, number: int) -> dict[str, Any]:
        pr = self.prs[number]
        return {**pr, "head": {"sha": self._head(pr["branch"])}}

    def find_pr(self, branch: str) -> dict[str, Any] | None:
        return next((p for p in self.prs.values() if p["branch"] == branch), None)

    def workflow_runs(self, sha: str | None = None, branch: str | None = None, per_page: int = 50) -> list[dict[str, Any]]:
        if branch:
            generations = [("develop", self.develop_ci), *((f"develop~{n}", ci) for n, ci in enumerate(self.develop_history, 1))]
        else:
            generations = [(sha or "", self.ci.get(sha or "", DEFAULT_CI))]
        runs: list[dict[str, Any]] = []
        for key, jobs in generations:  # newest first, like the API
            for wf in dict.fromkeys(w for w, *_ in jobs):
                run_id = self.run_ids.setdefault((key, wf), 1000 + len(self.run_ids))
                mine = [(j, st, c) for w, j, st, c in jobs if w == wf]
                self.run_jobs_by_id[run_id] = [{"name": j, "status": st, "conclusion": c, "completed_at": None}
                                               for j, st, c in mine]
                conclusions = {c for _, _, c in mine}
                # a run's own conclusion: cancelled when the runner cancelled all of it, as a newer push does
                conclusion = ("cancelled" if conclusions == {"cancelled"} else "success" if conclusions == {"success"}
                              else "failure")
                runs.append({"id": run_id, "name": wf, "status": "completed", "conclusion": conclusion, "head_sha": key})
        return runs

    def run_jobs(self, run_id: int) -> list[dict[str, Any]]:
        return self.run_jobs_by_id.get(run_id, [])

    def rerun_failed(self, run_id: int) -> None:
        self.reruns.append(run_id)

    def failed_log(self, run_id: int, limit: int = 12000) -> str:
        return self.logs.get(run_id, "Run swift test\nerror: boom")

    def merge_pr(self, number: int, sha: str) -> None:
        pr = self.pr(number)
        if pr["head"]["sha"] != sha:
            raise GitHubError("head changed")
        assert self.origin
        if self.phantom:
            pr["merged"] = self.prs[number]["merged"] = True
            self.prs[number]["merge_commit_sha"] = "0" * 40
            return
        clone = self.origin.parent / f"merge-{number}"
        sh(self.origin.parent, "git", "clone", "-q", str(self.origin), str(clone))
        sh(clone, "git", "config", "user.email", "t@t")
        sh(clone, "git", "config", "user.name", "t")
        sh(clone, "git", "checkout", "-q", "develop")
        sh(clone, "git", "merge", "-q", "--no-ff", "-m", f"Merge PR {number}", sha)
        sh(clone, "git", "push", "-q", "origin", "develop")
        self.prs[number]["merged"] = True
        self.prs[number]["merge_commit_sha"] = sh(clone, "git", "rev-parse", "HEAD").strip()

    def delete_branch(self, branch: str) -> None:
        self.deleted.append(branch)

    def remove_label(self, number: int, label: str) -> None:
        self.issues[number]["labels"] = [lab for lab in self.issues[number]["labels"] if lab["name"] != label]

    def ensure_label(self, name: str) -> None:
        pass

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
