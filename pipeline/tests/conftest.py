from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path

import pytest


@pytest.fixture(autouse=True)
def state_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[Path]:
    """Every test gets its own ~/.star-pipeline."""
    home = tmp_path / "star-pipeline"
    monkeypatch.setenv("STARPIPE_HOME", str(home))
    monkeypatch.delenv("STARPIPE_TICKET", raising=False)
    monkeypatch.delenv("STARPIPE_NIGHTLY", raising=False)
    yield home
