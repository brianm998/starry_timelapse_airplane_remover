"""The xcodebuild PATH shim (.mason/shims/xcodebuild), run against stubs; nothing really builds."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

SHIM = Path(__file__).resolve().parents[2] / ".mason" / "shims" / "xcodebuild"
GUI = ["-project", "gui/star.xcodeproj", "-scheme", "star", "CODE_SIGNING_ALLOWED=NO", "build"]


def stub(path: Path, name: str, log: Path) -> None:
    path.write_text(f'#!/bin/bash\necho "{name} $*" >> "{log}"\n')
    path.chmod(0o755)


@pytest.fixture
def world(tmp_path: Path) -> tuple[Path, Path, dict[str, str]]:
    repo = tmp_path / "repo"
    (repo / ".mason" / "scripts").mkdir(parents=True)
    (repo / ".mason" / "shims").mkdir()
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    log = tmp_path / "log"
    stub(repo / ".mason" / "scripts" / "xcodebuild-signed.sh", "wrapper", log)
    (repo / ".mason" / "shims" / "xcodebuild").write_bytes(SHIM.read_bytes())
    (repo / ".mason" / "shims" / "xcodebuild").chmod(0o755)
    bindir = tmp_path / "bin"
    bindir.mkdir()
    stub(bindir / "xcodebuild", "next", log)
    env = {k: v for k, v in os.environ.items() if not k.startswith("STAR_")}
    env["PATH"] = f"{repo / '.mason' / 'shims'}:{bindir}:/usr/bin:/bin"
    return repo, log, env


def call(repo: Path, env: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(repo / ".mason" / "shims" / "xcodebuild"), *args], cwd=repo, env=env,
                          capture_output=True, text=True, check=True)


def test_unsigned_gui_call_goes_to_the_wrapper(world: tuple[Path, Path, dict[str, str]]) -> None:
    repo, log, env = world
    done = call(repo, env, *GUI)
    assert log.read_text().strip() == "wrapper -project gui/star.xcodeproj -scheme star build"
    assert "removable-volume" in done.stderr


def test_other_calls_go_to_the_next_xcodebuild_unchanged(world: tuple[Path, Path, dict[str, str]]) -> None:
    repo, log, env = world
    call(repo, env, "-project", "other/x.xcodeproj", "CODE_SIGNING_ALLOWED=NO", "build")
    call(repo, env, "-project", "gui/star.xcodeproj", "-scheme", "star", "build")
    assert log.read_text().splitlines() == [
        "next -project other/x.xcodeproj CODE_SIGNING_ALLOWED=NO build",
        "next -project gui/star.xcodeproj -scheme star build",
    ]


def test_opt_out_and_loop_guard_pass_straight_through(world: tuple[Path, Path, dict[str, str]]) -> None:
    repo, log, env = world
    call(repo, {**env, "STAR_TEST_SIGN_IDENTITY": "-"}, *GUI)
    call(repo, {**env, "STAR_XCODEBUILD_SHIM_PASSED": "1"}, *GUI)
    assert log.read_text().splitlines() == ["next " + " ".join(GUI)] * 2


def test_real_wrapper_sets_the_loop_guard() -> None:
    wrapper = SHIM.parent.parent / "scripts" / "xcodebuild-signed.sh"
    assert "export STAR_XCODEBUILD_SHIM_PASSED=1" in wrapper.read_text()
