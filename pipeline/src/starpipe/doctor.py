"""`starpipe doctor`: the owner's one-time prerequisites (plan §16) and tool presence."""

from __future__ import annotations

import shutil
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from . import adapter_star as star
from .config import home


@dataclass
class Finding:
    level: str  # ok | warn | fail
    name: str
    detail: str


def _env_file(name: str, key: str, required: bool) -> Finding:
    path = home() / name
    level = "fail" if required else "warn"
    if not path.exists():
        return Finding(level, name, f"missing: put {key}=... in {path} (chmod 600)")
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        return Finding("fail", name, f"mode {mode:o}: run chmod 600 {path}")
    if key not in path.read_text():
        return Finding(level, name, f"{path} has no {key}")
    return Finding("ok", name, "present, mode 600")  # never print the value


def _cmd(name: str, why: str, required: bool = True) -> Finding:
    found = shutil.which(name)
    if found:
        return Finding("ok", name, found)
    return Finding("fail" if required else "warn", name, f"not on PATH ({why})")


def run(root: Path) -> list[Finding]:
    out = [
        Finding("ok" if sys.version_info >= (3, 13) else "fail", "python", sys.version.split()[0]),
        _cmd("uv", "runs the pipeline"),
        _cmd("git", "everything"),
        _cmd("swift", "StarCore, cli, daemon builds"),
        _cmd("xcodebuild", "the gui build"),
        _cmd("gh", "GitHub access until a PAT is configured", required=False),
        _env_file("claude.env", "CLAUDE_CODE_OAUTH_TOKEN", required=False),
        _env_file("github.env", "GITHUB_TOKEN", required=False),
        _env_file("ntfy.env", "STARPIPE_NTFY_URL", required=False),
    ]
    claude = shutil.which("claude")
    if claude and not Path(claude).exists():
        out.append(Finding("warn", "claude", f"{claude} is a dead path; the SDK's bundled CLI is used"))
    elif claude:
        out.append(Finding("ok", "claude", claude))
    for link in star.ARTIFACT_LINKS:
        path = root / link
        out.append(Finding("ok" if path.exists() else "warn", f"artifact {link}",
                           "present" if path.exists() else "missing: symlink it from the main checkout"))
    auto = shutil.which("automationmodetool")
    if auto:
        text = subprocess.run([auto], capture_output=True, text=True, check=False).stdout
        ok = "does not require" in text.lower()
        out.append(Finding("ok" if ok else "warn", "automation mode",
                           "enabled" if ok else "run: sudo automationmodetool enable-automationmode-without-authentication"))
    plist = Path.home() / "Library/LaunchAgents/com.brianm998.starpiped.plist"
    out.append(Finding("ok" if plist.exists() else "warn", "launch agent",
                       str(plist) if plist.exists() else "not installed (the daemon arrives in Phase 3)"))
    out.append(Finding("ok", "state dir", str(home())))
    return out


def exit_code(findings: list[Finding]) -> int:
    return 1 if any(f.level == "fail" for f in findings) else 0


