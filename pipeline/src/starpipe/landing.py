"""Pure parts of LAND (plan §10): which overlaps force a re-test, and the dropped-line audit."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from . import gitutil
from .checks import impact


@dataclass
class Overlap:
    files: list[str]
    checks: list[str]

    @property
    def any(self) -> bool:
        return bool(self.files or self.checks)


def overlap(root: Path, merge_base: str, develop: str, pr_files: list[str]) -> Overlap:
    """Files and T1 check sets that develop's new changes share with the PR's."""
    new = [p for p in gitutil.git(root, "diff", "--name-only", f"{merge_base}..{develop}").splitlines() if p]
    shared = sorted(set(new) & set(pr_files))
    theirs = set(impact.plan_for(new).t1())
    ours = set(impact.plan_for(pr_files).t1())
    return Overlap(shared, sorted(theirs & ours))


@dataclass
class Dropped:
    file: str
    line: str


def _lines(diff: str, sign: str) -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    current = ""
    for row in diff.splitlines():
        if row.startswith("+++ "):
            current = row[6:] if row.startswith("+++ b/") else ""
        elif current and row.startswith(sign) and not row.startswith(sign * 3):
            out.setdefault(current, []).append(row[1:])
    return out


def audit(root: Path, merge_base: str, develop: str, pr_original: str, result: str = "HEAD") -> list[Dropped]:
    """Every line develop added since the merge-base must still be in `result`, unless the PR's own diff removed it."""
    added = _lines(gitutil.git(root, "diff", "-U0", f"{merge_base}..{develop}"), "+")
    removed_by_pr = _lines(gitutil.git(root, "diff", "-U0", f"{merge_base}..{pr_original}"), "-")
    dropped: list[Dropped] = []
    for file, lines in added.items():
        shown = gitutil.git(root, "show", f"{result}:{file}", check=False)
        have = set(shown.splitlines())
        gone_by_pr = set(removed_by_pr.get(file, []))
        for line in lines:
            if not line.strip() or re.fullmatch(r"\W*", line):
                continue  # blank lines and bare punctuation move around without meaning
            if line not in have and line not in gone_by_pr:
                dropped.append(Dropped(file, line))
    return dropped
