from __future__ import annotations

import importlib.metadata
import os
import plistlib
import subprocess
from pathlib import Path
from typing import Any

import pytest
from click.testing import CliRunner

from starpipe import selfupdate
from starpipe.cli import landing_lines, main
from starpipe.config import home

from .fakes import sh
from .test_selfupdate import Launchctl, make_pipeline_repo, noop_sync


def make_repo(tmp: Path) -> Path:
    def g(*a: str) -> None:
        subprocess.run(["git", "-C", str(tmp), *a], check=True, capture_output=True)
    g("init", "-b", "develop")
    g("config", "user.email", "t@t")
    g("config", "user.name", "t")
    (tmp / "a.txt").write_text("a\n")
    g("add", "-A")
    g("commit", "-m", "base")
    g("checkout", "-b", "work")
    return tmp


def test_explain_on_a_starcore_change(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    p = repo / "StarCore/Sources/StarCore/X.swift"
    p.parent.mkdir(parents=True)
    p.write_text("x\n")
    out = CliRunner().invoke(main, ["check", "--explain", "--diff", "develop", "--worktree", str(repo)])
    assert out.exit_code == 0, out.output
    for line in ("build:StarCore", "build:cli", "build:daemon", "build:gui", "test:StarCore"):
        assert line in out.output
    assert "test:daemon" not in out.output and "test:gui" not in out.output


def test_t0_catches_an_artifact_path(tmp_path: Path) -> None:
    repo = make_repo(tmp_path)
    link = repo / "gui/videos"
    link.parent.mkdir(parents=True)
    link.write_text("x")
    subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(repo), "commit", "-qm", "oops"], check=True)
    out = CliRunner().invoke(main, ["check", "--tier", "t0", "--diff", "develop", "--worktree", str(repo)])
    assert out.exit_code == 1 and "gui/videos" in (out.output + (out.stderr if out.stderr_bytes else ""))


def test_version_flag() -> None:
    out = CliRunner().invoke(main, ["--version"])
    assert out.exit_code == 0, out.output
    assert f"starpipe, version {importlib.metadata.version('starpipe')}" in out.output


def test_daemon_install_pins_a_runtime_at_origin_develop(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    repo, _ = make_pipeline_repo(tmp_path)
    origin = tmp_path / "origin.git"
    sh(tmp_path, "git", "clone", "-q", "--bare", str(repo), str(origin))
    sh(repo, "git", "remote", "add", "origin", str(origin))
    sh(repo, "git", "fetch", "-q", "origin")
    (repo / "dirty.txt").write_text("the owner's work in progress\n")  # the main checkout has edits: install must not touch it
    # origin/develop moves past the checkout's HEAD: the runtime must be at origin's tip, not at HEAD
    other = tmp_path / "other"
    sh(tmp_path, "git", "clone", "-q", str(origin), str(other))
    sh(other, "git", "config", "user.email", "t@t")
    sh(other, "git", "config", "user.name", "t")
    (other / "pipeline" / "newer.txt").write_text("x\n")
    sh(other, "git", "add", "-A")
    sh(other, "git", "commit", "-q", "-m", "newer pipeline")
    sh(other, "git", "push", "-q", "origin", "HEAD:develop")
    tip = sh(other, "git", "rev-parse", "HEAD").strip()
    head, status = sh(repo, "git", "rev-parse", "HEAD").strip(), sh(repo, "git", "status", "--porcelain")
    assert head != tip

    fake_home = tmp_path / "fakehome"
    monkeypatch.setenv("HOME", str(fake_home))
    home().mkdir(parents=True, exist_ok=True)
    (home() / "config.toml").write_text('remote = "origin"\n')
    monkeypatch.chdir(repo)
    lc = Launchctl()
    monkeypatch.setattr(selfupdate, "real_sync", noop_sync)
    monkeypatch.setattr(selfupdate, "real_launchctl", lc)

    result = CliRunner().invoke(main, ["daemon", "install"])
    assert result.exit_code == 0, result.output

    current = selfupdate.link("current")
    assert current is not None and (current / ".complete").read_text().strip() == tip
    assert (current / "pipeline" / "newer.txt").exists()
    plist = plistlib.loads((fake_home / "Library" / "LaunchAgents" / f"{selfupdate.LABEL}.plist").read_bytes())
    assert plist["ProgramArguments"][0] == str(selfupdate.current_shim())
    assert plist["WorkingDirectory"] == str(repo)
    assert any(c[0] == "bootstrap" for c in lc.calls)
    assert sh(repo, "git", "rev-parse", "HEAD").strip() == head and sh(repo, "git", "status", "--porcelain") == status
    assert sh(repo, "git", "rev-parse", "--abbrev-ref", "HEAD").strip() == "develop"


def test_status_prints_the_active_batch_and_the_abandoned_one() -> None:
    landing = {"batch": {"number": 8, "phase": "building", "age_s": 11 * 60, "members": [59, 76, 77], "pr_number": None, "slow": True},
               "last_abandoned": {"number": 7, "state": "abandoned", "reason": "develop moved with overlapping changes",
                                  "ended": 1.0, "ago_s": 18 * 60},
               "next_batch_in_s": None}
    assert landing_lines(landing) == ["batch 8: building · age 11m · #59 #76 #77 · SLOW",
                                      "batch 7 abandoned 18m ago: develop moved with overlapping changes"]
    assert landing_lines({"batch": None, "last_abandoned": None, "next_batch_in_s": 45}) == ["no batch yet: the next one starts in 45s"]
    assert landing_lines({}) == []


def test_daemon_run_holds_off_idle_sleep(monkeypatch: pytest.MonkeyPatch) -> None:
    from starpipe import cli

    calls: list[list[str]] = []
    monkeypatch.setattr(cli.subprocess, "Popen", lambda argv, **_kw: calls.append(argv))
    cli._hold_off_idle_sleep()
    assert calls == [["caffeinate", "-i", "-w", str(os.getpid())]]

    def missing(*_a: Any, **_kw: Any) -> None:
        raise FileNotFoundError
    monkeypatch.setattr(cli.subprocess, "Popen", missing)
    cli._hold_off_idle_sleep()  # no caffeinate: not an error
