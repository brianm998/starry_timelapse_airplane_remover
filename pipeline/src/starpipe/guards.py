"""The fence around a model stage (plan §7.4): pure decisions over (tool, input), wrapped into SDK hooks by agent.py."""

from __future__ import annotations

import os
import re
import shlex
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from . import adapter_star as star

WRITE_TOOLS = {"Write", "Edit", "NotebookEdit", "MultiEdit"}
FORBIDDEN_TOOLS = {"Monitor", "ScheduleWakeup", "CronCreate", "CronDelete", "CronList", "Workflow", "RemoteTrigger"}
BACKGROUND = re.compile(r"(?:^|\s)(?:nohup|disown|setsid)\b|(?<![&])&\s*$|(?<![&])&\s*(?:;|\n)")
REDIRECT = re.compile(r"(?:^|[\s;|&])\d*>>?\s*(?!&)([^\s;|&]+)")
FILE_CMDS = {"rm", "mv", "cp", "tee", "touch", "mkdir", "rmdir", "ln", "truncate", "dd", "install"}
GIT_BAD = [
    (re.compile(r"\bgit\b.*\bpush\b"), "only the daemon pushes"),
    (re.compile(r"\bgit\b.*\b(?:checkout|switch)\b\s+(?:-\w+\s+)*(?:origin/)?develop\b"), "do not switch to develop"),
    (re.compile(r"\bgit\b.*\bbranch\b.*(?:-f|--force|-D|-d|-m|-M)\b.*\bdevelop\b"), "do not touch develop"),
    (re.compile(r"refs/heads/develop|refs/remotes/origin/develop"), "do not touch develop refs"),
    (re.compile(r"\bgit\b.*\bupdate-ref\b"), "do not rewrite refs"),
    (re.compile(r"\bgit\b.*\bworktree\b\s+(?:remove|prune|move)"), "do not manage worktrees"),
]


@dataclass
class Fence:
    worktree: Path
    ticket_dir: Path
    build_dir: Path
    read_only: bool = False
    branch: str = ""
    extra_roots: list[Path] = field(default_factory=lambda: list[Path]())

    def roots(self) -> list[Path]:
        return [self.worktree, self.ticket_dir, self.build_dir, *self.extra_roots]


@dataclass
class Decision:
    kind: str  # allow | deny | rewrite
    reason: str = ""
    command: str = ""


ALLOW = Decision("allow")


def _under(path: str, roots: list[Path], cwd: Path) -> bool:
    if path in ("/dev/null", "/dev/stderr", "/dev/stdout"):
        return True
    p = Path(os.path.expanduser(path))
    p = (p if p.is_absolute() else cwd / p)
    resolved = Path(os.path.normpath(p))
    return any(resolved == r or r in resolved.parents for r in (Path(os.path.normpath(x)) for x in roots)) or any(
        resolved == r or r in resolved.parents for r in (x.resolve() for x in roots)
    )


def _memory_path(path: str) -> bool:
    return "/.claude/projects/" in path and "/memory/" in path


def bash_writes(command: str) -> list[str]:
    """Targets of redirects and of file-mutating commands, found without running a shell."""
    targets = [m.group(1).strip("\"'") for m in REDIRECT.finditer(command)]
    for segment in re.split(r"[;|\n]|&&|\|\|", command):
        try:
            words = shlex.split(segment)
        except ValueError:
            continue
        while words and ("=" in words[0] and not words[0].startswith("-")):
            words = words[1:]
        if words and Path(words[0]).name in FILE_CMDS:
            targets += [w for w in words[1:] if not w.startswith("-")]
    return targets


def decide(tool: str, tool_input: dict[str, Any], fence: Fence, shim: str = "", heavy_ok: bool = True) -> Decision:
    if tool in FORBIDDEN_TOOLS:
        return Decision("deny", f"{tool} is not available in a pipeline stage")
    if tool in WRITE_TOOLS:
        if fence.read_only:
            return Decision("deny", "this stage is read-only")
        path = str(tool_input.get("file_path") or tool_input.get("notebook_path") or "")
        if _memory_path(path):
            return Decision("deny", "the memory directory is read-only in the pipeline")
        if not _under(path, fence.roots(), fence.worktree):
            return Decision("deny", f"{path} is outside the ticket worktree")
        return ALLOW
    if tool == "Agent" and tool_input.get("run_in_background"):
        return Decision("deny", "no background agents")
    if tool != "Bash":
        return ALLOW

    command = str(tool_input.get("command", ""))
    if tool_input.get("run_in_background") or BACKGROUND.search(command):
        return Decision("deny", "no backgrounding: run the command in the foreground and wait for it")
    for pattern, why in GIT_BAD:
        if pattern.search(command):
            return Decision("deny", f"git: {why}")
    if re.search(r"\bgit\b.*\breset\b.*--hard", command) and fence.branch and fence.branch not in command and \
            "HEAD" not in command:
        return Decision("deny", "git reset --hard is allowed only on the ticket branch")
    writes = bash_writes(command)
    if fence.read_only and writes and any(not _under(w, [], fence.worktree) for w in writes):
        return Decision("deny", "this stage is read-only")
    for target in writes:
        if _memory_path(target):
            return Decision("deny", "the memory directory is read-only in the pipeline")
        if not _under(target, fence.roots(), fence.worktree):
            return Decision("deny", f"{target} is outside the ticket worktree")
    if heavy_ok and star.HEAVY_PATTERN.search(command) and "starpipe heavy" not in command and " heavy -- " not in command:
        if not shim:
            return Decision("deny", "run heavy commands as: starpipe heavy -- <command>")
        return Decision("rewrite", "wrapped in the heavy lock",
                        f"{shlex.quote(shim)} heavy -- bash -c {shlex.quote(command)}")
    return ALLOW
