"""The results ledger: one JSON line per check run, so 'green at HEAD' is a lookup, not a claim."""

from __future__ import annotations

import json
import time
from dataclasses import asdict, dataclass
from pathlib import Path

from ..config import home


@dataclass
class Result:
    check: str
    status: str  # pass | fail | vacuous | skipped-tests | not-run
    sha: str
    seconds: float
    lock_wait: float = 0.0
    executed: int = 0
    failed: int = 0
    skipped: int = 0
    log: str = ""
    detail: str = ""
    at: float = 0.0

    @property
    def green(self) -> bool:
        return self.status == "pass"


def ledger_path() -> Path:
    return home() / "results.jsonl"


def record(result: Result) -> None:
    result.at = result.at or time.time()
    path = ledger_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        handle.write(json.dumps(asdict(result)) + "\n")


def latest(sha: str, check: str) -> Result | None:
    found: Result | None = None
    path = ledger_path()
    if not path.exists():
        return None
    for line in path.read_text().splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("sha") == sha and row.get("check") == check:
            found = Result(**row)
    return found
