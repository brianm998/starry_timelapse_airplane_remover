"""The CI judge (plan §8.5): is this PR's CI green enough to land?

Pure: jobs and the develop baseline in, a verdict out. `pr-gate` always blocks; every other job blocks only when it is a
new failure (green on develop, red here); slow jobs stop blocking after `blocking_wait_s`; infrastructure-looking reds
get one rerun.
"""

from __future__ import annotations

import re
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

GATE = "pr-gate"
GREEN = {"success", "skipped", "neutral"}
INFRA_CONCLUSIONS = {"cancelled", "timed_out", "startup_failure"}
INFRA_LOG = re.compile(r"runner (?:has )?lost|lost communication|Could not resolve host|ECONNRESET|Connection reset|"
                       r"Temporary failure in name resolution|actions/cache|Failed to download|curl: \(\d+\)|"
                       r"The operation was canceled|No space left on device", re.IGNORECASE)


@dataclass(frozen=True)
class Job:
    workflow: str
    job: str
    status: str  # queued | in_progress | completed
    conclusion: str | None
    run_id: int
    completed_at: float | None = None
    run_done: bool = True  # GitHub refuses `rerun-failed-jobs` on a run that is still going

    @property
    def key(self) -> tuple[str, str]:
        return (self.workflow, self.job)

    @property
    def done(self) -> bool:
        return self.status == "completed"

    @property
    def red(self) -> bool:
        return self.done and (self.conclusion or "failure") not in GREEN


@dataclass
class Verdict:
    kind: str  # pending | pass | fail | rerun
    reason: str = ""
    blocking: list[Job] = field(default_factory=lambda: list[Job]())
    rerun: list[Job] = field(default_factory=lambda: list[Job]())
    known_red: list[Job] = field(default_factory=lambda: list[Job]())
    demoted: list[Job] = field(default_factory=lambda: list[Job]())


Baseline = Callable[[str, str], str | None]


def _ts(value: str | None) -> float | None:
    return datetime.fromisoformat(value).timestamp() if value else None


def parse_jobs(runs: list[dict[str, Any]], jobs_by_run: dict[int, list[dict[str, Any]]]) -> list[Job]:
    """GitHub's workflow runs and their jobs as Job values (the latest attempt of each run)."""
    out: list[Job] = []
    for run in runs:
        for j in jobs_by_run.get(int(run["id"]), []):
            out.append(Job(run.get("name") or "", j["name"], j["status"], j.get("conclusion"), int(run["id"]),
                           _ts(j.get("completed_at")), run.get("status", "completed") == "completed"))
    return out


def judge(jobs: list[Job], baseline: Baseline, *, now: float, head_pushed_at: float, settle_s: float = 90.0,
          blocking_wait_s: float = 3 * 3600, reran: set[tuple[str, str]] | None = None,
          infra: Callable[[Job], bool] = lambda j: (j.conclusion or "") in INFRA_CONCLUSIONS) -> Verdict:
    reran = reran or set()
    gate = [j for j in jobs if j.workflow == GATE]
    if now - head_pushed_at < settle_s or not gate or not all(j.done for j in gate):
        return Verdict("pending", f"waiting for {GATE} to report")
    verdict = Verdict("pass")
    for j in gate:
        if j.red:
            if infra(j) and j.key not in reran:
                verdict.rerun.append(j)
            else:
                verdict.blocking.append(j)
    pending = False
    for j in jobs:
        if j.workflow == GATE:
            continue
        if not j.done:
            if now - head_pushed_at > blocking_wait_s:
                verdict.demoted.append(j)
            else:
                pending = True
        elif j.red:
            if baseline(*j.key) != "success":
                verdict.known_red.append(j)  # already failing on develop (or never seen): does not block
            elif j.key not in reran:
                verdict.rerun.append(j)  # a new red outside the gate gets one rerun first (a flaky test is not worth a model session): it may be a flake
            elif infra(j):
                verdict.known_red.append(j)  # infrastructure twice (e.g. a runner-image brownout): not this PR's fault
            else:
                verdict.blocking.append(j)
    if verdict.blocking:
        verdict.kind, verdict.reason = "fail", "new failures: " + ", ".join(f"{j.workflow}/{j.job}" for j in verdict.blocking)
    elif verdict.rerun:
        verdict.kind, verdict.reason = "rerun", "infrastructure-looking failures: " + ", ".join(
            f"{j.workflow}/{j.job}" for j in verdict.rerun)
    elif pending:
        verdict.kind, verdict.reason = "pending", "other jobs still running"
    return verdict
