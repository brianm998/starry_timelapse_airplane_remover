from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path

import pytest

from .fakes import install_fake_mason


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
