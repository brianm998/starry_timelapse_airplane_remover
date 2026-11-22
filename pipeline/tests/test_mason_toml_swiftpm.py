"""Every swift build/test in .mason/mason.toml and shards.py must disable SwiftPM's build-manifest caching (task #985)."""

import re
import tomllib
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
FLAG = "--disable-build-manifest-caching"
SWIFT = re.compile(r"swift (build|test)\b")


def _commands() -> list[tuple[str, str]]:
    data = tomllib.loads((ROOT / ".mason/mason.toml").read_text())
    found: list[tuple[str, str]] = []

    def walk(node: Any, path: str) -> None:
        if isinstance(node, dict):
            for k, v in node.items():  # pyright: ignore[reportUnknownVariableType]
                if k in ("command", "narrow_command") and isinstance(v, str) and SWIFT.search(v):
                    found.append((f"{path}.{k}", v))
                else:
                    walk(v, f"{path}.{k}")  # pyright: ignore[reportUnknownArgumentType]
        elif isinstance(node, list):
            for i, v in enumerate(node):  # pyright: ignore[reportUnknownVariableType,reportUnknownArgumentType]
                walk(v, f"{path}[{i}]")

    walk(data, "")
    return found


def test_mason_toml_has_swift_commands() -> None:
    assert len(_commands()) >= 15


def test_every_swift_command_disables_manifest_caching() -> None:
    missing = [p for p, c in _commands() if FLAG not in c]
    assert not missing, f"swift commands without {FLAG}: {missing}"


def test_shards_swift_calls_carry_flag() -> None:
    src = (ROOT / ".mason/scripts/shards.py").read_text()
    assert f'SWIFTPM_FLAGS = ["{FLAG}"]' in src
    calls = re.findall(r'\["swift",[^\]]*\]', src)
    assert len(calls) == 3
    assert all("SWIFTPM_FLAGS" in c for c in calls)
