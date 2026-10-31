"""T4, the nightly (plan §8.1, §16 Phase 6): every local suite and the Gherkin features on origin/develop's tip, at the lowest
heavy-lock priority, compared with the last time each check ran. A check that was green and is now red files a `p1` ticket.

Every outside effect is injected, so the tests run it in milliseconds; the real thing takes hours.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

from . import adapter_star as star
from . import gitutil, worktrees
from .checks import ledger, runner
from .config import Config, home
from .db import Database
from .github import GitHub, GitHubError
from .notify import Notifier

NIGHTLY_PRIORITY = 2
WORKTREE_NAME = "pipe-nightly"


@dataclass
class Options:
    ref: str | None = None  # default origin/<base>; a scratch branch plants a red for the done-when test
    suites: list[str] = field(default_factory=lambda: list[str]())  # ids or id prefixes; empty means everything
    ui: bool = False  # the mac gui @ui features: they need UI automation and the display
    file_tickets: bool = True


@dataclass
class Plan:
    local: list[str]
    gherkin_cli: list[star.CheckSpec]
    gherkin_ui: star.CheckSpec | None

    @property
    def needs_setup(self) -> bool:
        return bool(self.gherkin_cli)


def wanted(check_id: str, suites: list[str]) -> bool:
    return not suites or any(check_id == s or check_id.startswith(s) for s in suites)


def due(now: datetime, last_day: str | None, start: str) -> bool:
    """Is it time for tonight's nightly? `start` is "HH:MM" local time; at most one a day."""
    hour, minute = (int(x) for x in start.split(":"))
    return last_day != now.strftime("%Y-%m-%d") and (now.hour, now.minute) >= (hour, minute)


def test_data_dir(config: Config) -> str:
    return config.test_data or os.environ.get("STAR_TEST_DATA") or str(Path.home() / ".star-test-data")


def build_plan(root: Path, opts: Options, test_data: str) -> Plan:
    env = tuple((k, v.replace("{test_data}", test_data)) for k, v in star.NIGHTLY_ENV)
    cli = [c for c in star.nightly_gherkin_cli(root, env) if wanted(c.id, opts.suites)]
    ui = star.nightly_gherkin_ui(root, env) if opts.ui else None
    if ui is not None and not wanted(ui.id, opts.suites):
        ui = None
    return Plan([c for c in star.nightly_local_checks() if wanted(c, opts.suites)], cli, ui)


def datasets_for(root: Path) -> list[str]:
    path = root / "gherkin" / "generated" / "datasets-cli.txt"
    return path.read_text().split() if path.exists() else []


# the effects, replaceable in tests -----------------------------------------------------------------------------------
Exec = Callable[[str, "star.CheckSpec | None", Path], ledger.Result]
Fetch = Callable[[Path, list[str], str], tuple[bool, str]]


def make_worktree(repo: Path, sha: str) -> Path:
    wt = worktrees.worktree_path(repo, 0).with_name(WORKTREE_NAME)
    if wt.exists():
        gitutil.git(repo, "worktree", "remove", "--force", str(wt), check=False)
        shutil.rmtree(wt, ignore_errors=True)
    wt.parent.mkdir(parents=True, exist_ok=True)
    gitutil.git(repo, "worktree", "add", "--detach", str(wt), sha)
    worktrees.link_artifacts(repo, wt)
    return wt


def real_exec(check_id: str, spec: star.CheckSpec | None, root: Path) -> ledger.Result:
    log_dir = home() / "nightly" / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    base = gitutil.resolve_base(root, None)
    if spec is not None:
        return runner.run_spec(spec, root, base, log_dir, priority=NIGHTLY_PRIORITY)
    return runner.run_spec(star.CHECKS[check_id], root, base, log_dir, priority=NIGHTLY_PRIORITY)


def real_fetch(root: Path, names: list[str], test_data: str) -> tuple[bool, str]:
    if not names:
        return True, ""
    done = subprocess.run([str(root / "test_data" / "fetch.sh"), *names], cwd=root, capture_output=True, text=True, check=False,
                          env={**os.environ, "STAR_TEST_DATA": test_data})
    return done.returncode == 0, (done.stdout + done.stderr)[-600:]


@dataclass
class Nightly:
    db: Database
    config: Config
    gh: GitHub
    notifier: Notifier
    repo: Path
    exec: Exec = real_exec
    fetch: Fetch = real_fetch
    fetch_ref: Callable[[Path], None] | None = None
    clock: Callable[[], float] = time.time

    def run(self, opts: Options | None = None) -> int:
        """One nightly, start to finish. Returns the run id."""
        opts = opts or Options()
        if self.fetch_ref:
            self.fetch_ref(self.repo)
        ref = opts.ref or f"origin/{self.config.base_branch}"
        sha = gitutil.git(self.repo, "rev-parse", ref).strip()
        run = self.db.nightly_begin(ref, sha)
        status, summary = "done", {}
        try:
            wt = make_worktree(self.repo, sha)
            plan = build_plan(wt, opts, test_data_dir(self.config))
            summary = self._execute(run, wt, plan, test_data_dir(self.config))
            summary["new_reds"], summary["filed"] = self._compare(run, sha, opts)
        except (RuntimeError, OSError, subprocess.SubprocessError) as exc:  # a broken nightly must say so, not vanish
            status, summary = "error", {"error": str(exc)[:500]}
            self.notifier.alert("nightly-error", None, f"the nightly could not run: {exc}")
        finally:
            self.db.nightly_end(run, status, summary)
            self._remove_worktree()
        reds = summary.get("reds", [])
        if reds:
            self.notifier.alert("nightly-red", None, f"nightly {sha[:8]}: {len(reds)} red: {', '.join(reds[:5])}")
        return run

    def _remove_worktree(self) -> None:
        wt = worktrees.worktree_path(self.repo, 0).with_name(WORKTREE_NAME)
        for rel in star.ARTIFACT_LINKS:
            if (wt / rel).is_symlink():
                (wt / rel).unlink()
        gitutil.git(self.repo, "worktree", "remove", "--force", str(wt), check=False)

    def _record(self, run: int, r: ledger.Result) -> None:
        self.db.nightly_result(run, r.check, r.status, r.executed, r.failed, r.skipped, r.seconds, r.lock_wait, r.log)

    def _execute(self, run: int, wt: Path, plan: Plan, test_data: str) -> dict[str, Any]:
        started = self.clock()
        reds: list[str] = []

        def go(check_id: str, spec: star.CheckSpec | None = None) -> bool:
            result = self.exec(check_id, spec, wt)
            self._record(run, result)
            if not result.green:
                reds.append(check_id)
            return result.green

        for check_id in plan.local:
            go(check_id)
        gherkin = [*plan.gherkin_cli, *([plan.gherkin_ui] if plan.gherkin_ui else [])]
        if gherkin:
            ok, detail = self._setup(run, wt, plan, test_data)
            for spec in gherkin:
                if ok or spec.id == "gherkin:gui-ui":  # the @ui features need neither datasets nor the verifier builds
                    go(spec.id, spec)
                else:
                    self.db.nightly_result(run, spec.id, "setup-failed", 0, 0, 0, 0, 0, detail)
                    reds.append(spec.id)
        return {"reds": reds, "seconds": self.clock() - started, "checks": len(plan.local) + len(gherkin)}

    def _setup(self, run: int, wt: Path, plan: Plan, test_data: str) -> tuple[bool, str]:
        if plan.gherkin_cli:
            ok, detail = self.fetch(wt, datasets_for(wt), test_data)
            if not ok:
                return False, f"dataset fetch failed: {detail}"
            for spec in star.nightly_setup():
                result = self.exec(spec.id, spec, wt)
                self._record(run, result)
                if not result.green:
                    return False, f"{spec.id} failed: {result.detail}"
        return True, ""

    def _compare(self, run: int, sha: str, opts: Options) -> tuple[list[str], list[str]]:
        """Green before, red now. A check never seen before is baseline, not news (like the develop known-red ledger)."""
        current = self.db.nightly_run(run)
        assert current is not None
        new_reds = [r["check_id"] for r in current["results"]
                    if r["status"] != "pass" and self.db.previous_nightly_status(r["check_id"], run) == "pass"]
        filed: list[str] = []
        for check_id in new_reds:
            row = next(r for r in current["results"] if r["check_id"] == check_id)
            title = f"nightly red: {check_id}"
            if not opts.file_tickets:
                filed.append(f"(dry run) {title}")
                continue
            if self._auto_open() >= self.config.max_auto_tickets:
                self.db.event("auto-ticket-capped", None, check=check_id)
                continue
            try:
                n = self.gh.create_issue(title, self._body(check_id, row, sha))
                self.gh.add_labels(n, ["pipe:filed-by-pipeline", "pipeline", "p1"])
                filed.append(f"#{n} {title}")
            except GitHubError as exc:
                self.db.event("nightly-ticket-failed", None, check=check_id, error=str(exc)[:200])
        return new_reds, filed

    def _auto_open(self) -> int:
        issues = self.gh.paged("issues?state=open&labels=pipe:filed-by-pipeline&per_page=100")
        return len([i for i in issues if any(lab["name"] == "pipeline" for lab in i.get("labels", []))])

    def _body(self, check_id: str, row: dict[str, Any], sha: str) -> str:
        tail = ""
        try:
            tail = "\n".join(Path(row["log"]).read_text(errors="replace").splitlines()[-40:])
        except OSError:
            pass
        return (f"## Goal\nMake `{check_id}` pass on develop again.\n\n## Context\nThe nightly found `{check_id}` red "
                f"({row['status']}, {row['failed']} failed of {row['executed']}) at {sha}; it passed the last time it ran. "
                f"Log: `{row['log']}`.\n\n```\n{tail}\n```\n\n## Acceptance criteria\n- A1: `{check_id}` passes on develop — "
                f"check: the next nightly\n\n## Tests\nnone: restores an existing check\n\n## Out of scope\nUnrelated failures.\n")


def summary_line(run: dict[str, Any] | None) -> str:
    if run is None:
        return "no nightly has run"
    when = datetime.fromtimestamp(run["ended"] or run["started"]).strftime("%a %H:%M")
    reds = len(run["summary"].get("reds", []))
    state = "running" if run["ended"] is None else ("error" if run["status"] == "error" else (f"{reds} red" if reds else "green"))
    return f"{when} · {run['sha'][:8]} · {state}"


__all__ = ["Nightly", "Options", "build_plan", "due", "summary_line", "wanted"]
