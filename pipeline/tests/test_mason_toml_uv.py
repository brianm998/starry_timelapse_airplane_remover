"""Every suite in .mason/mason.toml that runs uv must stay off MASON nodes, which may lack it (task #1159)."""

import re
import tomllib
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
UV = re.compile(r"\buv\b")


def _uv_suites() -> dict[str, dict[str, Any]]:
    suites: dict[str, dict[str, Any]] = tomllib.loads((ROOT / ".mason/mason.toml").read_text())["suite"]
    return {
        name: suite
        for name, suite in suites.items()
        if any(UV.search(suite.get(k, "")) for k in ("command", "narrow_command"))
    }


def test_mason_toml_has_uv_suites() -> None:
    assert {"t0-pipeline-static", "test-pipeline"} <= _uv_suites().keys()


def test_every_uv_suite_stays_local() -> None:
    remote = [name for name, suite in _uv_suites().items() if suite.get("remote") is not False]
    assert not remote, f"uv suites without `remote = false`: {remote}"
