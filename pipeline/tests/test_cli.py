from __future__ import annotations

import subprocess
from pathlib import Path

from click.testing import CliRunner

from starpipe.cli import main


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
