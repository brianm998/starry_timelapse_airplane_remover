"""Failures develop already has: a test check that is red at HEAD is also run at the branch's merge-base, and when every failing
test also fails there, the change did not cause it (#231). The ledger is keyed by sha, so the base's run is shared by every ticket
cut from that base."""

from __future__ import annotations

import json
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any

from .. import gitutil, worktrees
from ..config import home
from . import ledger, runner

if TYPE_CHECKING:
    from ..db import Database
    from ..notify import Notifier

BaselineRunner = Callable[[Path, str, str], ledger.Result | None]  # (worktree, base ref, check id) -> the check at the merge-base
PRUNE_AFTER_S = 24 * 3600.0


@dataclass
class KnownRed:
    check: str
    base: str  # the merge-base sha the same check also fails at
    tests: list[str]  # the failing tests the change is excused for

    def line(self) -> str:
        return f"{self.check} at merge-base {self.base[:10]}: {', '.join(self.tests)}"


def shares(head: ledger.Result, base: ledger.Result | None) -> bool:
    """Every failure at HEAD is one the base has. Hung, vacuous, partial and build failures are never excused: only a plain
    test failure, with its failing tests named."""
    if base is None or head.status != "fail" or base.status != "fail" or not head.check.startswith("test:"):
        return False
    if head.failed < 1 or not head.failures or not set(head.failures) <= set(base.failures):
        return False
    return len(head.failures) >= head.failed or base.failed == head.failed  # unnamed failures must at least match in number


def _main_checkout(worktree: Path) -> Path:
    common = Path(gitutil.git(worktree, "rev-parse", "--path-format=absolute", "--git-common-dir").strip())
    return common.parent


def _prune(keep: Path) -> None:
    for old in keep.parent.glob("baseline-*"):
        if old != keep and time.time() - old.stat().st_mtime > PRUNE_AFTER_S:
            gitutil.git(_main_checkout(keep), "worktree", "remove", "--force", str(old), check=False)


def _baseline_tree(worktree: Path, sha: str) -> Path:
    """A detached worktree at `sha`, outside every ticket's worktree and reused while it exists."""
    path = home() / "baselines" / f"baseline-{sha[:12]}"
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        gitutil.git(worktree, "worktree", "add", "--detach", str(path), sha)
        _prune(path)
    path.touch()
    worktrees.link_artifacts(_main_checkout(worktree), path)
    return path


def result_at_base(worktree: Path, base_ref: str, check: str) -> ledger.Result | None:
    """`check` at the merge-base: the ledger's result for that sha when there is one, else a run in the baseline worktree."""
    try:
        sha = gitutil.merge_base(worktree, base_ref)
        if (known := ledger.latest(sha, check)) is not None:
            return known
        tree = _baseline_tree(worktree, sha)
        log_dir = home() / "checks" / sha[:12]
        log_dir.mkdir(parents=True, exist_ok=True)
        return runner.run_check(check, tree, base_ref, log_dir)
    except (RuntimeError, OSError, KeyError):
        return None  # no baseline: the failure stays the change's


def known_red(worktree: Path, base_ref: str, result: ledger.Result, runner_: BaselineRunner = result_at_base,
              notifier: Notifier | None = None) -> KnownRed | None:
    """Excuse a red test check whose failures develop shares, and alert the owner once per (check, base sha)."""
    if result.green or result.status != "fail" or not result.failures or not result.check.startswith("test:"):
        return None
    base = runner_(worktree, base_ref, result.check)
    if base is None or not shares(result, base):
        return None
    found = KnownRed(result.check, base.sha, list(result.failures))
    if notifier:
        notifier.alert(f"known-red:{result.check}:{base.sha[:12]}", None,
                       f"{result.check} fails on develop itself (merge-base {base.sha[:10]}), so tickets cut from it are let "
                       f"through with it red: {', '.join(base.failures)}. Fix it or skip it on develop.")
    return found


def note(db: Database, ticket: int, sha: str, found: KnownRed) -> None:
    """Remember the excuse for the PR body; it only holds for the sha it was found at."""
    row: dict[str, Any] = json.loads(db.get(f"known_red:{ticket}") or "{}")
    if row.get("sha") != sha:
        row = {"sha": sha, "checks": {}}
    row["checks"][found.check] = {"base": found.base, "tests": found.tests}
    db.put(f"known_red:{ticket}", json.dumps(row))


def section(db: Database, ticket: int, sha: str) -> str:
    row: dict[str, Any] = json.loads(db.get(f"known_red:{ticket}") or "{}")
    if row.get("sha") != sha or not row.get("checks"):
        return ""
    lines = [f"- {check} at merge-base {v['base'][:10]}: {', '.join(v['tests'])}" for check, v in row["checks"].items()]
    return ("## Known red on develop\nThese tests fail at the merge-base too, so this change is not held up by them:\n"
            + "\n".join(lines) + "\n")
