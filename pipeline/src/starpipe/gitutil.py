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


def is_ancestor(root: Path, ancestor: str, descendant: str) -> bool:
    return subprocess.run(["git", "-C", str(root), "merge-base", "--is-ancestor", ancestor, descendant],
                          capture_output=True, check=False).returncode == 0


# remote access over https (plan §14.3): the daemon has no ssh agent under launchd ---------------------------------------
REMOTE_TIMEOUT_S = 600.0


def gh_token() -> str:
    """GH_TOKEN / GITHUB_TOKEN from the environment or ~/.star-pipeline/github.env, else `gh auth token`."""
    import os

    from .config import home

    for key in ("GH_TOKEN", "GITHUB_TOKEN"):
        if os.environ.get(key):
            return os.environ[key]
    env = home() / "github.env"
    if env.exists():
        for line in env.read_text().splitlines():
            name, sep, value = line.strip().removeprefix("export ").partition("=")
            if sep and name.strip() in ("GH_TOKEN", "GITHUB_TOKEN") and value.strip():
                return value.strip().strip("\"'")
    done = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, check=False)
    if done.returncode != 0 or not done.stdout.strip():
        raise RuntimeError("no GitHub token: set GH_TOKEN, fill ~/.star-pipeline/github.env, or run `gh auth login`")
    return done.stdout.strip()


def _askpass() -> Path:
    from .config import home

    path = home() / "askpass.sh"
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#!/bin/sh\ncase "$1" in *sername*) echo x-access-token;; *) echo "$STARPIPE_GH_TOKEN";; esac\n')
        path.chmod(0o700)
    return path


def remote_git(root: Path, owner: str, repo: str, *args: str) -> str:
    """git over https to this repo, the token passed by environment (never argv) through GIT_ASKPASS."""
    import os

    env = {**os.environ, "GIT_ASKPASS": str(_askpass()), "GIT_TERMINAL_PROMPT": "0", "STARPIPE_GH_TOKEN": gh_token()}
    url = f"https://github.com/{owner}/{repo}.git"
    try:
        done = subprocess.run(["git", "-C", str(root), *[a.replace("@URL@", url) for a in args]],
                              capture_output=True, text=True, check=False, env=env, timeout=REMOTE_TIMEOUT_S)
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(f"git {args[0]} timed out after {REMOTE_TIMEOUT_S:.0f}s") from exc
    if done.returncode != 0:
        raise RuntimeError(f"git {args[0]} failed: {done.stderr.strip()[-400:]}")
    return done.stdout


def remote_fetch(root: Path, owner: str, repo: str, base: str) -> None:
    """Update origin/<base> and every pipe branch's remote-tracking ref without touching local branches."""
    remote_git(root, owner, repo, "fetch", "--quiet", "@URL@", f"+refs/heads/{base}:refs/remotes/origin/{base}")


def remote_push(root: Path, owner: str, repo: str, branch: str) -> None:
    remote_git(root, owner, repo, "push", "--quiet", "@URL@", f"HEAD:refs/heads/{branch}")
