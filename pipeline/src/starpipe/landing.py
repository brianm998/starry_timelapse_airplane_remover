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


TOKEN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*|\d+")
WINDOW = 3  # a rewritten or re-wrapped line may spread over this many adjacent lines of the result
MIN_TOKENS = 3  # fewer than this and a line says too little to be matched loosely: it must be there exactly


def _tokens(text: str) -> frozenset[str]:
    return frozenset(TOKEN.findall(text))


def _windows(lines: list[str]) -> list[frozenset[str]]:
    """The token set of every run of up to WINDOW adjacent lines."""
    per_line = [_tokens(x) for x in lines]
    out: list[frozenset[str]] = []
    for i in range(len(per_line)):
        acc: frozenset[str] = frozenset()
        for j in range(i, min(i + WINDOW, len(per_line))):
            acc = acc | per_line[j]
            out.append(acc)
    return out


def audit(root: Path, merge_base: str, develop: str, pr_original: str, result: str = "HEAD") -> list[Dropped]:
    """Every line develop added since the merge-base must still be in `result`, unless the PR's own diff removed it.

    "Still be in" means the exact line, or, when both sides edited the same line (an argument added, a signature re-wrapped), all of
    its words appear together in one line or a few adjacent lines of the result. An exact-only check flagged those rewrites as lost
    lines and parked a ticket whose conflict had been resolved correctly (found live, 2026-10-31); a line that was really deleted has
    no such neighbourhood and is still caught."""
    added = _lines(gitutil.git(root, "diff", "-U0", f"{merge_base}..{develop}"), "+")
    removed_by_pr = _lines(gitutil.git(root, "diff", "-U0", f"{merge_base}..{pr_original}"), "-")
    dropped: list[Dropped] = []
    for file, lines in added.items():
        shown = gitutil.git(root, "show", f"{result}:{file}", check=False).splitlines()
        have = set(shown)
        windows: list[frozenset[str]] | None = None
        gone_by_pr = set(removed_by_pr.get(file, []))
        for line in lines:
            if not line.strip() or re.fullmatch(r"\W*", line):
                continue  # blank lines and bare punctuation move around without meaning
            if line in have or line in gone_by_pr:
                continue
            tokens = _tokens(line)
            if len(tokens) >= MIN_TOKENS:
                windows = windows if windows is not None else _windows(shown)
                if any(tokens <= w for w in windows):
                    continue  # rewritten, not lost
            dropped.append(Dropped(file, line))
    return dropped
