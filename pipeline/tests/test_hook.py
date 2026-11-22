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


GUI_UNSIGNED = ("xcodebuild -project gui/star.xcodeproj -scheme star -configuration Debug "
                "CODE_SIGNING_ALLOWED=NO test -only-testing:starTests/X")


def wrapped_command(out: dict[str, object] | None) -> str:
    assert out is not None
    return out["hookSpecificOutput"]["updatedInput"]["command"]  # type: ignore[index,return-value]


def test_unsigned_gui_test_is_rewritten_to_the_signing_wrapper() -> None:
    cmd = wrapped_command(run(GUI_UNSIGNED, {"STAR_TEST_SIGN_IDENTITY": ""}))
    assert ".mason/scripts/xcodebuild-signed.sh -project gui/star.xcodeproj -scheme star" in cmd
    assert "CODE_SIGNING_ALLOWED" not in cmd
    assert "-configuration Debug test -only-testing:starTests/X" in cmd
    cmd = wrapped_command(run(GUI_UNSIGNED.replace("CODE_SIGNING_ALLOWED=NO", "CODE_SIGN_IDENTITY=-")))
    assert "xcodebuild-signed.sh" in cmd and "CODE_SIGN_IDENTITY" not in cmd


def test_other_xcodebuild_commands_are_not_rewritten() -> None:
    other = wrapped_command(run("xcodebuild -project other/x.xcodeproj -scheme star CODE_SIGNING_ALLOWED=NO build"))
    assert "xcodebuild-signed" not in other and "CODE_SIGNING_ALLOWED=NO" in other
    plain = wrapped_command(run("xcodebuild -project gui/star.xcodeproj -scheme star build"))
    assert "xcodebuild-signed" not in plain


def test_opt_out_and_already_signed_are_left_alone() -> None:
    assert "xcodebuild-signed" not in wrapped_command(run(GUI_UNSIGNED, {"STAR_TEST_SIGN_IDENTITY": "-"}))
    signed = ".mason/scripts/xcodebuild-signed.sh -project gui/star.xcodeproj -scheme star build"
    assert wrapped_command(run(signed)).count("xcodebuild-signed.sh") == 1
