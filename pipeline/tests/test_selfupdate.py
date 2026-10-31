from __future__ import annotations

import json
import plistlib
import subprocess
from pathlib import Path

import pytest
from click.testing import CliRunner

from starpipe import cli, selfupdate
from starpipe.config import Config, home
from starpipe.daemon import Daemon

from .fakes import sh
from .test_engine import Rig
from .test_ship import ready_ticket


def make_pipeline_repo(tmp: Path, salt: str = "") -> tuple[Path, str]:
    """A repo whose pipeline/ looks enough like the real one for `build`: a shim, a project file, and a monitor to leave out."""
    repo = tmp / "src-repo"
    sh(tmp, "git", "init", "-q", "-b", "develop", str(repo))
    sh(repo, "git", "config", "user.email", "t@t")
    sh(repo, "git", "config", "user.name", "t")
    (repo / "pipeline" / "bin").mkdir(parents=True)
    (repo / "pipeline" / "bin" / "starpipe").write_text("#!/bin/bash\necho starpipe\n")
    (repo / "pipeline" / "bin" / "starpipe").chmod(0o755)
    (repo / "pipeline" / "pyproject.toml").write_text("[project]\nname='x'\n")
    (repo / "pipeline" / "monitor").mkdir()
    (repo / "pipeline" / "monitor" / "Package.swift").write_text("// big and not needed by the daemon\n")
    (repo / "README.md").write_text("not part of the runtime\n")
    (repo / "pipeline" / "salt.txt").write_text(salt)  # two repos made in the same second must not share a commit sha
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-q", "-m", "pipeline")
    return repo, sh(repo, "git", "rev-parse", "HEAD").strip()


def fake_plist(tmp: Path, program: str = "/old/checkout/pipeline/bin/starpipe") -> Path:
    path = tmp / "agent.plist"
    path.write_bytes(plistlib.dumps({"Label": selfupdate.LABEL, "ProgramArguments": [program, "daemon", "run"]}))
    return path


class Launchctl:
    """A launchctl that behaves like the real one where it matters: bootout takes a moment, and bootstrap fails (exit 5, I/O
    error) while the job is still loaded. `slow_unload` is how many `print` polls still find it after the bootout."""

    def __init__(self, slow_unload: int = 0, bootstrap_always_fails: bool = False) -> None:
        self.calls: list[list[str]] = []
        self.loaded = True
        self.pending_unload = 0
        self.slow_unload = slow_unload
        self.fails = bootstrap_always_fails

    def __call__(self, args: list[str]) -> int:
        self.calls.append(args)
        verb = args[0]
        if verb == "bootout":
            self.pending_unload = self.slow_unload
            if self.slow_unload == 0:
                self.loaded = False
            return 0
        if verb == "print":
            if self.pending_unload > 0:
                self.pending_unload -= 1
                if self.pending_unload == 0:
                    self.loaded = False
                return 0
            return 0 if self.loaded else 113
        if verb == "bootstrap":
            if self.fails or self.loaded:
                return 5
            self.loaded = True
            return 0
        return 0 if verb == "kickstart" else 1


def ok_test(_rt: Path) -> tuple[bool, str]:
    return True, "ok"


def noop_sync(rt: Path) -> None:
    (rt / "pipeline" / ".venv").mkdir()


def test_a_runtime_is_the_pipeline_directory_at_one_commit_without_the_monitor(tmp_path: Path) -> None:
    repo, sha = make_pipeline_repo(tmp_path)
    syncs: list[Path] = []
    rt = selfupdate.build(repo, sha, lambda r: syncs.append(r) or noop_sync(r))  # type: ignore[func-returns-value]
    assert rt == selfupdate.runtime_dir(sha) and (rt / ".complete").read_text().strip() == sha
    assert (rt / "pipeline" / "bin" / "starpipe").exists() and (rt / "pipeline" / "pyproject.toml").exists()
    assert not (rt / "pipeline" / "monitor").exists() and not (rt / "README.md").exists()
    assert selfupdate.build(repo, sha, lambda r: syncs.append(r)) == rt and len(syncs) == 1, "built once, then reused"


def test_a_failed_build_leaves_nothing_behind(tmp_path: Path) -> None:
    repo, sha = make_pipeline_repo(tmp_path)

    def broken(_rt: Path) -> None:
        raise subprocess.CalledProcessError(1, "uv sync")

    with pytest.raises(subprocess.CalledProcessError):
        selfupdate.build(repo, sha, broken)
    assert not selfupdate.runtime_dir(sha).exists()


def test_a_commit_without_a_pipeline_is_refused(tmp_path: Path) -> None:
    repo = tmp_path / "empty"
    sh(tmp_path, "git", "init", "-q", "-b", "develop", str(repo))
    sh(repo, "git", "config", "user.email", "t@t")
    sh(repo, "git", "config", "user.name", "t")
    (repo / "pipeline").mkdir()
    (repo / "pipeline" / "x").write_text("x")
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-q", "-m", "no shim")
    with pytest.raises(RuntimeError, match="not a pipeline commit"):
        selfupdate.build(repo, sh(repo, "git", "rev-parse", "HEAD").strip(), noop_sync)


def test_the_self_test_passes_in_the_environment_that_runs_this_suite() -> None:
    """For real: every starpipe module imports, config and the database open, the SDK's CLI and the stage prompts are present."""
    assert selfupdate.self_test_in_process() == []
    result = CliRunner().invoke(cli.main, ["daemon", "self-test"])
    assert result.exit_code == 0 and result.output.strip().endswith("ok")


def test_the_first_switch_repoints_launchd_and_later_ones_only_flip_the_symlink(tmp_path: Path) -> None:
    repo, sha = make_pipeline_repo(tmp_path)
    plist, lc = fake_plist(tmp_path), Launchctl()
    first = selfupdate.build(repo, sha, noop_sync)
    selfupdate.switch(first, plist, lc, now=100.0, sleep=lambda _s: None)
    assert selfupdate.link("current") == first.resolve() and selfupdate.link("previous") is None
    program = plistlib.loads(plist.read_bytes())["ProgramArguments"]
    assert program == [str(selfupdate.current_shim()), "daemon", "run"], "launchd now follows the `current` symlink"
    assert [c[0] for c in lc.calls if c[0] != "print"] == ["bootout", "bootstrap"]

    (tmp_path / "src-repo" / "pipeline" / "new.txt").write_text("v2")
    sh(tmp_path / "src-repo", "git", "add", "-A")
    sh(tmp_path / "src-repo", "git", "commit", "-q", "-m", "v2")
    second = selfupdate.build(repo, sh(repo, "git", "rev-parse", "HEAD").strip(), noop_sync)
    lc.calls.clear()
    selfupdate.switch(second, plist, lc, now=200.0)
    assert selfupdate.link("current") == second.resolve() and selfupdate.link("previous") == first.resolve()
    assert [c[0] for c in lc.calls] == ["kickstart"], "no plist change, so no re-bootstrap: safe from inside the daemon"
    assert plistlib.loads(plist.read_bytes())["ProgramArguments"][0] == str(selfupdate.current_shim())


def test_update_builds_tests_and_switches_when_idle(tmp_path: Path) -> None:
    repo, sha = make_pipeline_repo(tmp_path)
    plist, lc = fake_plist(tmp_path), Launchctl()
    report = selfupdate.update(repo, "develop", plist, sessions=lambda: 0, sync=noop_sync, test=ok_test, launchctl=lc)
    assert report.switched and report.sha == sha and selfupdate.link("current") == selfupdate.runtime_dir(sha).resolve()
    again = selfupdate.update(repo, "develop", plist, sessions=lambda: 0, sync=noop_sync, test=ok_test, launchctl=lc)
    assert not again.switched and "already running" in again.detail


def test_update_does_not_switch_to_a_runtime_that_fails_its_self_test(tmp_path: Path) -> None:
    repo, _ = make_pipeline_repo(tmp_path)
    plist, lc = fake_plist(tmp_path), Launchctl()
    report = selfupdate.update(repo, "develop", plist, sessions=lambda: 0, sync=noop_sync,
                               test=lambda _rt: (False, "import starpipe.x: boom"), launchctl=lc)
    assert report.tested is False and not report.switched and "boom" in report.detail
    assert selfupdate.link("current") is None and lc.calls == []


def test_a_dry_run_builds_and_tests_but_does_not_switch(tmp_path: Path) -> None:
    repo, _ = make_pipeline_repo(tmp_path)
    lc = Launchctl()
    report = selfupdate.update(repo, "develop", fake_plist(tmp_path), sessions=lambda: 0, sync=noop_sync, test=ok_test,
                               dry_run=True, launchctl=lc)
    assert report.built and report.tested and not report.switched and selfupdate.link("current") is None and lc.calls == []


def test_update_waits_for_the_sessions_to_finish_and_gives_up_after_the_wait(tmp_path: Path) -> None:
    repo, _ = make_pipeline_repo(tmp_path)
    plist, lc = fake_plist(tmp_path), Launchctl()
    counts = iter([2, 1, 0])
    clock = {"t": 0.0}

    def sleep(s: float) -> None:
        clock["t"] += s

    ok = selfupdate.update(repo, "develop", plist, sessions=lambda: next(counts), sync=noop_sync, test=ok_test, launchctl=lc,
                           sleep=sleep, clock=lambda: clock["t"])
    assert ok.switched and clock["t"] == 20.0, "it polled until the sessions were gone"

    (tmp_path / "again").mkdir()
    repo2, _ = make_pipeline_repo(tmp_path / "again", salt="second")
    stuck = selfupdate.update(repo2, "develop", fake_plist(tmp_path / "again"), sessions=lambda: 3, sync=noop_sync, test=ok_test,
                              launchctl=lc, wait_s=60, sleep=sleep, clock=lambda: clock["t"])
    assert not stuck.switched and "3 stage session(s) still running" in stuck.detail
    forced = selfupdate.update(repo2, "develop", fake_plist(tmp_path / "again"), sessions=lambda: 3, sync=noop_sync, test=ok_test,
                               launchctl=lc, now=True)
    assert forced.switched


def test_rollback_returns_to_the_previous_runtime_and_a_second_rollback_undoes_it(tmp_path: Path) -> None:
    repo, sha1 = make_pipeline_repo(tmp_path)
    plist, lc = fake_plist(tmp_path), Launchctl()
    first = selfupdate.build(repo, sha1, noop_sync)
    selfupdate.switch(first, plist, lc, now=1.0)
    with pytest.raises(RuntimeError, match="no previous runtime"):
        selfupdate.rollback(plist, lc)
    (repo / "pipeline" / "v2").write_text("2")
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-q", "-m", "v2")
    second = selfupdate.build(repo, sh(repo, "git", "rev-parse", "HEAD").strip(), noop_sync)
    selfupdate.switch(second, plist, lc, now=2.0)
    assert selfupdate.rollback(plist, lc, clock=lambda: 3.0) == first.name
    assert selfupdate.link("current") == first.resolve() and selfupdate.link("previous") == second.resolve()
    selfupdate.rollback(plist, lc, clock=lambda: 4.0)
    assert selfupdate.link("current") == second.resolve()


def test_three_restarts_after_a_switch_are_a_crash_loop(tmp_path: Path) -> None:
    repo, sha = make_pipeline_repo(tmp_path)
    plist, lc = fake_plist(tmp_path), Launchctl()
    first = selfupdate.build(repo, sha, noop_sync)
    selfupdate.switch(first, plist, lc, now=1000.0)
    (repo / "pipeline" / "v2").write_text("2")
    sh(repo, "git", "add", "-A")
    sh(repo, "git", "commit", "-q", "-m", "v2")
    selfupdate.switch(selfupdate.build(repo, sh(repo, "git", "rev-parse", "HEAD").strip(), noop_sync), plist, lc, now=2000.0)

    assert not selfupdate.crash_loop(2001.0)
    for t in (2001.0, 2030.0, 2060.0):
        selfupdate.record_start(t)
    assert not selfupdate.crash_loop(2061.0), "three starts: the first is the normal one after the switch"
    selfupdate.record_start(2090.0)
    assert selfupdate.crash_loop(2091.0)
    assert not selfupdate.crash_loop(2000.0 + selfupdate.CRASH_WINDOW_S + 1), "after the window it is not a switch problem"


def test_without_a_previous_runtime_there_is_nothing_to_roll_back_to(tmp_path: Path) -> None:
    repo, sha = make_pipeline_repo(tmp_path)
    selfupdate.switch(selfupdate.build(repo, sha, noop_sync), fake_plist(tmp_path), Launchctl(), now=1.0)
    for t in (2.0, 3.0, 4.0, 5.0):
        selfupdate.record_start(t)
    assert not selfupdate.crash_loop(6.0)


def test_record_start_is_a_no_op_before_any_runtime_exists() -> None:
    assert not (home() / "runtime").exists()
    selfupdate.record_start(1.0)
    assert not (home() / "runtime").exists()


# the daemon's side -------------------------------------------------------------------------------------------------
async def test_a_landing_that_changes_pipeline_marks_the_daemon_for_an_update(tmp_path: Path) -> None:
    rig = Rig(tmp_path)
    ready_ticket(rig, 1, "thing.py", "x = 1\n", folder="pipeline/src")
    await rig.engine.drive(1)
    assert rig.state(1) == "landed" and rig.db.get("self_update_wanted")


async def test_docs_and_monitor_only_landings_do_not(tmp_path: Path) -> None:
    rig = Rig(tmp_path)
    ready_ticket(rig, 1, "a.md", "x\n")
    ready_ticket(rig, 2, "App.swift", "// x\n", folder="pipeline/monitor/Sources")
    await rig.engine.drive(1)
    await rig.engine.drive(2)
    assert rig.state(1) == "landed" and rig.state(2) == "landed" and rig.db.get("self_update_wanted") is None


def test_auto_update_is_off_unless_enabled_and_waits_for_idle(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    rig = Rig(tmp_path)
    calls: list[str] = []

    def fake_update(*_a: object, **_k: object) -> None:
        calls.append("update")

    monkeypatch.setattr(selfupdate, "update", fake_update)
    rig.db.put("self_update_wanted", "abc")
    off = Daemon(rig.engine, Config(), token="t")
    assert off.auto_update_once(tmp_path / "p.plist") is None and calls == []

    on = Daemon(rig.engine, Config(auto_self_update=True), token="t")
    rig.db.begin_stage(1, "develop", 1, "sonnet")  # a stage is mid-session: not idle
    rig.gh.add_issue(1, "t")
    assert on.auto_update_once(tmp_path / "p.plist") is None and calls == []
    rig.db.end_stage(rig.db.running_stages()[0]["id"], "accepted")
    assert on.auto_update_once(tmp_path / "p.plist") == "updated" and calls == ["update"]
    assert rig.db.get("self_update_wanted") is None


def test_a_failed_auto_update_pages_once_and_does_not_retry(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    rig = Rig(tmp_path)

    def boom(*_a: object, **_k: object) -> None:
        raise RuntimeError("uv sync failed")

    monkeypatch.setattr(selfupdate, "update", boom)
    rig.db.put("self_update_wanted", "abcdef1234")
    d = Daemon(rig.engine, Config(auto_self_update=True), token="t")
    assert (d.auto_update_once(tmp_path / "p.plist") or "").startswith("failed")
    assert rig.db.get("self_update_wanted") is None
    assert any(t == "star pipeline: self-update-failed" for t, _ in rig.pages)


async def test_the_runtime_endpoint_reports_running_sessions_and_the_pinned_runtimes(tmp_path: Path) -> None:
    from aiohttp.test_utils import TestClient, TestServer

    rig = Rig(tmp_path)
    rig.gh.add_issue(1, "t")
    rig.engine.sync_issues()
    rig.db.begin_stage(1, "develop", 1, "sonnet")
    client = TestClient(TestServer(Daemon(rig.engine, Config(), token="tok").app()))
    await client.start_server()
    try:
        data = await (await client.get("/v1/runtime", headers={"Authorization": "Bearer tok"})).json()
        assert data["sessions"] == 1 and data["current"] is None and data["previous"] is None
    finally:
        await client.close()


def test_the_runtime_command_says_when_nothing_is_pinned() -> None:
    result = CliRunner().invoke(cli.main, ["runtime"])
    assert result.exit_code == 0 and "the daemon runs from the checkout" in result.output
    assert json.dumps({"current": "-"})  # the output format is for people; nothing else parses it


def test_a_slow_bootout_is_waited_out_before_bootstrapping(tmp_path: Path) -> None:
    """The bug that took the live daemon down: bootstrap straight after bootout fails while the job is still loaded."""
    repo, sha = make_pipeline_repo(tmp_path)
    lc = Launchctl(slow_unload=3)
    slept: list[float] = []
    selfupdate.switch(selfupdate.build(repo, sha, noop_sync), fake_plist(tmp_path), lc, now=1.0, sleep=slept.append)
    verbs = [c[0] for c in lc.calls]
    assert verbs[0] == "bootout" and verbs[-1] == "bootstrap" and verbs.count("bootstrap") == 1, "bootstrapped once, after it unloaded"
    assert verbs.count("print") >= 3 and lc.loaded and slept


def test_a_bootstrap_that_never_works_is_an_error_not_a_silent_dead_daemon(tmp_path: Path) -> None:
    repo, sha = make_pipeline_repo(tmp_path)
    lc = Launchctl(bootstrap_always_fails=True)
    with pytest.raises(RuntimeError, match="the daemon is NOT loaded"):
        selfupdate.switch(selfupdate.build(repo, sha, noop_sync), fake_plist(tmp_path), lc, now=1.0, sleep=lambda _s: None)
    assert [c[0] for c in lc.calls].count("bootstrap") == 10


def test_a_failed_kickstart_is_an_error_too(tmp_path: Path) -> None:
    repo, sha = make_pipeline_repo(tmp_path)
    plist = fake_plist(tmp_path, str(selfupdate.current_shim()))  # already pointing at `current`: only a kickstart is needed
    with pytest.raises(RuntimeError, match="kickstart"):
        selfupdate.switch(selfupdate.build(repo, sha, noop_sync), plist, lambda _a: 1, now=1.0, sleep=lambda _s: None)


def test_the_shim_resolves_symlinks_so_one_runtime_supplies_the_code_and_the_environment(tmp_path: Path) -> None:
    """launchd runs the shim through the `current` symlink. `uv run --project <symlink>` mixed the new runtime's code with the old
    one's virtualenv (seen live), so the shim must hand uv the physical directory."""
    real = tmp_path / "runtime-abc123" / "pipeline"
    (real / "bin").mkdir(parents=True)
    shim = real / "bin" / "starpipe"
    shim.write_text((Path(__file__).resolve().parents[1] / "bin" / "starpipe").read_text())
    shim.chmod(0o755)
    (tmp_path / "current").symlink_to(tmp_path / "runtime-abc123")
    fake_bin = tmp_path / "fakebin"
    fake_bin.mkdir()
    (fake_bin / "uv").write_text('#!/bin/sh\necho "$@"\n')
    (fake_bin / "uv").chmod(0o755)
    out = subprocess.run([str(tmp_path / "current" / "pipeline" / "bin" / "starpipe"), "daemon", "run"], capture_output=True,
                         text=True, check=True, env={"PATH": f"{fake_bin}:/usr/bin:/bin"}).stdout
    assert f"--project {(tmp_path / 'runtime-abc123' / 'pipeline').resolve()}" in out
    assert "current" not in out and out.strip().endswith("starpipe daemon run")
