"""The weekly digest (plan §11): is the pipeline meeting its goal, which is to need the owner as little as possible?

Everything comes from the database and the results ledger; nothing is estimated.
"""

from __future__ import annotations

import json
import statistics
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from .db import Database

DAY = 86400.0


@dataclass
class Digest:
    since: float
    until: float
    landed: list[int] = field(default_factory=lambda: list[int]())
    median_claim_to_land_s: float | None = None
    interventions: dict[str, int] = field(default_factory=lambda: dict[str, int]())
    interventions_per_ticket: float | None = None
    park_reasons: list[tuple[str, int]] = field(default_factory=lambda: list[tuple[str, int]]())
    lock_busy_fraction: float | None = None
    lock_wait_s: float = 0.0
    questions: int = 0
    resolver_answers: int = 0
    nightly: str = "no nightly has run"

    def render(self) -> str:
        days = (self.until - self.since) / DAY
        median = f"{self.median_claim_to_land_s / 60:.0f} min" if self.median_claim_to_land_s is not None else "n/a"
        per = f"{self.interventions_per_ticket:.2f}" if self.interventions_per_ticket is not None else "n/a"
        lines = [
            f"# Star pipeline digest: {datetime.fromtimestamp(self.since):%Y-%m-%d} to {datetime.fromtimestamp(self.until):%Y-%m-%d}",
            "",
            f"- **Landed:** {len(self.landed)} ticket(s)" + (f" ({', '.join(f'#{n}' for n in self.landed)})" if self.landed else ""),
            f"- **Median claim to land:** {median}",
            f"- **Interventions per landed ticket:** {per}"
            + (f" ({', '.join(f'{v} {k}' for k, v in sorted(self.interventions.items()))})" if self.interventions else ""),
            f"- **Questions answered by the resolver:** {self.resolver_answers} of {self.questions}",
            "- **Heavy lock:** "
            + (f"busy {self.lock_busy_fraction * 100:.1f}% of the {days:.0f} days" if self.lock_busy_fraction is not None else "n/a")
            + f", {self.lock_wait_s / 60:.0f} min spent waiting for it",
            f"- **Last nightly:** {self.nightly}",
        ]
        if self.park_reasons:
            lines += ["", "## Top park reasons", *[f"- {n} × {reason}" for reason, n in self.park_reasons]]
        return "\n".join(lines) + "\n"


def build(db: Database, now: float, days: int = 7, ledger_path: Path | None = None) -> Digest:
    since = now - days * DAY
    d = Digest(since, now)

    events = [e for e in db.events_since(0, 100000) if e["at"] >= since]
    claimed: dict[int, float] = {}
    for e in db.events_since(0, 100000):  # a ticket landed this week may have been claimed last week
        if e["kind"] == "claimed" and e["ticket"] is not None:
            claimed.setdefault(e["ticket"], e["at"])
    durations: list[float] = []
    for e in events:
        if e["kind"] == "landed" and e["ticket"] is not None:
            d.landed.append(e["ticket"])
            if e["ticket"] in claimed:
                durations.append(e["at"] - claimed[e["ticket"]])
    d.landed = sorted(set(d.landed))
    d.median_claim_to_land_s = statistics.median(durations) if durations else None

    rows = db._all("SELECT kind, COUNT(*) AS n FROM interventions WHERE at >= ? GROUP BY kind", (since,))  # pyright: ignore[reportPrivateUsage]
    d.interventions = {r["kind"]: r["n"] for r in rows}
    if d.landed:
        d.interventions_per_ticket = sum(d.interventions.values()) / len(d.landed)

    reasons: Counter[str] = Counter()
    for e in events:
        if e["kind"] == "state" and e["data"].get("state") == "failed" and e["data"].get("reason"):
            reasons[str(e["data"]["reason"]).split(":")[0][:70]] += 1
    d.park_reasons = reasons.most_common(5)

    q = db._all("SELECT answered_by, COUNT(*) AS n FROM questions WHERE answered_at >= ? OR answered_at IS NULL GROUP BY answered_by", (since,))  # pyright: ignore[reportPrivateUsage]
    d.questions = sum(r["n"] for r in q)
    d.resolver_answers = sum(r["n"] for r in q if r["answered_by"] == "resolver")

    if ledger_path and ledger_path.exists():
        busy = wait = 0.0
        for line in ledger_path.read_text().splitlines():
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("at", 0) >= since:
                busy += float(r.get("seconds", 0))
                wait += float(r.get("lock_wait", 0))
        d.lock_busy_fraction = min(1.0, busy / (now - since))
        d.lock_wait_s = wait

    from .nightly import summary_line

    d.nightly = summary_line(db.nightly_run())
    return d
