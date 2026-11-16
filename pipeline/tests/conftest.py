from __future__ import annotations

import os
import shutil
import subprocess
import sys
from collections.abc import Iterator
from pathlib import Path

import pytest

from .fakes import install_fake_mason


@pytest.fixture(autouse=True, scope="session")
def direct_git(tmp_path_factory: pytest.TempPathFactory) -> Iterator[None]:
    """Run the Xcode git directly, not through the `/usr/bin/git` xcrun shim.

    These tests spawn git thousands of times. On a loaded Mac the shim costs a second xcrun
    process per call: median 3.2 s against 1.1 s direct at load 60-80 (#467), which pushed this
    suite past its time limit. A `git` symlink to the real binary goes first on PATH. A symlinked
    git cannot find its own libexec and templates (it falls back to a compiled-in Xcode path), so
    GIT_EXEC_PATH and GIT_TEMPLATE_DIR name them. Anywhere else (Linux, no Xcode) nothing changes."""
    real = _xcode_git() if sys.platform == "darwin" else None
    if real is None:
        yield
        return
    bin_dir = tmp_path_factory.mktemp("direct-git")
    (bin_dir / "git").symlink_to(real)
    prefix = real.parent.parent  # .../Developer/usr
    with pytest.MonkeyPatch.context() as mp:
        mp.setenv("PATH", f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}")
        mp.setenv("GIT_EXEC_PATH", str(prefix / "libexec" / "git-core"))
        mp.setenv("GIT_TEMPLATE_DIR", str(prefix / "share" / "git-core" / "templates"))
        yield


def _xcode_git() -> Path | None:
    """The real git behind the xcrun shim, when there is one and it looks whole."""
    if shutil.which("git") != "/usr/bin/git" or not shutil.which("xcrun"):
        return None
    try:
        found = subprocess.run(["xcrun", "--find", "git"], capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    real = Path(found.stdout.strip())
    prefix = real.parent.parent
    if found.returncode != 0 or not real.is_file() or not (prefix / "libexec" / "git-core").is_dir() \
            or not (prefix / "share" / "git-core" / "templates").is_dir():
        return None
    return real


@pytest.fixture(autouse=True)
def state_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[Path]:
    """Every test gets its own ~/.star-pipeline."""
    home = tmp_path / "star-pipeline"
    monkeypatch.setenv("STARPIPE_HOME", str(home))
    monkeypatch.delenv("STARPIPE_TICKET", raising=False)
    monkeypatch.delenv("STARPIPE_NIGHTLY", raising=False)
    monkeypatch.delenv("STARPIPE_STAGE", raising=False)
    monkeypatch.delenv("STARPIPE_TICKET_PRIORITY", raising=False)
    for name in ("MASON_TASK", "MASON_STEP", "MASON_HELD", "MASON_WORKTREE"):  # set when MASON runs these tests itself
        monkeypatch.delenv(name, raising=False)
    yield home


@pytest.fixture(autouse=True)
def fake_mason(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """No test talks to the real masond: `mason` is a fake that records argv (tests/fakes.py). The log's path."""
    return install_fake_mason(tmp_path / "fake-mason", monkeypatch)
