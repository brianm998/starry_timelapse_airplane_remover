"""T0 static checks implemented in Python (the rest are commands in adapter_star.CHECKS)."""

from __future__ import annotations

import re
import subprocess
import tarfile
import tempfile
from io import BytesIO
from pathlib import Path

from .. import adapter_star as star
from .. import gitutil

_SAME = re.compile(r"^(\S+)\s+\S+\s+\d+ keys, (\d+) same as English", re.MULTILINE)
_LOCALIZATIONS = "StarCore/Sources/StarCore/Resources/Localizations"


def artifacts(root: Path, base: str) -> tuple[bool, str]:
    """A diff must not add the symlinked build artifacts (memory gui-worktree-build)."""
    bad = [p for p in gitutil.added_paths(root, base)
           if any(p == a or p.startswith(a + "/") for a in star.ARTIFACT_LINKS)]
    return (not bad, "adds artifact paths: " + ", ".join(bad) if bad else "no artifact paths in the diff")


def _same_as_english(tool_dir: Path) -> tuple[int, dict[str, int]]:
    done = subprocess.run(["python3", str(tool_dir / "i18n" / "check.py")], capture_output=True, text=True,
                          check=False)
    return done.returncode, {m.group(1): int(m.group(2)) for m in _SAME.finditer(done.stdout)}


def i18n(root: Path, base: str) -> tuple[bool, str]:
    """The catalogue is complete and no language has more English text than on base (CLAUDE.md)."""
    code, now = _same_as_english(root)
    if code != 0:
        return False, "i18n/check.py reports a missing or extra key"
    mb = gitutil.merge_base(root, base)
    with tempfile.TemporaryDirectory() as tmp:
        archive = subprocess.run(
            ["git", "-C", str(root), "archive", mb, "i18n", _LOCALIZATIONS], capture_output=True, check=False
        )
        if archive.returncode != 0:
            return True, "no baseline catalogue on base; completeness only"
        with tarfile.open(fileobj=BytesIO(archive.stdout)) as tar:
            tar.extractall(tmp, filter="data")
        _, before = _same_as_english(Path(tmp))
    worse = {k: (before.get(k, 0), v) for k, v in now.items() if v > before.get(k, 0)}
    if worse:
        return False, "more text identical to English than on base: " + ", ".join(
            f"{k} {a}->{b}" for k, (a, b) in sorted(worse.items()))
    return True, f"complete; same-as-English not above base ({sum(now.values())} total)"
