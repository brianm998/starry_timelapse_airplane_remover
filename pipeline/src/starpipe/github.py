"""A thin GitHub client over `gh api`. The runner is injectable so tests never touch the network."""

from __future__ import annotations

import json
import subprocess
from collections.abc import Callable, Sequence
from typing import Any

from .config import Config

Runner = Callable[[Sequence[str], str | None], str]

STATE_LABELS = ["pipe:queued", "pipe:exploring", "pipe:developing", "pipe:verifying", "pipe:review", "pipe:ci",
                "pipe:landing", "pipe:needs-input", "pipe:failed", "pipe:paused"]
OTHER_LABELS = ["pipeline", "pipe:landed", "pipe:filed-by-pipeline", "pipe:proposed", "p0", "p1", "p2", "p3"]
LABEL_COLOURS = {"pipeline": "0e8a16", "pipe:landed": "6f42c1", "pipe:failed": "d73a4a", "pipe:needs-input": "fbca04",
                 "pipe:paused": "bfbfbf", "pipe:filed-by-pipeline": "c5def5", "pipe:proposed": "d4c5f9"}


class GitHubError(RuntimeError):
    pass


GH_TIMEOUT_S = 120.0


def gh_runner(args: Sequence[str], stdin: str | None) -> str:
    try:
        done = subprocess.run(["gh", *args], input=stdin, capture_output=True, text=True, check=False, timeout=GH_TIMEOUT_S)
    except subprocess.TimeoutExpired as exc:  # a hung call must not hang the daemon with it
        raise GitHubError(f"gh {' '.join(args)} timed out after {GH_TIMEOUT_S:.0f}s") from exc
    if done.returncode != 0:
        raise GitHubError(f"gh {' '.join(args)} failed: {(done.stderr or done.stdout).strip()}")
    return done.stdout


class GitHub:
    def __init__(self, config: Config, runner: Runner = gh_runner) -> None:
        self.config = config
        self._run = runner
        self.base = f"repos/{config.owner}/{config.repo}"
        self._jobs_cache: dict[tuple[int, str], list[dict[str, Any]]] = {}

    def api(self, method: str, path: str, body: dict[str, Any] | None = None) -> Any:
        args = ["api", "-X", method, f"{self.base}/{path}"]
        stdin = None
        if body is not None:
            args += ["--input", "-"]
            stdin = json.dumps(body)
        out = self._run(args, stdin)
        return json.loads(out) if out.strip() else None

    def paged(self, path: str) -> list[dict[str, Any]]:
        """Every page of a list endpoint (gh's --paginate with --slurp wraps pages in an outer array)."""
        out = self._run(["api", "--paginate", "--slurp", f"{self.base}/{path}"], None)
        pages: list[list[dict[str, Any]]] = json.loads(out) if out.strip() else []
        return [item for page in pages for item in page]

    def issue(self, number: int) -> dict[str, Any]:
        return self.api("GET", f"issues/{number}")

    def comments(self, number: int) -> list[dict[str, Any]]:
        return self.paged(f"issues/{number}/comments?per_page=100")

    def timeline(self, number: int) -> list[dict[str, Any]]:
        return self.paged(f"issues/{number}/timeline?per_page=100")

    def create_issue(self, title: str, body: str) -> int:
        return int(self.api("POST", "issues", {"title": title, "body": body})["number"])

    def add_labels(self, number: int, labels: list[str]) -> None:
        self.api("POST", f"issues/{number}/labels", {"labels": labels})

    def block(self, number: int, blocked_by: int) -> None:
        """Record that `number` is blocked by `blocked_by` (needs the blocker's database id)."""
        blocker = self.issue(blocked_by)
        self.api("POST", f"issues/{number}/dependencies/blocked_by", {"issue_id": blocker["id"]})

    def close_issue(self, number: int, reason: str = "not_planned") -> None:
        self.api("PATCH", f"issues/{number}", {"state": "closed", "state_reason": reason})

    def comment(self, number: int, body: str) -> int:
        return int(self.api("POST", f"issues/{number}/comments", {"body": body})["id"])

    def remove_label(self, number: int, label: str) -> None:
        try:
            self.api("DELETE", f"issues/{number}/labels/{label.replace(':', '%3A')}")
        except GitHubError:
            pass  # already gone

    def set_state_label(self, number: int, state: str) -> None:
        """Make `pipe:<state>` the only state label on the issue."""
        issue = self.issue(number)
        have = {lab["name"] for lab in issue.get("labels", [])}
        wanted = f"pipe:{state}"
        for label in have & set(STATE_LABELS) - {wanted}:
            self.remove_label(number, label)
        if wanted in STATE_LABELS and wanted not in have:
            self.add_labels(number, [wanted])

    def blocked_by(self, number: int) -> list[int]:
        return [int(b["number"]) for b in self.paged(f"issues/{number}/dependencies/blocked_by?per_page=100")]

    # pull requests and CI ---------------------------------------------------------------------------------------------
    def create_pr(self, title: str, body: str, head: str, base: str) -> dict[str, Any]:
        return self.api("POST", "pulls", {"title": title, "body": body, "head": head, "base": base})

    def close_pr(self, number: int, comment: str = "") -> None:
        if comment:
            self.comment(number, comment)  # a PR's conversation is its issue's comments
        self.api("PATCH", f"pulls/{number}", {"state": "closed"})

    def cancel_runs(self, branch: str) -> int:
        """Cancel the queued and running workflow runs of a branch: closing its PR does not, and a queued run for a closed PR still takes
        its turn for GitHub's runners. Returns how many cancellations were requested."""
        data: dict[str, Any] = self.api("GET", f"actions/runs?branch={branch}&per_page=30") or {}
        cancelled = 0
        for run in data.get("workflow_runs", []):
            if run.get("status") in ("queued", "in_progress", "waiting", "pending"):
                try:
                    self.api("POST", f"actions/runs/{run['id']}/cancel")
                    cancelled += 1
                except GitHubError:
                    pass  # it finished between the list and the cancel
        return cancelled

    def update_pr(self, number: int, body: str) -> None:
        self.api("PATCH", f"pulls/{number}", {"body": body})

    def pr(self, number: int) -> dict[str, Any]:
        return self.api("GET", f"pulls/{number}")

    def find_pr(self, branch: str) -> dict[str, Any] | None:
        found = self.paged(f"pulls?head={self.config.owner}:{branch}&state=all&per_page=10")
        return found[0] if found else None

    def workflow_runs(self, sha: str | None = None, branch: str | None = None, per_page: int = 50) -> list[dict[str, Any]]:
        query = f"per_page={per_page}" + (f"&head_sha={sha}" if sha else "") + (f"&branch={branch}" if branch else "")
        data: dict[str, Any] = self.api("GET", f"actions/runs?{query}") or {}
        return data.get("workflow_runs", [])

    def run_jobs(self, run_id: int, version: str | None = None) -> list[dict[str, Any]]:
        """A run's jobs. With a `version` (only for a completed run: its attempt and update time) the answer is remembered, since a
        completed run does not change until it is rerun, which changes the version. This is most of the polling cost."""
        if version is not None and (run_id, version) in self._jobs_cache:
            return self._jobs_cache[(run_id, version)]
        data: dict[str, Any] = self.api("GET", f"actions/runs/{run_id}/jobs?per_page=100") or {}
        jobs: list[dict[str, Any]] = data.get("jobs", [])
        if version is not None:
            if len(self._jobs_cache) > 2000:
                self._jobs_cache.clear()
            self._jobs_cache[(run_id, version)] = jobs
        return jobs

    def rerun_failed(self, run_id: int) -> None:
        self.api("POST", f"actions/runs/{run_id}/rerun-failed-jobs")

    def failed_log(self, run_id: int, limit: int = 12000) -> str:
        out = self._run(["run", "view", str(run_id), "-R", f"{self.config.owner}/{self.config.repo}", "--log-failed"], None)
        return out[-limit:]

    def merge_pr(self, number: int, sha: str) -> None:
        """A merge commit, refused by GitHub unless the PR head is still `sha` (the plan's --match-head-commit)."""
        self.api("PUT", f"pulls/{number}/merge", {"merge_method": "merge", "sha": sha})

    def delete_branch(self, branch: str) -> None:
        try:
            self.api("DELETE", f"git/refs/heads/{branch}")
        except GitHubError:
            pass  # already deleted

    def ensure_label(self, name: str) -> None:
        """Create one label if it is missing (an existing one answers 422, which is fine)."""
        try:
            self.api("POST", "labels", {"name": name, "color": LABEL_COLOURS.get(name, "ededed")})
        except GitHubError:
            pass  # already there; a real failure surfaces on the add_labels that follows

    def ensure_labels(self) -> tuple[list[str], list[str]]:
        """Create the missing labels; return (created, already_there)."""
        have = {item["name"] for item in self.paged("labels?per_page=100")}
        created: list[str] = []
        for name in [*OTHER_LABELS, *STATE_LABELS]:
            if name in have:
                continue
            self.api("POST", "labels", {"name": name, "color": LABEL_COLOURS.get(name, "ededed")})
            created.append(name)
        return created, sorted(have & {*OTHER_LABELS, *STATE_LABELS})
