#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Run one Swift package's XCTest classes as several concurrent `xcrun xctest` processes, and write JUnit.

An extension step for star's `.mason/` (Stage 27). `swift test --parallel` starts one xctest process per
test, about a second each, which loses on a package with many small tests (StarCore has 1,625). This
builds the tests once, then starts one process per shard (a group of classes). A class named in no shard
runs in one more, catch-all shard, so a class added later is never lost. Serial shards run one at a time
afterwards, each alone.

    shards.py --package-path StarCore --junit out.xml --workers 8 \
        --shard HorizonConsensusTests --shard A,B --serial-shard MemoryMonitorTests

`--parse-only LOG` reads an xctest log, prints the counts and writes `--junit` from it, with no build:
that is how this file is tested without a star build.

Exit status: 0 when every shard ran, said how many tests it executed and failed none; 1 otherwise
(a build failure, an unknown class, a shard that crashed or printed no summary, a failed test).
Only XCTest is run here. Tests written with swift-testing (`@Test`) are not seen by `xctest`.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

CASE = re.compile(r"^Test Case '-\[(?P<cls>\S+) (?P<name>\S+)\]' (?P<verdict>passed|failed|skipped) \((?P<secs>[\d.]+) seconds\)")
BANNER = re.compile(r"^\s*Executed (?P<n>\d+) tests?, with (?:(?P<skipped>\d+) tests? skipped and )?(?P<failures>\d+) failures?")
FAILURE = re.compile(r"^(?P<where>\S.*): error: -\[(?P<cls>\S+) (?P<name>\S+)\] : (?P<msg>.*)$")


def parse_log(text: str) -> dict:
    """Cases and the banner out of one xctest log. `banner` is None when the process printed no summary."""
    cases: dict[tuple[str, str], dict] = {}
    banner = None
    for line in text.splitlines():
        if m := CASE.match(line):
            key = (m["cls"], m["name"])
            cases[key] = {"cls": m["cls"], "name": m["name"], "verdict": m["verdict"], "secs": float(m["secs"]), "msgs": cases.get(key, {}).get("msgs", [])}
        elif m := FAILURE.match(line):
            key = (m["cls"], m["name"])
            cases.setdefault(key, {"cls": m["cls"], "name": m["name"], "verdict": "failed", "secs": 0.0, "msgs": []})["msgs"].append(f"{m['where']}: {m['msg']}")
        elif m := BANNER.match(line):
            banner = {"executed": int(m["n"]), "skipped": int(m["skipped"] or 0), "failures": int(m["failures"])}
    return {"cases": list(cases.values()), "banner": banner}


def junit(results: list[dict], out: Path) -> None:
    cases = [c for r in results for c in r["cases"]]
    failed = sum(c["verdict"] == "failed" for c in cases)
    skipped = sum(c["verdict"] == "skipped" for c in cases)
    rows = []
    for c in cases:
        attrs = f"classname={quoteattr(c['cls'])} name={quoteattr(c['name'])} time={quoteattr(str(c['secs']))}"
        if c["verdict"] == "failed":
            msg = escape("\n".join(c["msgs"]) or "failed")
            rows.append(f"    <testcase {attrs}><failure message={quoteattr(msg[:200])}>{msg}</failure></testcase>")
        elif c["verdict"] == "skipped":
            rows.append(f"    <testcase {attrs}><skipped/></testcase>")
        else:
            rows.append(f"    <testcase {attrs}/>")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n<testsuites>\n'
        f'  <testsuite name="xctest-shards" tests="{len(cases)}" failures="{failed}" skipped="{skipped}">\n'
        + "\n".join(rows) + "\n  </testsuite>\n</testsuites>\n"
    )


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kw)


def classes_of(listing: str) -> dict[str, str]:
    """`swift test list` lines are `Module.Class/test`; map each short class name to `Module.Class`."""
    out: dict[str, str] = {}
    for line in listing.splitlines():
        head = line.strip().split("/", 1)[0]
        if "." in head and " " not in head:
            out[head.rsplit(".", 1)[1]] = head
    return out


def plan(known: dict[str, str], shards: list[list[str]], serial: list[str]) -> tuple[list[list[str]], list[str]]:
    """Concurrent shards (catch-all first) and serial ones, as full class names. Raises on an unknown class."""
    named = [c for s in shards for c in s] + serial
    unknown = sorted(set(named) - set(known))
    if unknown:
        raise SystemExit(f"shards: the test bundle has no class {', '.join(unknown)}")
    rest = sorted(set(known) - set(named))
    groups = [rest] + shards
    return [[known[c] for c in g] for g in groups if g], [known[c] for c in serial]


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--package-path")
    ap.add_argument("--junit", required=True)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--shard", action="append", default=[], help="comma-separated classes run together")
    ap.add_argument("--serial-shard", action="append", default=[], help="one class, run alone afterwards")
    ap.add_argument("--parse-only", help="parse this xctest log instead of running anything")
    a = ap.parse_args(argv)
    out = Path(a.junit)

    if a.parse_only:
        r = parse_log(Path(a.parse_only).read_text())
        junit([r], out)
        print(f"shards: parsed {len(r['cases'])} cases, banner {r['banner']}")
        return 0 if r["banner"] and all(c["verdict"] != "failed" for c in r["cases"]) else 1

    if not a.package_path:
        ap.error("--package-path is required")
    pkg = a.package_path
    build = run(["swift", "build", "--build-tests", "--package-path", pkg])
    print(build.stdout, end="")
    if build.returncode:
        return 1
    bin_dir = run(["swift", "build", "--build-tests", "--package-path", pkg, "--show-bin-path"]).stdout.strip().splitlines()[-1]
    bundles = sorted(Path(bin_dir).glob("*.xctest"))
    if not bundles:
        print(f"shards: no .xctest bundle in {bin_dir}", file=sys.stderr)
        return 1
    listing = run(["swift", "test", "list", "--skip-build", "--package-path", pkg])
    if listing.returncode:
        print(listing.stdout, file=sys.stderr)
        return 1
    concurrent, serial = plan(classes_of(listing.stdout), [s.split(",") for s in a.shard], a.serial_shard)

    lock = threading.Lock()

    def one(k_classes: tuple[int, list[str]]) -> dict:
        k, classes = k_classes
        p = run(["xcrun", "xctest", "-XCTest", ",".join(classes), str(bundles[0])])
        with lock:
            for line in p.stdout.splitlines():
                print(f"[shard {k}] {line}")
        r = parse_log(p.stdout)
        r["crashed"] = p.returncode != 0 and not any(c["verdict"] == "failed" for c in r["cases"])
        return r

    results: list[dict] = []
    with ThreadPoolExecutor(max_workers=max(1, a.workers)) as ex:
        results += list(ex.map(one, enumerate(concurrent)))
    for i, c in enumerate(serial):
        results.append(one((len(concurrent) + i, [c])))

    junit(results, out)
    bad = False
    for k, r in enumerate(results):
        if r["banner"] is None or r["crashed"]:
            print(f"shards: shard {k} printed no summary or crashed: counted red", file=sys.stderr)
            bad = True
        bad = bad or any(c["verdict"] == "failed" for c in r["cases"])
    total = sum(len(r["cases"]) for r in results)
    print(f"shards: {total} test cases in {len(results)} shards")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
