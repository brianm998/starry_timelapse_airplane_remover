#!/usr/bin/env python3
"""PreToolUse hook for interactive Claude sessions in this repo: run heavy Bash commands under
`starpipe heavy`, so memory one-heavy-job-at-a-time holds for everyone (plan §9.1).

Stdlib only, so it starts fast and works before the pipeline's environment exists. It fails open:
anything unexpected leaves the command untouched. STARPIPE_NO_WRAP=1 disables it.
"""

import json
import os
import re
import shlex
import shutil
import sys
from pathlib import Path

HEAVY = re.compile(
    r"(?:^|[;&|(]|&&|\|\||\n)\s*(?:[\w./-]+/)?"
    r"(?:swift\s+(?:build|test|run)\b|xcodebuild\b|gradle\b|gradlew\b"
    r"|\.build/[\w-]+/(?:star|stard)\b|star-gherkin\b)"
)


def main() -> None:
    if os.environ.get("STARPIPE_NO_WRAP"):
        return
    try:
        event = json.load(sys.stdin)
        command = event["tool_input"]["command"]
    except (ValueError, KeyError, TypeError):
        return
    shim = Path(__file__).resolve().parent.parent / "bin" / "starpipe"
    if "starpipe heavy" in command or " heavy -- " in command:
        return
    if not (HEAVY.search(command) and shim.exists() and shutil.which("uv")):
        return
    wrapped = f"{shlex.quote(str(shim))} heavy -- bash -c {shlex.quote(command)}"
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "updatedInput": {**event["tool_input"], "command": wrapped},
    }}))


if __name__ == "__main__":
    main()
