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
from starpipe.cli import landing_lines, main, update_hold_line
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

    hold_off = getattr(cli, "_hold_off_idle_sleep")  # noqa: B009 - private on purpose
    calls: list[list[str]] = []

    def record(argv: list[str], **_kw: Any) -> None:
        calls.append(argv)
    monkeypatch.setattr(cli.subprocess, "Popen", record)
    hold_off()
    assert calls == [["caffeinate", "-i", "-w", str(os.getpid())]]

    def missing(*_a: Any, **_kw: Any) -> None:
        raise FileNotFoundError
    monkeypatch.setattr(cli.subprocess, "Popen", missing)
    hold_off()  # no caffeinate: not an error


def test_status_says_when_a_self_update_holds_claims(monkeypatch: pytest.MonkeyPatch) -> None:
    hold = {"sha": "e3c559f6aabbccdd", "left_s": 7 * 60 + 5, "waiting_on": [73]}
    assert update_hold_line(hold) == "self-update to e3c559f6 pending: holding new work, waiting on #73, swaps in 7m"
    assert update_hold_line({**hold, "waiting_on": [73, 74], "left_s": 40}) == (
        "self-update to e3c559f6 pending: holding new work, waiting on #73 #74, swaps in 40s")
    assert update_hold_line(None) is None

    class FakeClient:
        def __init__(self, hold: dict[str, object] | None) -> None:
            self.hold = hold

        def call(self, _method: str, _path: str) -> dict[str, object]:
            return {"daemon": {"pid": 1, "error": None}, "self_update": {"pending": "e3c559f6", "hold": self.hold}, "tickets": []}

    for h, shown in ((hold, True), (None, False)):
        monkeypatch.setattr("starpipe.cli._client", lambda h=h: FakeClient(h))  # type: ignore[misc]
        out = CliRunner().invoke(main, ["status"])
        assert out.exit_code == 0 and ("self-update to e3c559f6 pending" in out.output) is shown


class FakeDaemon:
    def __init__(self, result: str = "ok") -> None:
        self.calls: list[tuple[str, str, dict[str, Any] | None]] = []
        self.result = result

    def call(self, method: str, path: str, body: dict[str, Any] | None = None) -> Any:
        self.calls.append((method, path, body))
        return {"result": self.result}


def test_block_adds_links_to_an_existing_ticket(monkeypatch: pytest.MonkeyPatch) -> None:
    from starpipe import github

    from .fakes import FakeGitHub

    gh = FakeGitHub()
    for n in (7, 174, 199):
        gh.add_issue(n, f"ticket {n}")
    gh.add_issue(50, "not a pipeline ticket", labels=())
    monkeypatch.setattr(github, "GitHub", lambda _cfg: gh)  # pyright: ignore[reportUnknownLambdaType, reportUnknownArgumentType]
    run = CliRunner()
    out = run.invoke(main, ["block", "7", "#174,199"])
    assert out.exit_code == 0, out.output
    assert gh.deps[7] == [174, 199]
    assert run.invoke(main, ["block", "7", "174"]).exit_code == 0 and gh.deps[7] == [174, 199], "an existing link is not added twice"
    assert run.invoke(main, ["block", "7", "7"]).exit_code != 0, "a ticket cannot block itself"
    assert run.invoke(main, ["block", "174", "7"]).exit_code != 0, "7 is blocked by 174: the reverse link would close a cycle"
    assert run.invoke(main, ["block", "50", "7"]).exit_code != 0, "not a pipeline ticket"
    out = run.invoke(main, ["unblock", "7", "174"])
    assert out.exit_code == 0, out.output
    assert gh.deps[7] == [199]
    assert run.invoke(main, ["unblock", "7", "174"]).exit_code != 0, "no such link"


def test_retry_without_the_flag_is_unchanged(monkeypatch: pytest.MonkeyPatch) -> None:
    from starpipe import cli

    daemon = FakeDaemon("note: #7 is still blocked by #174; retried anyway")
    monkeypatch.setattr(cli, "_client", lambda: daemon)
    out = CliRunner().invoke(main, ["retry", "7", "ci"])
    assert out.exit_code == 0 and "still blocked by #174" in out.output, out.output
    assert daemon.calls == [("POST", "/v1/tickets/7/retry", {"stage": "ci"})], "no when_unblocked unless asked for"

    daemon.result = "ok"
    out = CliRunner().invoke(main, ["retry", "7", "ci", "--when-unblocked"])
    assert out.exit_code == 0 and out.output.strip() == "ok"
    assert daemon.calls[-1] == ("POST", "/v1/tickets/7/retry", {"stage": "ci", "when_unblocked": True})
