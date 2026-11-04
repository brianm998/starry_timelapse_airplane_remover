"""gherkin/hang-watchdog.sh: dumps when stard's log goes quiet, says nothing while it grows (ticket #54)."""
from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "gherkin" / "hang-watchdog.sh"
BANNER = "stard hang watchdog: dump"
NAME = "fakestardwd-unique-token"


@pytest.fixture
def fake_stard(tmp_path: Path):
    """A process (a script, since a copied system binary is killed on macOS) matched by NAME and whose command line carries `--scratch <tmp>`; its log is <tmp>/logs/stard.log."""
    exe = tmp_path / NAME
    exe.write_text("#!/bin/bash\nsleep 120\n")
    exe.chmod(0o755)
    scratch = tmp_path / "scratch"
    (scratch / "logs").mkdir(parents=True)
    log = scratch / "logs" / "stard.log"
    log.write_text("starAlignment(complete)\nResourceGovernor: CPU gate 2/2\n")
    proc = subprocess.Popen([str(exe), "--scratch", str(scratch)])
    yield proc, log
    proc.kill()
    proc.wait()


def watch(seconds: float, limit: int = 2) -> str:
    """Run the watchdog for `seconds`, then stop it and return its output."""
    p = subprocess.Popen(["bash", str(SCRIPT), str(limit), "1"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                         env={**os.environ, "HANG_WATCHDOG_PGREP": f"-f {NAME}"})
    time.sleep(seconds)
    p.terminate()
    out, _ = p.communicate(timeout=30)
    return out


def testWatchdogDumpsWhenStardLogGoesQuiet(fake_stard):
    proc, log = fake_stard
    out = watch(9)
    assert out.count(BANNER) >= 1, out
    assert out.count(BANNER) <= 2, out  # a first dump and one more, then silence for that pid
    assert f"pid {proc.pid}" in out
    assert "--- ps" in out
    assert str(proc.pid) in out.split("--- ps", 1)[1]
    assert "ResourceGovernor: CPU gate 2/2" in out  # the log tail
    assert "--- jstack of every JVM" in out  # tools that are absent degrade to a note, the dump still completes
    assert "::endgroup::" in out


def testWatchdogStaysSilentWhileStardLogGrows(fake_stard):
    proc, log = fake_stard
    grower = subprocess.Popen(["bash", "-c", f"while :; do echo tick >> '{log}'; sleep 0.5; done"])
    try:
        out = watch(7)
    finally:
        grower.kill()
        grower.wait()
    assert BANNER not in out, out
