"""gherkin/run-desktop-features.sh: STAR_FEATURE_TIMEOUT_SECONDS cuts a hung feature off and goes on to the next (ticket #415)."""
from __future__ import annotations

import os
import shutil
import subprocess
import time
from pathlib import Path

GHERKIN = Path(__file__).resolve().parents[2] / "gherkin"

FAKE_GRADLEW = r"""#!/bin/bash
# a stand-in for gradlew: the feature named "hangs" never returns (and has a child, like the test worker and stard)
feature=""
while [ $# -gt 0 ]; do case "$1" in com.star.*) feature=${1##*.}; feature=${feature%Feature} ;; esac; shift; done
if [ "$feature" = hangs ]; then
    sleep 300 &
    echo $! > "$(dirname "$0")/child.pid"
    wait
fi
mkdir -p build/test-results/gherkinTest build/reports/tests/gherkinTest
echo '<testsuite tests="1" skipped="0" failures="0"/>' > build/test-results/gherkinTest/TEST-x.xml
"""


def run(tmp_path: Path, timeout: str | None, features: list[str]) -> tuple[subprocess.CompletedProcess[str], Path]:
    (tmp_path / "gherkin").mkdir()
    for name in ("run-desktop-features.sh", "hang-watchdog.sh"):
        shutil.copy(GHERKIN / name, tmp_path / "gherkin" / name)
    desktop = tmp_path / "star-desktop"
    desktop.mkdir()
    (desktop / "gradlew").write_text(FAKE_GRADLEW)
    (desktop / "gradlew").chmod(0o755)
    shims = tmp_path / "shims"
    shims.mkdir()
    (shims / "jps").write_text("#!/bin/bash\nexit 0\n")  # the machine's real JVMs would only slow the dump
    (shims / "jps").chmod(0o755)
    env = {**os.environ, "PATH": f"{shims}{os.pathsep}{os.environ['PATH']}", "HANG_WATCHDOG_PGREP": "-x no-such-stard-process"}
    env.pop("STAR_HANG_WATCHDOG_SECONDS", None)
    if timeout is None:
        env.pop("STAR_FEATURE_TIMEOUT_SECONDS", None)
    else:
        env["STAR_FEATURE_TIMEOUT_SECONDS"] = timeout
    done = subprocess.run(["bash", str(tmp_path / "gherkin" / "run-desktop-features.sh"), "/x/stard", *features],
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, timeout=120)
    return done, desktop


def testHungFeatureIsCutOffAndTheNextOneRuns(tmp_path: Path) -> None:
    done, desktop = run(tmp_path, "3", ["hangs", "fine"])
    out = done.stdout
    assert done.returncode == 1, out
    assert "::error::hangs: still running after 3s" in out, out
    assert "stard hang watchdog: dump now" in out and "hangs ran 3s" in out, out  # the stacks were dumped first
    assert "== fine: passed" in out, out  # the feature after it still ran
    assert (desktop / "build/gherkin-each/fine/PASSED").exists()
    assert not (desktop / "build/gherkin-each/hangs/PASSED").exists()
    assert "::error::1 of the features failed: hangs" in out, out
    child = int((desktop / "child.pid").read_text())
    for _ in range(20):  # the fake gradlew's child died with it
        try:
            os.kill(child, 0)
        except ProcessLookupError:
            return
        time.sleep(0.25)
    raise AssertionError(f"the hung feature's child process {child} is still running")


def testWithoutTheLimitAFeatureRunsAsBefore(tmp_path: Path) -> None:
    done, _desktop = run(tmp_path, None, ["fine"])
    assert done.returncode == 0, done.stdout
    assert "== fine: passed" in done.stdout
    assert "still running after" not in done.stdout
