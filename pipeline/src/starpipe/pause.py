"""`starpipe pause` / `resume`: hold every heavy-lock slot so no test, build or UI run starts, whatever version of the pipeline asks.

The lock is flock on files in ~/.star-pipeline/locks. Every version of the code, back to the one-slot lock (`heavy.slot0`), waits on
those same files, so a process that holds them all stops the daemon's checks, the agents in ticket worktrees (whose own, older
`heavy.py` runs) and a session's wrapped commands alike, without any of them knowing about it. Waiting is harmless: they start when
`resume` lets go. A run already going is not stopped by this; kill it first.

The holder dies with a reboot or a logout, which is a resume."""

from __future__ import annotations

import contextlib
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

from . import heavy
from .config import load


def pidfile() -> Path:
    return heavy.locks_dir() / "pause.pid"


def paused_pid() -> int | None:
    """The live holder's pid, or None."""
    try:
        pid = int(pidfile().read_text())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return None


def hold() -> None:
    """Take every slot (retrying until each is free: a job that is running lets go when it ends) and sit on them."""
    names = heavy._all_slots(load())  # pyright: ignore[reportPrivateUsage]
    held: dict[str, int] = {}
    pidfile().write_text(str(os.getpid()))
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    while len(held) < len(names):
        for name in names:
            if name not in held and (fd := heavy._try_slot(name)) is not None:  # pyright: ignore[reportPrivateUsage]
                held[name] = fd
        if len(held) < len(names):
            time.sleep(0.2)
    while True:
        time.sleep(3600)


def pause() -> int:
    """Start the holder, detached; its pid."""
    if (pid := paused_pid()) is not None:
        return pid
    proc = subprocess.Popen([sys.executable, "-m", "starpipe.pause"], start_new_session=True, stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return proc.pid


def resume() -> bool:
    """Let go of the slots; whether anything was paused."""
    pid = paused_pid()
    if pid is not None:
        with contextlib.suppress(OSError):
            os.kill(pid, signal.SIGTERM)
    pidfile().unlink(missing_ok=True)
    return pid is not None


if __name__ == "__main__":
    with contextlib.suppress(KeyboardInterrupt):
        hold()
