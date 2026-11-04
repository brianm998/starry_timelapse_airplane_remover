"""Run one swift package's XCTest classes as several concurrent `xctest` processes (ticket #250).

`swift test --parallel` launches an xctest process per test, which costs ~1 s each on this Mac, so it loses on suites with
many small tests. This builds the tests once and then launches one process per *shard* (a group of classes), so a launch is
paid per shard and each shard's log keeps its XCTest banner and skip counts. The shards run the built bundle with
`xcrun xctest -XCTest <classes>`, not `swift test --skip-build --filter`: every `swift test` holds SwiftPM's lock on `.build`
for the whole run ("Another instance of SwiftPM is already running ... waiting"), so those would run back to back. Nothing
here names a star path or class: the caller (adapter_star) passes the class groups.

    python -m starpipe.shards --package-path PKG --log-dir DIR --stem NAME --concurrency N \
        --shard 'ClassA|ClassB' --shard 'ClassC' --serial-shard 'ClassD'

Shard logs are `DIR/NAME.shard<k>.log`: k = 0 is the catch-all (every class of the bundle no other shard names, so a class
added later is still run), then the concurrent shards in order, then the serial ones. Serial shards run one at a time after
every concurrent shard has ended, alone on the machine. Everything is also streamed to stdout with a `[shard k]` prefix, so
the heavy job's idle watchdog sees activity and a hung test's name stays visible. Exit non-zero if the build or any shard
failed, or if a shard names a class the bundle does not have.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import threading
from collections.abc import Sequence
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

# xctest runs on a pty (`script`) so it line-buffers its progress; see adapter_star.LIVE_LOG
_PTY = ("script", "-q", "/dev/null")

_out_lock = threading.Lock()


def shard_log(log_dir: Path, stem: str, k: int) -> Path:
    return log_dir / f"{stem}.shard{k}.log"


def _classes(group: str) -> list[str]:
    return [c for c in group.split("|") if c]


def shard_classes(all_classes: Sequence[str], concurrent: Sequence[str], serial: Sequence[str]) -> list[list[str]]:
    """The classes of every shard, in log order: the catch-all (everything unnamed), the concurrent shards, the serial ones."""
    groups = [_classes(g) for g in (*concurrent, *serial)]
    named = {c for g in groups for c in g}
    return [[c for c in all_classes if c not in named], *groups]


def discover(package: str) -> tuple[list[str], Path]:
    """The test classes of the built package and its .xctest bundle."""
    listing = subprocess.run(["swift", "test", "--package-path", package, "--skip-build", "list"], capture_output=True, text=True,
                             check=False)
    classes = list(dict.fromkeys(m.group(1) for m in re.finditer(r"^\w+\.(\w+)/\w+", listing.stdout, re.MULTILINE)))
    bin_path = subprocess.run(["swift", "build", "--package-path", package, "--show-bin-path"], capture_output=True, text=True,
                              check=False).stdout.strip().splitlines()
    bundles = sorted(Path(bin_path[-1]).glob("*.xctest")) if bin_path else []
    if not classes or not bundles:
        raise SystemExit(f"no test classes or no .xctest bundle found for {package}: {listing.stdout[-300:]}{listing.stderr[-300:]}")
    return classes, bundles[0]


def _say(k: int, line: bytes) -> None:
    with _out_lock:
        sys.stdout.buffer.write(f"[shard {k}] ".encode() + line)
        sys.stdout.buffer.flush()


def _run_shard(bundle: Path, log: Path, k: int, classes: list[str]) -> int:
    argv = [*_PTY, "xcrun", "xctest", "-XCTest", ",".join(classes), str(bundle)]
    with log.open("wb") as out:
        proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        assert proc.stdout is not None
        for line in proc.stdout:
            out.write(line)
            out.flush()
            _say(k, line)
        return proc.wait()


def run(package: str, log_dir: Path, stem: str, concurrency: int, concurrent: Sequence[str], serial: Sequence[str]) -> int:
    log_dir.mkdir(parents=True, exist_ok=True)
    for k in range(1 + len(concurrent) + len(serial)):  # a log left by an earlier run must not stand in for this one's
        shard_log(log_dir, stem, k).unlink(missing_ok=True)
    sys.stdout.write(f"+ swift build --build-tests --package-path {package}\n")
    sys.stdout.flush()
    built = subprocess.run(["swift", "build", "--build-tests", "--package-path", package], check=False)
    if built.returncode != 0:
        return built.returncode
    all_classes, bundle = discover(package)
    unknown = sorted({c for g in (*concurrent, *serial) for c in _classes(g)} - set(all_classes))
    if unknown:
        print(f"shard classes not in {bundle.name}: {', '.join(unknown)}", file=sys.stderr)
        return 2
    selections = shard_classes(all_classes, concurrent, serial)
    first_serial = 1 + len(concurrent)
    codes: list[int] = []
    with ThreadPoolExecutor(max_workers=max(1, concurrency)) as pool:
        futures = [pool.submit(_run_shard, bundle, shard_log(log_dir, stem, k), k, selections[k]) for k in range(first_serial)]
        codes += [f.result() for f in futures]
    for k in range(first_serial, len(selections)):  # alone on the machine: every concurrent shard has ended
        codes.append(_run_shard(bundle, shard_log(log_dir, stem, k), k, selections[k]))
    return 0 if all(c == 0 for c in codes) else 1


def main(argv: Sequence[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--package-path", required=True)
    ap.add_argument("--log-dir", required=True, type=Path)
    ap.add_argument("--stem", required=True, help="shard log file name prefix")
    ap.add_argument("--concurrency", type=int, default=4)
    ap.add_argument("--shard", action="append", default=[], help="classes joined by |; run concurrently")
    ap.add_argument("--serial-shard", action="append", default=[], help="classes joined by |; run alone, after the concurrent shards")
    args = ap.parse_args(argv)
    if shutil.which("swift") is None:
        print("swift not found on PATH", file=sys.stderr)
        return 127
    return run(args.package_path, args.log_dir, args.stem, args.concurrency, args.shard, args.serial_shard)


if __name__ == "__main__":
    sys.exit(main())
