"""`starpipe freeze` / `thaw`: stop all automated work on this Mac, through masond (owner decision 0119-5).

Freeze is two things: `mason pause --mode all` (MASON's own tasks stop at their next step) and a detached holder of
`mason hold --exclusive --pipeline starpipe --label freeze`, which keeps every job and session of every pipeline waiting in
masond's queue. Waiting is harmless: they start when `thaw` lets go. A run already going is not stopped by this; kill it first.

The holder is a process of its own so it outlives the command. If it dies (a reboot, a logout) its hold ends with it; the pause
stays until `thaw` or `mason resume`."""

from __future__ import annotations

import contextlib
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

from . import masonq
from .config import home


def pidfile() -> Path:
    return home() / "freeze.pid"


def paused_pid() -> int | None:
    """The live holder's pid, or None."""
    try:
        pid = int(pidfile().read_text())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return None


def _stop(_signum: int, _frame: object) -> None:
    sys.exit(0)


def hold() -> None:
    """The holder process: take the exclusive hold (it waits in masond's queue for running jobs to end) and sit on it."""
    pidfile().parent.mkdir(parents=True, exist_ok=True)
    pidfile().write_text(str(os.getpid()))
    signal.signal(signal.SIGTERM, _stop)
    held = masonq.acquire(None, "freeze", exclusive=True)
    try:
        while True:
            time.sleep(3600)
    finally:
        held.release()


def _mason(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([masonq.binary(), *args], capture_output=True, text=True, stdin=subprocess.DEVNULL, check=False)


def pause() -> int:
    """`mason pause --mode all`, then start the holder, detached; its pid."""
    if (pid := paused_pid()) is not None:
        return pid
    done = _mason("pause", "--mode", "all")
    if done.returncode != 0:
        raise RuntimeError(f"mason pause --mode all failed ({done.returncode}): {(done.stderr or done.stdout).strip()}")
    proc = subprocess.Popen([sys.executable, "-m", "starpipe.pause"], start_new_session=True, stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pidfile().parent.mkdir(parents=True, exist_ok=True)
    pidfile().write_text(str(proc.pid))
    return proc.pid


def resume() -> bool:
    """Release the hold and MASON's pause; whether anything was frozen."""
    pid = paused_pid()
    if pid is not None:
        with contextlib.suppress(OSError):
            os.kill(pid, signal.SIGTERM)
    pidfile().unlink(missing_ok=True)
    if pid is None:
        return False
    done = _mason("resume", "--mode", "all")
    if done.returncode != 0:
        raise RuntimeError(f"mason resume --mode all failed ({done.returncode}): {(done.stderr or done.stdout).strip()}")
    return True


if __name__ == "__main__":
    with contextlib.suppress(KeyboardInterrupt):
        hold()
