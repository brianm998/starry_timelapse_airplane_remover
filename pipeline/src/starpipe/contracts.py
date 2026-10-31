"""The tool contracts of the model stages (plan §7.2). Validation lives here, not in the SDK glue, so the real
runner and the test fakes call the same code. Every method returns text for the model: either "accepted…" or what is
wrong, so it can fix it inside the same session."""

from __future__ import annotations

import difflib
import json
import re
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, ValidationError

from . import gitutil
from . import plan as planmod
from .checks import impact, ledger
from .db import Database, Ticket
from .github import GitHub, GitHubError

ACCEPTED = "accepted. End your turn now."
CLOSE_REASONS = ("duplicate-of", "already-done", "no-defect", "not-this-repo")
GUI_PREFIX, DESKTOP_PREFIX = "gui/star/", "star-desktop/src/main/"

CheckRunner = Callable[[Path, str], list[ledger.Result]]


class ChangeSubmission(BaseModel):
    summary: str
    deviations: list[dict[str, str]] = []
    tests_added: list[dict[str, str]] = []
    parity_reason: str = ""
    memory_notes: list[str] = []


class Finding(BaseModel):
    file: str
    line: int = 0
    severity: Literal["blocker", "major", "minor"]
    issue: str
    suggested_fix: str = ""


class Review(BaseModel):
    verdict: Literal["approve", "changes"]
    findings: list[Finding] = []
    parity_accepted: bool = True
    notes: str = ""


class Resolution(BaseModel):
    kind: Literal["answer", "followup", "close", "escalate"]
    text: str
    reasons: list[str] = []


@dataclass
class Contract:
    """One stage session's tools. `result` is set once a submit_* call is accepted."""

    ticket: Ticket
    worktree: Path
    base_ref: str
    db: Database
    gh: GitHub | None = None
    check_runner: CheckRunner | None = None
    owner_filed: bool = True
    result: tuple[str, Any] | None = None
    lock_wait_s: float = 0.0  # seconds spent waiting for the heavy lock; stage budgets are net of it
    followups: list[dict[str, Any]] = field(default_factory=list[dict[str, Any]])

    def _bug(self) -> bool:
        return bool(re.search(r"\b(bug|fix|crash|regress|wrong|fails?)\b", self.ticket.title, re.IGNORECASE))

    def _accept(self, kind: str, value: Any) -> str:
        self.result = (kind, value)
        return ACCEPTED

    # EXPLORE -------------------------------------------------------------------------------------------------------
    def submit_plan(self, args: dict[str, Any]) -> str:
        try:
            p = planmod.Plan.model_validate(args)
        except ValidationError as exc:
            return "plan rejected:\n" + "\n".join(f"- {'.'.join(map(str, e['loc']))}: {e['msg']}" for e in exc.errors())
        errors = planmod.validate(p, self.worktree, self.ticket.body, self._bug())
        if errors:
            return "plan rejected:\n" + "\n".join(f"- {e}" for e in errors)
        return self._accept("plan", p.model_dump())

    def close_ticket(self, args: dict[str, Any]) -> str:
        reason, evidence = str(args.get("reason", "")), [str(e) for e in args.get("evidence", [])]
        if reason.split(" ")[0] not in CLOSE_REASONS:
            return f"reason must be one of {', '.join(CLOSE_REASONS)} (duplicate-of needs '#n')"
        if not evidence:
            return "evidence is required: commit SHAs on origin/develop, or file:line"
        bad: list[str] = []
        for item in evidence:
            if re.fullmatch(r"[0-9a-f]{7,40}", item):
                ok = subprocess_ok(self.worktree, "merge-base", "--is-ancestor", item, self.base_ref)
            else:
                m = re.fullmatch(r"(.+):(\d+)", item)
                ok = bool(m) and (self.worktree / m.group(1)).is_file() and \
                    int(m.group(2)) <= len((self.worktree / m.group(1)).read_text(errors="replace").splitlines())
            if not ok:
                bad.append(item)
        if bad:
            return "evidence not verifiable (not an ancestor of the base, or no such file:line): " + ", ".join(bad)
        return self._accept("close", {"reason": reason, "evidence": evidence, "owner_filed": self.owner_filed})

    # DEVELOP / FIX ----------------------------------------------------------------------------------------------------
    def run_checks(self, args: dict[str, Any]) -> str:
        if self.check_runner is None:
            return "run_checks is not available in this stage"
        results = self.check_runner(self.worktree, self.base_ref)
        sha = gitutil.head_sha(self.worktree)
        self.lock_wait_s += sum(r.lock_wait for r in results)
        for r in results:
            self.db.record_check(self.ticket.number, sha, r.check, r.status,
                                 {"executed": r.executed, "failed": r.failed, "skipped": r.skipped}, r.log)
        lines = [f"{'PASS' if r.green else r.status.upper()} {r.check} ({r.executed} tests, {r.failed} failed)"
                 + ("" if r.green else f" — {r.detail} log: {r.log}") for r in results]
        return "\n".join(lines) or "no checks needed for this diff"

    def _missing_green(self, sha: str) -> list[str]:
        changed = gitutil.changed_paths(self.worktree, self.base_ref)
        need = impact.plan_for(changed)
        wanted = [*need.t0, *need.t1()]
        return [c for c in wanted if not (r := ledger.latest(sha, c)) or not r.green]

    def submit_change(self, args: dict[str, Any]) -> str:
        try:
            sub = ChangeSubmission.model_validate(args)
        except ValidationError as exc:
            return "change rejected:\n" + "\n".join(f"- {'.'.join(map(str, e['loc']))}: {e['msg']}" for e in exc.errors())
        problems: list[str] = []
        if not gitutil.is_clean(self.worktree) or gitutil.git(self.worktree, "ls-files", "--others",
                                                               "--exclude-standard").strip():
            problems.append("the tree is not clean: commit or remove everything")
        if not gitutil.git(self.worktree, "log", f"{self.base_ref}..HEAD", "--oneline").strip():
            problems.append("no commits on the branch")
        if not problems:
            sha = gitutil.head_sha(self.worktree)
            red = self._missing_green(sha)
            if red:
                problems.append(f"no green result at HEAD {sha[:10]} for: {', '.join(red)} (call run_checks)")
            plan = self.ticket.plan or {}
            diff = gitutil.git(self.worktree, "diff", f"{self.base_ref}...HEAD")
            for t in plan.get("tests", {}).get("new", []):
                if t["name"] not in diff:
                    problems.append(f"planned test '{t['name']}' does not appear in the diff")
            changed = gitutil.changed_paths(self.worktree, self.base_ref)
            gui = any(p.startswith(GUI_PREFIX) for p in changed)
            desktop = any(p.startswith(DESKTOP_PREFIX) for p in changed)
            if gui != desktop and not sub.parity_reason.strip():
                problems.append("gui and desktop changed one-sided: give parity_reason (CLAUDE.md)")
        if problems:
            return "change rejected:\n" + "\n".join(f"- {p}" for p in problems)
        return self._accept("change", sub.model_dump())

    # REVIEW --------------------------------------------------------------------------------------------------------
    def submit_review(self, args: dict[str, Any]) -> str:
        try:
            r = Review.model_validate(args)
        except ValidationError as exc:
            return "review rejected:\n" + "\n".join(f"- {'.'.join(map(str, e['loc']))}: {e['msg']}" for e in exc.errors())
        if r.verdict == "changes" and not r.findings:
            return "a 'changes' verdict needs at least one finding"
        if r.verdict == "approve" and any(f.severity == "blocker" for f in r.findings):
            return "cannot approve with a blocker finding"
        return self._accept("review", r.model_dump())

    # all model stages ------------------------------------------------------------------------------------------------
    def ask_question(self, args: dict[str, Any]) -> str:
        q, why = str(args.get("question", "")).strip(), str(args.get("why_unanswerable", "")).strip()
        if not q or not why:
            return "give the question and why the repo, ticket and memory do not answer it"
        return self._accept("question", {"question": q, "why": why, "options": args.get("options", []),
                                         "recommendation": args.get("recommendation", ""),
                                         "blocking": bool(args.get("blocking", True))})

    def file_followup(self, args: dict[str, Any]) -> str:
        title, body = str(args.get("title", "")).strip(), str(args.get("body", "")).strip()
        if not title or not body:
            return "followup needs a title and a body"
        if self.gh is not None:
            try:
                for issue in self.gh.paged("issues?state=open&per_page=100"):
                    if difflib.SequenceMatcher(None, title.lower(), issue["title"].lower()).ratio() >= 0.8:
                        return f"duplicate of open issue #{issue['number']}; not filed"
            except GitHubError as exc:
                return f"could not check for duplicates: {exc}"
        self.followups.append({"title": title, "body": body, "blocks": bool(args.get("blocks", False))})
        return "followup recorded (it is filed without the pipeline label)"

    # RESOLVE -------------------------------------------------------------------------------------------------------
    def submit_resolution(self, args: dict[str, Any]) -> str:
        try:
            r = Resolution.model_validate(args)
        except ValidationError as exc:
            return "resolution rejected:\n" + "\n".join(f"- {'.'.join(map(str, e['loc']))}: {e['msg']}" for e in exc.errors())
        if r.kind == "answer" and not r.reasons:
            return "an answer must cite what settles it (repo path, CLAUDE.md, memory, earlier owner answer)"
        return self._accept("resolution", r.model_dump())


def subprocess_ok(root: Path, *args: str) -> bool:
    import subprocess
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, check=False).returncode == 0


def dump(contract: Contract) -> str:
    return json.dumps(contract.result, default=str)
