"""Root pytest configuration for the pipeline package.

MASON's narrowed test step names a whole test file by its dotted module path
(`tests.test_cli` for `tests/test_cli.py`; its `name_from_path` turns `/` into `.` and
drops the extension), and pytest rejects that as "file or directory not found". Turn such an
argument back into the file path it names, so a narrowed `uv run pytest -v tests.test_cli`
runs that file. Real paths, node ids (`::`) and options are left alone.
"""

from __future__ import annotations

from pathlib import Path

import pytest


def dotted_to_path(arg: str, root: Path) -> str:
    """`tests.test_cli` -> `tests/test_cli.py` when that file exists under `root` and `arg`
    is not itself a path; any other argument is returned unchanged."""
    if arg.startswith("-") or "/" in arg or "::" in arg or "." not in arg:
        return arg
    if (root / arg).exists():
        return arg
    candidate = Path(*arg.split(".")).with_suffix(".py")
    if (root / candidate).is_file():
        return candidate.as_posix()
    return arg


def pytest_configure(config: pytest.Config) -> None:
    root = Path(str(config.invocation_params.dir))
    config.args[:] = [dotted_to_path(a, root) for a in config.args]
