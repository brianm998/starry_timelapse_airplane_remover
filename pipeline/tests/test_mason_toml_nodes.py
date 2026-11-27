"""Suites that need artifacts or tools only this Mac has stay off MASON nodes (task #1175)."""

import re
import tomllib
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
# Gitignored artifacts link-artifacts.sh takes from the main checkout: a package needs them if it is,
# or depends on, one of these.
ARTIFACT_PACKAGES = {"StarCpp", "StarDecisionTrees"}
LOCAL_DEP = re.compile(r'\.package\(\s*(?:name:\s*"[^"]+",\s*)?path:\s*"([^"]+)"')


def _suites() -> dict[str, dict[str, Any]]:
    return tomllib.loads((ROOT / ".mason/mason.toml").read_text())["suite"]


def _needs_artifacts(package: Path) -> bool:
    if package.name in ARTIFACT_PACKAGES:
        return True
    manifest = package / "Package.swift"
    code = "\n".join(line for line in manifest.read_text().splitlines() if not line.lstrip().startswith("//"))
    return any(_needs_artifacts((package / dep).resolve()) for dep in LOCAL_DEP.findall(code))


def _reason(command: str) -> str | None:
    if "JAVA_HOME=" in command:
        return "Android Studio's JAVA_HOME"
    if "xcodebuild" in command:
        return "the signing identity"
    for package in re.findall(r"--package-path (\S+)", command):
        if _needs_artifacts(ROOT / package):
            return "linked OpenCV/StarDecisionTrees"
    return None


def _local_only() -> dict[str, str]:
    return {name: why for name, s in _suites().items() if (why := _reason(s["command"]))}


def test_the_expected_suites_are_found() -> None:
    assert set(_local_only()) == {
        "t0-proto-sync", "build-desktop", "test-desktop", "build-gui", "test-gui",
        "build-StarCpp", "build-StarCore", "build-cli", "build-daemon", "build-trail_tools",
        "build-decision_tree_generator", "test-StarCpp", "test-StarCpp-qos", "test-StarCpp-wgpu",
        "test-StarCore", "test-daemon", "test-cli", "test-trail_tools", "test-decision_tree_generator",
    }  # fmt: skip


def test_suites_needing_this_mac_are_not_remote() -> None:
    suites = _suites()
    placeable = {n: why for n, why in _local_only().items() if suites[n].get("remote") is not False}
    assert not placeable, f"add `remote = false` to these suites (what a node lacks): {placeable}"


def test_suites_running_uv_are_not_remote() -> None:
    """A node may lack uv (exit 127, task #1165): suites that call it stay on this Mac."""
    placeable = [n for n, s in _suites().items() if re.search(r"\buv\b", s["command"]) and s.get("remote") is not False]
    assert not placeable, f"add `remote = false` to these suites (nodes may have no uv): {placeable}"
