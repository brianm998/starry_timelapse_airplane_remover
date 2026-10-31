"""The negative control (plan §8.3): a new test must fail on the merge-base with only its test files overlaid."""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from . import gitutil, heavy

# (argv, cwd) -> (exit code, combined output)
CommandRunner = Callable[[list[str], Path], tuple[int, str]]


@dataclass
class Control:
    test: str
    verdict: str  # discriminates | red-by-compile | passes-on-base | unsupported
    detail: str = ""

    @property
    def bad(self) -> bool:
        return self.verdict == "passes-on-base"


def heavy_runner(argv: list[str], cwd: Path) -> tuple[int, str]:
    with tempfile.TemporaryFile() as out:
        code, _ = heavy.run(argv, cwd=str(cwd), stdout=out.fileno())
        out.seek(0)
        return code, out.read().decode(errors="replace")


def _package_dir(root: Path, path: str) -> Path | None:
    p = (root / path).parent
    while p != root and p != p.parent:
        if (p / "Package.swift").exists():
            return p
        p = p.parent
    return None


def is_test_file(path: str) -> bool:
    return "/Tests/" in path or path.startswith("Tests/") or "/GherkinTests/" in path


def run(worktree: Path, base_ref: str, new_tests: list[str], runner: CommandRunner = heavy_runner) -> list[Control]:
    """One verdict per named new test. Swift packages only: other kinds are reported unsupported, not skipped silently."""
    if not new_tests:
        return []
    mb = gitutil.merge_base(worktree, base_ref)
    changed = [p for p in gitutil.git(worktree, "diff", "--name-only", f"{mb}...HEAD").splitlines() if is_test_file(p)]
    scratch = Path(tempfile.mkdtemp(prefix="starpipe-nc-"))
    wt = scratch / "base"
    controls: list[Control] = []
    try:
        gitutil.git(worktree, "worktree", "add", "--detach", str(wt), mb)
        for rel in changed:  # overlay only the test files, taken from the branch
            src, dst = worktree / rel, wt / rel
            if src.exists():
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst)
        for rel in ("opencv/include", "opencv/lib", "opencv/opencv2.framework", "StarDecisionTrees/include",
                    "StarDecisionTrees/lib", "external_binaries/bin"):
            if (worktree / rel).exists() and not (wt / rel).exists():
                (wt / rel).parent.mkdir(parents=True, exist_ok=True)
                (wt / rel).symlink_to((worktree / rel).resolve())
        for name in new_tests:
            owner = next((p for p in changed if name.split("/")[-1].split(".")[-1] in (worktree / p).read_text(errors="replace")
                          and p.endswith(".swift")), None)
            pkg = _package_dir(wt, owner) if owner else None
            if pkg is None:
                controls.append(Control(name, "unsupported", "not a swift test, or its package was not found"))
                continue
            code, output = runner(["swift", "test", "--filter", name], pkg)
            if code == 0:
                controls.append(Control(name, "passes-on-base", "the test passed on the merge-base without the change"))
            elif "error:" in output and "Executed" not in output and "Test run with" not in output:
                controls.append(Control(name, "red-by-compile", "does not compile against the base"))
            else:
                controls.append(Control(name, "discriminates"))
    finally:
        for rel in ("opencv/include", "opencv/lib", "opencv/opencv2.framework", "StarDecisionTrees/include",
                    "StarDecisionTrees/lib", "external_binaries/bin"):
            if (wt / rel).is_symlink():
                (wt / rel).unlink()
        subprocess.run(["git", "-C", str(worktree), "worktree", "remove", "--force", str(wt)], capture_output=True, check=False)
        shutil.rmtree(scratch, ignore_errors=True)
    return controls
