"""pipeline/conftest.py turns MASON's dotted test names back into file paths."""

from __future__ import annotations

import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("pipeline_root_conftest", ROOT / "conftest.py")
assert _spec is not None and _spec.loader is not None
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
dotted_to_path = _mod.dotted_to_path


def test_dotted_module_becomes_its_file() -> None:
    assert dotted_to_path("tests.test_cli", ROOT) == "tests/test_cli.py"


def test_paths_node_ids_and_options_are_unchanged() -> None:
    for arg in ["tests/test_cli.py", "tests", "tests/test_cli.py::test_x", "-v", "-k", "tests.nope"]:
        assert dotted_to_path(arg, ROOT) == arg
