"""The pinned runtime and `starpipe self-update` (plan §14.4).

The daemon must not run from a checkout that moves underneath it: switch branches in the main checkout, or land a ticket that edits
pipeline/, and its code changes while it runs. Instead `~/.star-pipeline/runtime/<sha>/` holds a copy of `pipeline/` at one commit,
built with `uv sync --frozen`; launchd points at the shim inside it; `current` and `previous` are symlinks. Updating is: build the
new runtime, self-test it, wait until no stage is mid-session, repoint launchd, keep the old one. Three crashes within five minutes
of a switch roll back to the previous runtime on their own.
"""

from __future__ import annotations

import importlib
import json
import os
import pkgutil
import plistlib
import shutil
import subprocess
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from .config import home

LABEL = "com.brianm998.starpiped"
CRASH_WINDOW_S = 300.0
CRASH_LIMIT = 3  # starts beyond the first after a switch, inside the window

Sync = Callable[[Path], None]
Launchctl = Callable[[list[str]], int]  # runs launchctl, returns its exit code


def runtime_root() -> Path:
    return home() / "runtime"


def runtime_dir(sha: str) -> Path:
    return runtime_root() / sha[:12]


def shim_of(rt: Path) -> Path:
    return rt / "pipeline" / "bin" / "starpipe"


def link(name: str) -> Path | None:
    path = runtime_root() / name
    return path.resolve() if path.is_symlink() and path.exists() else None


def real_sync(rt: Path) -> None:
    subprocess.run(["uv", "sync", "--frozen", "--project", str(rt / "pipeline")], check=True, capture_output=True, text=True, timeout=900)


def build(repo: Path, sha: str, sync: Sync = real_sync) -> Path:
    """A runtime for `sha`: pipeline/ (without the monitor) from `git archive`, and its environment. Idempotent."""
    rt = runtime_dir(sha)
    if (rt / ".complete").exists():
        return rt
    shutil.rmtree(rt, ignore_errors=True)  # a partial build from an interrupted run
    rt.mkdir(parents=True)
    try:
        archive = subprocess.Popen(["git", "-C", str(repo), "archive", "--format=tar", sha, "--", "pipeline",
                                    ":(exclude)pipeline/monitor"], stdout=subprocess.PIPE)
        subprocess.run(["tar", "-x", "-C", str(rt)], stdin=archive.stdout, check=True)
        if archive.wait() != 0:
            raise RuntimeError(f"git archive {sha} failed")
        if not shim_of(rt).exists():
            raise RuntimeError(f"{sha[:12]} has no pipeline/bin/starpipe: not a pipeline commit")
        sync(rt)
        (rt / ".complete").write_text(sha + "\n")
    except (OSError, RuntimeError, subprocess.SubprocessError):
        shutil.rmtree(rt, ignore_errors=True)
        raise
    return rt


def self_test_in_process() -> list[str]:
    """What `starpipe daemon self-test` checks, run inside the runtime being tested; returns problems (empty is healthy)."""
    problems: list[str] = []
    import starpipe

    for mod in pkgutil.walk_packages(starpipe.__path__, "starpipe."):
        try:
            importlib.import_module(mod.name)
        except Exception as exc:  # noqa: BLE001  # any import failure is a reason not to switch
            problems.append(f"import {mod.name}: {type(exc).__name__}: {exc}")
    try:
        from .config import load

        load()
    except Exception as exc:  # noqa: BLE001
        problems.append(f"config: {exc}")
    try:
        from .db import Database, db_path

        if db_path().exists():
            db = Database(read_only=True)
            db.get("pause")
            db.close()
    except Exception as exc:  # noqa: BLE001
        problems.append(f"database: {exc}")
    try:
        import claude_agent_sdk

        bundled = Path(claude_agent_sdk.__file__).parent / "_bundled" / "claude"
        if not bundled.exists():
            problems.append(f"the SDK's bundled CLI is missing: {bundled}")
    except ImportError as exc:
        problems.append(f"claude_agent_sdk: {exc}")
    prompts = Path(starpipe.__file__).resolve().parents[2] / "prompts"
    for needed in ("_preamble", "explore", "develop", "fix", "review", "resolve", "ci_fix", "conflict"):
        if not (prompts / f"{needed}.md").exists():
            problems.append(f"prompt missing: {needed}.md")
    return problems


def self_test(rt: Path) -> tuple[bool, str]:
    """Run the runtime's own self-test, from its own environment."""
    done = subprocess.run([str(shim_of(rt)), "daemon", "self-test"], capture_output=True, text=True, check=False, timeout=300)
    return done.returncode == 0, (done.stdout + done.stderr).strip()[-800:]


def current_shim() -> Path:
    """The path launchd runs, by way of the `current` symlink: a version switch never has to rewrite the plist."""
    return runtime_root() / "current" / "pipeline" / "bin" / "starpipe"


def repoint(plist: Path) -> bool:
    """Make the plist run the stable `current` shim. True when it had to change (so the agent must be re-bootstrapped)."""
    data = plistlib.loads(plist.read_bytes())
    want = str(current_shim())
    if data["ProgramArguments"][0] == want:
        return False
    data["ProgramArguments"][0] = want
    plist.write_bytes(plistlib.dumps(data))
    return True


def real_launchctl(args: list[str]) -> int:
    return subprocess.run(["launchctl", *args], check=False, capture_output=True, timeout=60).returncode


def restart_agent(plist: Path, changed: bool, launchctl: Launchctl, sleep: Callable[[float], None]) -> None:
    """Restart the launchd agent and check that it is loaded again; raise rather than leave the daemon down.

    bootout is asynchronous: bootstrapping straight after it fails with an I/O error while the job is still being torn down (this
    took the daemon down for minutes the first time), so wait until `launchctl print` no longer finds it, then bootstrap, retrying."""
    domain = f"gui/{os.getuid()}"
    target = f"{domain}/{LABEL}"
    if not changed:
        if launchctl(["kickstart", "-k", target]) != 0:
            raise RuntimeError(f"launchctl kickstart -k {target} failed")
        return
    launchctl(["bootout", target])
    for _ in range(40):
        if launchctl(["print", target]) != 0:
            break  # unloaded
        sleep(0.5)
    for _ in range(10):
        if launchctl(["bootstrap", domain, str(plist)]) == 0:
            return
        sleep(1)
    raise RuntimeError(f"launchctl could not bootstrap {plist}: the daemon is NOT loaded; run `launchctl bootstrap {domain} {plist}`")


def switch(rt: Path, plist: Path, launchctl: Launchctl = real_launchctl, now: float | None = None, restart: bool = True,
           sleep: Callable[[float], None] = time.sleep) -> None:
    """Make `rt` current (the old one becomes previous) and restart the agent on it.

    The first time, the plist is repointed at the `current` symlink and the agent re-bootstrapped (from the CLI, which survives it).
    Afterwards a switch is only the symlink and `kickstart -k`, which is safe to run from inside the daemon itself."""
    root = runtime_root()
    root.mkdir(parents=True, exist_ok=True)
    old = link("current")
    if old is not None and old != rt.resolve():
        _relink(root / "previous", old)
    _relink(root / "current", rt)
    (root / "switched_at").write_text(str(now if now is not None else time.time()))
    (root / "starts.json").write_text("[]")
    changed = repoint(plist)
    if restart:
        restart_agent(plist, changed, launchctl, sleep)


def _relink(path: Path, target: Path) -> None:
    if path.is_symlink() or path.exists():
        path.unlink()
    path.symlink_to(target)


def record_start(now: float | None = None) -> None:
    path = runtime_root() / "starts.json"
    if not path.parent.exists():
        return
    starts: list[float] = json.loads(path.read_text()) if path.exists() else []
    starts.append(now if now is not None else time.time())
    path.write_text(json.dumps(starts[-20:]))


def crash_loop(now: float | None = None) -> bool:
    """Three restarts beyond the first inside five minutes of a switch: the new runtime does not stay up."""
    now = now if now is not None else time.time()
    root = runtime_root()
    marker, starts_file = root / "switched_at", root / "starts.json"
    if not marker.exists() or not starts_file.exists() or link("previous") is None:
        return False
    switched = float(marker.read_text())
    if now - switched > CRASH_WINDOW_S:
        return False
    starts: list[float] = json.loads(starts_file.read_text())
    return len([s for s in starts if s >= switched]) > CRASH_LIMIT


@dataclass
class Report:
    sha: str
    built: bool
    tested: bool
    switched: bool
    detail: str


def update(repo: Path, ref: str, plist: Path, *, sessions: Callable[[], int], wait_s: float = 3600.0, now: bool = False,
           dry_run: bool = False, sync: Sync = real_sync, test: Callable[[Path], tuple[bool, str]] = self_test,
           launchctl: Launchctl = real_launchctl, sleep: Callable[[float], None] = time.sleep,
           clock: Callable[[], float] = time.time) -> Report:
    sha = subprocess.run(["git", "-C", str(repo), "rev-parse", ref], capture_output=True, text=True, check=True).stdout.strip()
    rt = build(repo, sha, sync)
    ok, detail = test(rt)
    if not ok:
        return Report(sha, True, False, False, f"the new runtime failed its self-test, not switching:\n{detail}")
    if dry_run:
        return Report(sha, True, True, False, "dry run: built and tested, not switched")
    if link("current") == rt.resolve():
        return Report(sha, True, True, False, "already running this runtime")
    deadline = clock() + wait_s
    while not now and (busy := sessions()) > 0:
        if clock() >= deadline:
            return Report(sha, True, True, False, f"{busy} stage session(s) still running after the wait; use --now to switch anyway")
        sleep(10)
    switch(rt, plist, launchctl, clock(), sleep=sleep)
    return Report(sha, True, True, True, f"switched to {sha[:12]}")


def rollback(plist: Path, launchctl: Launchctl = real_launchctl, clock: Callable[[], float] = time.time) -> str:
    """Go back to the previous runtime; `previous` then points at what was left, so a second rollback undoes this one."""
    previous = link("previous")
    if previous is None:
        raise RuntimeError("there is no previous runtime to go back to")
    switch(previous, plist, launchctl, clock())
    return previous.name
