from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from starpipe import adapter_star as star

HOOK = Path(__file__).resolve().parents[1] / "hooks" / "heavy_wrap.py"


def run(command: str, env: dict[str, str] | None = None) -> dict[str, object] | None:
    import os
    done = subprocess.run([sys.executable, str(HOOK)], input=json.dumps({"tool_input": {"command": command}}),
                          capture_output=True, text=True, check=True, env={**os.environ, **(env or {})})
    return json.loads(done.stdout) if done.stdout.strip() else None


def test_swift_test_is_wrapped() -> None:
    out = run("cd StarCore && swift test --filter X")
    assert out is not None
    updated = out["hookSpecificOutput"]["updatedInput"]["command"]  # type: ignore[index]
    assert "heavy -- bash -c" in updated and "swift test --filter X" in updated


def test_mentioning_a_heavy_command_is_not_running_it() -> None:
    assert run("grep -rn 'swift test' docs/") is None
    assert run("git log --grep xcodebuild") is None


def test_already_wrapped_and_disabled_are_left_alone() -> None:
    assert run("pipeline/bin/starpipe heavy -- swift build") is None
    assert run("swift build", {"STARPIPE_NO_WRAP": "1"}) is None


def test_hook_and_adapter_patterns_agree() -> None:
    import re
    src = HOOK.read_text()
    pattern = re.search(r'HEAVY = re.compile\(\n(.*?)\n\)', src, re.DOTALL)
    assert pattern is not None
    for cmd in ("swift build", "x && ./gradlew test", "xcodebuild test", ".build/release/stard --scratch /x",
                "ls", "echo swift test"):
        hook_hit = run(cmd) is not None
        assert hook_hit == bool(star.HEAVY_PATTERN.search(cmd)), cmd
