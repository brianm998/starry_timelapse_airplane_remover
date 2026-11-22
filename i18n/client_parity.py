#!/usr/bin/env python3
"""Fail when one client uses a catalogue key the other never references.

    ./client_parity.py            print one-sided keys that are not allowlisted; exit 1 if any
    ./client_parity.py --report   print every one-sided key, allowlisted or not (exit 0)
    ./client_parity.py --root DIR scan another tree (the tests do)

gui  = gui/star + StarCore Swift sources.  desktop = star-desktop/src/main Kotlin + stard Swift.
A key counts as used when a string literal equals it, or when an interpolated literal
("tool.help.\\(x)", "view_mode.${x}") has a prefix it starts with. Only keys in en.json count.
i18n/client-parity-allowlist.json maps "<key or prefix*>" to {"side", "why"}.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CATALOGUE = os.path.join("StarCore", "Sources", "StarCore", "Resources", "Localizations", "en.json")
ALLOWLIST = os.path.join("i18n", "client-parity-allowlist.json")
SIDES = {
    "gui": [("gui/star", ".swift"), ("StarCore/Sources/StarCore", ".swift")],
    "desktop": [("star-desktop/src/main", ".kt"), ("daemon/Sources/stard", ".swift")],
}
LITERAL = re.compile(r'"([A-Za-z0-9_.]+)"')
DYNAMIC = re.compile(r'"([A-Za-z0-9_.]*)(?:\\\(|\$)')


def files(root, sub, ext):
    for base, _, names in os.walk(os.path.join(root, sub)):
        for name in names:
            if name.endswith(ext):
                yield os.path.join(base, name)


def scan(root, side, english):
    exact, prefixes = set(), set()
    for sub, ext in SIDES[side]:
        for path in files(root, sub, ext):
            with open(path, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
            exact.update(k for k in LITERAL.findall(text) if k in english)
            prefixes.update(p for p in DYNAMIC.findall(text) if p)
    used = set(exact)
    for key in english:
        if any(key.startswith(p) for p in prefixes):
            used.add(key)
    return used


def one_sided(root):
    with open(os.path.join(root, CATALOGUE), encoding="utf-8") as handle:
        english = json.load(handle)
    gui, desktop = scan(root, "gui", english), scan(root, "desktop", english)
    return {**{k: "gui" for k in gui - desktop}, **{k: "desktop" for k in desktop - gui}}


def allowed(key, allowlist):
    for pattern in allowlist:
        if pattern == key or (pattern.endswith("*") and key.startswith(pattern[:-1])):
            return True
    return False


def main(argv):
    root = os.path.join(HERE, "..")
    if "--root" in argv:
        root = argv[argv.index("--root") + 1]
    path = os.path.join(root, ALLOWLIST)
    allowlist = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            allowlist = json.load(handle)
    sided = one_sided(root)
    if "--report" in argv:
        for key in sorted(sided):
            note = allowlist[key]["why"] if key in allowlist else (
                next((v["why"] for p, v in allowlist.items() if allowed(key, [p])), "NOT ALLOWLISTED"))
            print(f"{sided[key]:8} {key}  [{note}]")
        return 0
    bad = sorted(k for k in sided if not allowed(k, allowlist))
    for key in bad:
        print(f"only {sided[key]} references {key}")
    if bad:
        print(f"{len(bad)} one-sided catalogue key(s): port to the other client, or add to {ALLOWLIST} with a reason")
        return 1
    print("client parity ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
