"""Ticket worktrees (plan §9.3): .claude/worktrees/pipe-<n> on branch pipe/<n>-<slug>, cut from origin/develop."""

from __future__ import annotations

import re
import shutil
from pathlib import Path

from . import adapter_star as star
from .config import home
from .gitutil import git


def slug(title: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")[:40] or "ticket"


def branch_name(number: int, title: str) -> str:
    return f"pipe/{number}-{slug(title)}"


def worktree_path(repo: Path, number: int) -> Path:
    return repo / ".claude" / "worktrees" / f"pipe-{number}"


def ticket_dir(number: int) -> Path:
    path = home() / "tickets" / str(number)
    path.mkdir(parents=True, exist_ok=True)
    return path


def link_artifacts(repo: Path, worktree: Path) -> list[str]:
    """Symlink the untracked build inputs from the main checkout (memory gui-worktree-build)."""
    linked: list[str] = []
    for rel in star.ARTIFACT_LINKS:
        src, dst = repo / rel, worktree / rel
        if src.exists() and not dst.exists() and not dst.is_symlink():
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.symlink_to(src)
            linked.append(rel)
    return linked


def create(repo: Path, number: int, title: str, base: str) -> tuple[Path, str]:
    """Make (or reuse) the ticket's worktree. Idempotent, so a restarted CLAIM is harmless."""
    wt, branch = worktree_path(repo, number), branch_name(number, title)
    if not wt.exists():
        wt.parent.mkdir(parents=True, exist_ok=True)
        exists = git(repo, "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}", check=False).strip()
        if exists:
            git(repo, "worktree", "add", str(wt), branch)
        else:
            git(repo, "worktree", "add", "-b", branch, str(wt), base)
    link_artifacts(repo, wt)
    return wt, branch


def remove(repo: Path, number: int, keep_branch: bool = True, branch: str | None = None) -> None:
    wt = worktree_path(repo, number)
    if wt.exists():
        for rel in star.ARTIFACT_LINKS:  # symlinks first, so `worktree remove` never follows into the main checkout
            link = wt / rel
            if link.is_symlink():
                link.unlink()
        git(repo, "worktree", "remove", "--force", str(wt), check=False)
    shutil.rmtree(home() / "build" / f"pipe-{number}", ignore_errors=True)
    if branch and not keep_branch:
        git(repo, "branch", "-D", branch, check=False)
