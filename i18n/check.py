#!/usr/bin/env python3
"""Check the star localization catalogue, and merge translation drops into it.

    ./check.py                 report on every table against en.json
    ./check.py --install DIR   merge DIR/<code>.json into the tables, then report

`--install` is how a batch of translations lands: each file in DIR is a partial or complete
{key: value} map for one language, and it is merged over whatever that language already has,
sorted, and written back. Keys absent from en.json are refused rather than silently kept —
that is almost always a key that was renamed on the English side.

Exit status is nonzero when anything is missing, so this can gate a release. It duplicates
what LocalizationTests asserts, but runs in a second and without a Swift toolchain.
"""
import json
import os
import re
import sys

# The tables live in StarCore's resource bundle, which is `.copy`'d wholesale into every
# Swift client and into the Kotlin jar — so this script and the README sit outside it rather
# than being shipped inside every star app.
HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                    "..", "StarCore", "Sources", "StarCore", "Resources", "Localizations")
PLACEHOLDER = re.compile(r"\{(\d+)\}")


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def save(path, table):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(dict(sorted(table.items())), handle, indent=2, ensure_ascii=False)
        handle.write("\n")


def codes():
    manifest = load(os.path.join(HERE, "languages.json"))
    return [entry["code"] for entry in manifest["languages"]]


def install(source_dir, english):
    for code in codes():
        drop = os.path.join(source_dir, f"{code}.json")
        if not os.path.exists(drop):
            continue
        incoming = load(drop)
        unknown = sorted(set(incoming) - set(english))
        if unknown:
            print(f"  {code}: refusing {len(unknown)} key(s) not in en.json: "
                  f"{', '.join(unknown[:5])}")
            incoming = {k: v for k, v in incoming.items() if k in english}
        target = os.path.join(HERE, f"{code}.json")
        table = load(target) if os.path.exists(target) else {}
        table.update(incoming)
        save(target, table)
        print(f"  {code}: merged {len(incoming)} → {len(table)} total")


def main():
    english = load(os.path.join(HERE, "en.json"))

    if "--install" in sys.argv:
        source_dir = sys.argv[sys.argv.index("--install") + 1]
        print(f"installing from {source_dir}")
        install(source_dir, english)
        print()

    failed = False
    print(f"en.json: {len(english)} keys\n")
    for code in codes():
        if code == "en":
            continue
        path = os.path.join(HERE, f"{code}.json")
        if not os.path.exists(path):
            print(f"{code:8} MISSING TABLE")
            failed = True
            continue

        table = load(path)
        missing = sorted(set(english) - set(table))
        extra = sorted(set(table) - set(english))
        empty = sorted(k for k, v in table.items() if not v.strip())
        # A translation that drops a {0} loses the number the sentence was about; one that
        # invents a {3} renders literal braces on screen. Both are invisible until a user in
        # that language reaches the string.
        bad = sorted(k for k, v in table.items()
                     if k in english
                     and set(PLACEHOLDER.findall(v)) != set(PLACEHOLDER.findall(english[k])))
        # Not an error — some strings genuinely are the same word in two languages — but a
        # whole table that matches English is a table nobody translated.
        untranslated = sum(1 for k, v in table.items() if k in english and v == english[k])

        problems = []
        if missing:
            problems.append(f"{len(missing)} missing ({', '.join(missing[:3])}…)")
        if extra:
            problems.append(f"{len(extra)} unknown ({', '.join(extra[:3])}…)")
        if empty:
            problems.append(f"{len(empty)} empty")
        if bad:
            problems.append(f"{len(bad)} placeholder mismatch ({', '.join(bad[:3])}…)")

        if problems:
            failed = True
            print(f"{code:8} FAIL  {len(table):4} keys — " + "; ".join(problems))
        else:
            print(f"{code:8} ok    {len(table):4} keys, {untranslated} same as English")

    print()
    if failed:
        print("catalogue is INCOMPLETE")
        return 1
    print("catalogue is complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
