"""`starpipe freeze` / `thaw` through masond (ticket #169, owner decision 0119-5)."""

from __future__ import annotations

import time
from collections.abc import Callable
from pathlib import Path

import pytest

from starpipe import pause


def wait_until(condition: Callable[[], bool], timeout: float = 20.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.1)
    return False


def lines(log: Path) -> list[str]:
    return log.read_text().splitlines()


def test_freeze_pauses_mason_and_holds_the_machine_exclusively_until_thawed(fake_mason: Path) -> None:
    holder = pause.pause()
    try:
        assert wait_until(lambda: any(ln.startswith("hold ") for ln in lines(fake_mason)))
        log = lines(fake_mason)
        assert log[0] == "pause --mode all"
        assert "hold hold --needs exclusive --exclusive --pipeline starpipe --label freeze" in log
        assert pause.paused_pid() == holder
        assert pause.pause() == holder, "freezing twice is one freeze"
    finally:
        assert pause.resume()
    assert wait_until(lambda: any(ln.startswith("released ") for ln in lines(fake_mason))), "thaw lets go of the hold"
    assert lines(fake_mason)[-1] == "resume --mode all" or "resume --mode all" in lines(fake_mason)
    assert pause.paused_pid() is None
    assert not pause.resume(), "thawing what is not frozen does nothing"
    assert lines(fake_mason).count("resume --mode all") == 1


def test_a_failed_mason_pause_is_an_error_and_holds_nothing(fake_mason: Path, monkeypatch: pytest.MonkeyPatch,
                                                            tmp_path: Path) -> None:
    broken = tmp_path / "broken-mason"
    broken.write_text("#!/bin/sh\necho 'no masond' >&2\nexit 3\n")
    broken.chmod(0o755)
    monkeypatch.setenv("STARPIPE_MASON", str(broken))
    with pytest.raises(RuntimeError, match="no masond"):
        pause.pause()
    assert pause.paused_pid() is None
