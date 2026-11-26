"""Every suite in .mason/mason.toml that calls `uv` must stay on this Mac (task #1163): a node's job PATH may lack uv."""

import re
import tomllib
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
UV = re.compile(r"(?:^|[\s;&|(])uv\s+(?:run|sync|tool|pip)\b")


def _uv_suites() -> dict[str, dict[str, Any]]:
    data = tomllib.loads((ROOT / ".mason/mason.toml").read_text())
    return {
        name: suite
        for name, suite in data["suite"].items()
        if any(isinstance(v, str) and UV.search(v) for v in suite.values())
    }


def test_the_known_uv_suites_are_found() -> None:
    assert {"t0-pipeline-static", "test-pipeline"} <= _uv_suites().keys()


def test_every_uv_suite_stays_local() -> None:
    offenders = [name for name, suite in _uv_suites().items() if suite.get("remote") is not False]
    assert not offenders, f"suites that call uv without `remote = false`: {offenders}"
