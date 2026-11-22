import json
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "client_parity.py")
CAT = "StarCore/Sources/StarCore/Resources/Localizations/en.json"


def put(root, rel, text):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def run(root, *extra):
    return subprocess.run([sys.executable, SCRIPT, "--root", root, *extra],
                          capture_output=True, text=True)


class ClientParity(unittest.TestCase):
    def tree(self, gui="", desktop="", allow=None):
        root = tempfile.mkdtemp()
        self.addCleanup(__import__("shutil").rmtree, root, True)
        keys = {"ui.shared": "x", "ui.some_new_key": "y", "tool.help.a": "z", "tool.help.b": "w"}
        put(root, CAT, json.dumps(keys))
        put(root, "gui/star/A.swift", gui + ' localized("ui.shared")')
        put(root, "star-desktop/src/main/A.kt", desktop + ' t("ui.shared")')
        if allow is not None:
            put(root, "i18n/client-parity-allowlist.json", json.dumps(allow))
        return root

    def test_balanced_passes(self):
        self.assertEqual(run(self.tree()).returncode, 0)

    def test_one_sided_key_fails_and_is_named(self):
        result = run(self.tree(gui='localized("ui.some_new_key")'))
        self.assertEqual(result.returncode, 1)
        self.assertIn("ui.some_new_key", result.stdout)

    def test_allowlist_silences(self):
        root = self.tree(gui='localized("ui.some_new_key")',
                         allow={"ui.some_new_key": {"side": "gui", "why": "engine"}})
        self.assertEqual(run(root).returncode, 0)
        self.assertIn("ui.some_new_key", run(root, "--report").stdout)

    def test_dynamic_prefix_counts_as_use(self):
        gui = 'localized("tool.help.a") localized("tool.help.b")'
        for dyn in ('t("tool.help.${name}")', 't("tool.help.$it")'):
            self.assertEqual(run(self.tree(gui=gui, desktop=dyn)).returncode, 0)
        swift = 'localized("tool.help.\\(x)")'
        root = self.tree(gui=swift, desktop='t("tool.help.a") t("tool.help.b")')
        self.assertEqual(run(root).returncode, 0)


if __name__ == "__main__":
    unittest.main()
