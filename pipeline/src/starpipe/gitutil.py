"""Small git helpers, all run with an explicit cwd."""

from __future__ import annotations

import subprocess
from pathlib import Path


def git(root: Path, *args: str, check: bool = True) -> str:
    done = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, check=False)
    if check and done.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {done.stderr.strip()}")
    return done.stdout


def repo_root(start: Path) -> Path:
    return Path(git(start, "rev-parse", "--show-toplevel").strip())


def resolve_base(root: Path, base: str | None) -> str:
    """origin/develop when it exists, else develop."""
    for candidate in ([base] if base else ["origin/develop", "develop"]):
        if candidate and subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--verify", "--quiet", candidate],
            capture_output=True, check=False,
        ).returncode == 0:
            return candidate
    raise RuntimeError(f"no base ref found ({base or 'origin/develop, develop'})")


def head_sha(root: Path) -> str:
    return git(root, "rev-parse", "HEAD").strip()


def merge_base(root: Path, base: str) -> str:
    return git(root, "merge-base", base, "HEAD").strip()


def changed_paths(root: Path, base: str) -> list[str]:
    """Everything that differs from the merge-base: commits, working-tree edits and untracked files."""
    mb = merge_base(root, base)
    names = git(root, "diff", "--name-only", mb).splitlines()
    names += git(root, "ls-files", "--others", "--exclude-standard").splitlines()
    return sorted({n for n in names if n})


def added_paths(root: Path, base: str) -> list[str]:
    mb = merge_base(root, base)
    out = [line.split("\t", 1)[1] for line in git(root, "diff", "--name-status", "--diff-filter=AR", mb).splitlines()
           if "\t" in line]
    return out + git(root, "ls-files", "--others", "--exclude-standard").splitlines()


def is_clean(root: Path) -> bool:
    return git(root, "status", "--porcelain", "--untracked-files=no").strip() == ""
