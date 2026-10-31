"""SQLite state (plan §14.5). The daemon is the only writer; clients read through the API or read-only."""

from __future__ import annotations

import json
import sqlite3
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from importlib import resources
from pathlib import Path
from typing import Any

from .config import home

Clock = Callable[[], float]

# A ticket's state is also its GitHub label (pipe:<state>).
ACTIVE_STATES = ("exploring", "developing", "verifying", "review")
POST_STATES = ("ready", "ci", "landing")
LIVE_STATES = ("queued", *ACTIVE_STATES, *POST_STATES, "needs-input", "paused")
TERMINAL_STATES = ("landed", "failed", "closed", "cancelled")


def db_path() -> Path:
    return home() / "state.db"


@dataclass
class Ticket:
    number: int
    title: str
    body: str
    author: str
    state: str
    priority: int
    blocked_by: list[int]
    branch: str | None
    worktree: str | None
    plan_json: str | None
    park_reason: str | None
    pr_number: int | None
    created_at: float

    @property
    def plan(self) -> dict[str, Any] | None:
        return json.loads(self.plan_json) if self.plan_json else None


def _ticket(row: sqlite3.Row) -> Ticket:
    return Ticket(row["number"], row["title"], row["body"], row["author"], row["state"], row["priority"],
                  json.loads(row["blocked_by"]), row["branch"], row["worktree"], row["plan_json"],
                  row["park_reason"], row["pr_number"], row["created_at"])


class Database:
    def __init__(self, path: Path | str | None = None, clock: Clock = time.time, read_only: bool = False) -> None:
        self.clock = clock
        target = Path(path) if path else db_path()
        if read_only:
            self.conn = sqlite3.connect(f"file:{target}?mode=ro", uri=True, check_same_thread=False)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            self.conn = sqlite3.connect(target, check_same_thread=False)
            self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        if not read_only:
            self._migrate()

    def _migrate(self) -> None:
        with self.lock:
            self.conn.execute("CREATE TABLE IF NOT EXISTS schema_version (n INTEGER PRIMARY KEY)")
            done = {r[0] for r in self.conn.execute("SELECT n FROM schema_version")}
            files = sorted(resources.files("starpipe").joinpath("migrations").iterdir(), key=lambda f: f.name)
            for f in files:
                n = int(f.name.split("_", 1)[0])
                if f.name.endswith(".sql") and n not in done:
                    self.conn.executescript(f.read_text())
                    self.conn.execute("INSERT INTO schema_version VALUES (?)", (n,))
            self.conn.commit()

    def close(self) -> None:
        self.conn.close()

    def _exec(self, sql: str, args: tuple[Any, ...] = ()) -> sqlite3.Cursor:
        with self.lock:
            cur = self.conn.execute(sql, args)
            self.conn.commit()
            return cur

    def _all(self, sql: str, args: tuple[Any, ...] = ()) -> list[sqlite3.Row]:
        with self.lock:
            return self.conn.execute(sql, args).fetchall()

    # events --------------------------------------------------------------------------------------------------------
    def event(self, kind: str, ticket: int | None = None, **data: Any) -> None:
        self._exec("INSERT INTO events(at, ticket, kind, data) VALUES (?,?,?,?)",
                   (self.clock(), ticket, kind, json.dumps(data)))

    def events_since(self, after: int = 0, limit: int = 500) -> list[dict[str, Any]]:
        rows = self._all("SELECT * FROM events WHERE id > ? ORDER BY id LIMIT ?", (after, limit))
        return [{**dict(r), "data": json.loads(r["data"])} for r in rows]

    # kv ------------------------------------------------------------------------------------------------------------
    def get(self, key: str, default: str | None = None) -> str | None:
        rows = self._all("SELECT value FROM kv WHERE key=?", (key,))
        return rows[0]["value"] if rows else default

    def put(self, key: str, value: str | None) -> None:
        if value is None:
            self._exec("DELETE FROM kv WHERE key=?", (key,))
        else:
            self._exec("INSERT INTO kv(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                       (key, value))

    # tickets -------------------------------------------------------------------------------------------------------
    def upsert_ticket(self, number: int, title: str, body: str, author: str, priority: int,
                      blocked_by: list[int]) -> bool:
        """Insert a new ticket as queued, or refresh the issue's own fields. True when it was new."""
        now = self.clock()
        exists = self.ticket(number) is not None
        if exists:
            self._exec("UPDATE tickets SET title=?, body=?, priority=?, blocked_by=?, updated_at=? WHERE number=?",
                       (title, body, priority, json.dumps(blocked_by), now, number))
        else:
            self._exec("INSERT INTO tickets(number,title,body,author,priority,blocked_by,created_at,updated_at) "
                       "VALUES (?,?,?,?,?,?,?,?)", (number, title, body, author, priority, json.dumps(blocked_by), now, now))
            self.event("ticket-queued", number, title=title)
        return not exists

    def ticket(self, number: int) -> Ticket | None:
        rows = self._all("SELECT * FROM tickets WHERE number=?", (number,))
        return _ticket(rows[0]) if rows else None

    def tickets(self, states: tuple[str, ...] | None = None) -> list[Ticket]:
        if states:
            marks = ",".join("?" * len(states))
            rows = self._all(f"SELECT * FROM tickets WHERE state IN ({marks}) ORDER BY priority, created_at", states)
        else:
            rows = self._all("SELECT * FROM tickets ORDER BY priority, created_at")
        return [_ticket(r) for r in rows]

    def set_state(self, number: int, state: str, reason: str | None = None) -> None:
        self._exec("UPDATE tickets SET state=?, park_reason=?, updated_at=? WHERE number=?",
                   (state, reason, self.clock(), number))
        self.event("state", number, state=state, reason=reason)

    def set_fields(self, number: int, **fields: Any) -> None:
        allowed = {"branch", "worktree", "plan_json", "pr_number", "claimed_at", "closed_reason", "priority"}
        assert set(fields) <= allowed, fields
        cols = ", ".join(f"{k}=?" for k in fields)
        self._exec(f"UPDATE tickets SET {cols}, updated_at=? WHERE number=?", (*fields.values(), self.clock(), number))

    def open_blockers(self, number: int) -> list[int]:
        """Blockers that have not landed or closed yet."""
        t = self.ticket(number)
        if t is None:
            return []
        out: list[int] = []
        for b in t.blocked_by:
            other = self.ticket(b)
            if other is None or other.state not in ("landed", "closed"):
                out.append(b)
        return out

    # stages --------------------------------------------------------------------------------------------------------
    def begin_stage(self, ticket: int, stage: str, attempt: int, model: str) -> int:
        cur = self._exec("INSERT INTO stages(ticket,stage,attempt,model,started) VALUES (?,?,?,?,?)",
                         (ticket, stage, attempt, model, self.clock()))
        self.event("stage-start", ticket, stage=stage, attempt=attempt, model=model)
        assert cur.lastrowid is not None
        return cur.lastrowid

    def set_session(self, stage_id: int, session_id: str) -> None:
        self._exec("UPDATE stages SET session_id=? WHERE id=?", (session_id, stage_id))

    def end_stage(self, stage_id: int, outcome: str, lock_wait_s: float = 0.0, detail: str = "") -> None:
        self._exec("UPDATE stages SET ended=?, outcome=?, lock_wait_s=?, detail=? WHERE id=?",
                   (self.clock(), outcome, lock_wait_s, detail, stage_id))
        row = self._all("SELECT ticket, stage FROM stages WHERE id=?", (stage_id,))[0]
        self.event("stage-end", row["ticket"], stage=row["stage"], outcome=outcome)

    def stages(self, ticket: int, stage: str | None = None) -> list[dict[str, Any]]:
        if stage:
            rows = self._all("SELECT * FROM stages WHERE ticket=? AND stage=? ORDER BY id", (ticket, stage))
        else:
            rows = self._all("SELECT * FROM stages WHERE ticket=? ORDER BY id", (ticket,))
        return [dict(r) for r in rows]

    def running_stages(self) -> list[dict[str, Any]]:
        return [dict(r) for r in self._all("SELECT * FROM stages WHERE ended IS NULL")]

    # questions -----------------------------------------------------------------------------------------------------
    def add_question(self, ticket: int, stage: str, text: str, payload: dict[str, Any]) -> int:
        cur = self._exec("INSERT INTO questions(ticket,stage,text,payload,asked_at) VALUES (?,?,?,?,?)",
                         (ticket, stage, text, json.dumps(payload), self.clock()))
        assert cur.lastrowid is not None
        return cur.lastrowid

    def open_question(self, ticket: int) -> dict[str, Any] | None:
        rows = self._all("SELECT * FROM questions WHERE ticket=? AND answer IS NULL ORDER BY id DESC LIMIT 1", (ticket,))
        return dict(rows[0]) if rows else None

    def answer_question(self, question_id: int, answer: str, by: str) -> None:
        self._exec("UPDATE questions SET answer=?, answered_at=?, answered_by=? WHERE id=?",
                   (answer, self.clock(), by, question_id))

    def set_question_comment(self, question_id: int, comment_id: int) -> None:
        self._exec("UPDATE questions SET comment_id=? WHERE id=?", (comment_id, question_id))

    def asked_before(self, ticket: int, text: str) -> bool:
        return bool(self._all("SELECT 1 FROM questions WHERE ticket=? AND text=? AND answer IS NOT NULL", (ticket, text)))

    # CI baseline ---------------------------------------------------------------------------------------------------
    def baseline(self, workflow: str, job: str) -> str | None:
        rows = self._all("SELECT conclusion FROM develop_baseline WHERE workflow=? AND job=?", (workflow, job))
        return rows[0]["conclusion"] if rows else None

    def set_baseline(self, workflow: str, job: str, sha: str, conclusion: str) -> None:
        self._exec("INSERT INTO develop_baseline(workflow,job,sha,conclusion,at) VALUES (?,?,?,?,?) "
                   "ON CONFLICT(workflow,job) DO UPDATE SET sha=excluded.sha, conclusion=excluded.conclusion, at=excluded.at",
                   (workflow, job, sha, conclusion, self.clock()))

    def baseline_size(self) -> int:
        return int(self._all("SELECT COUNT(*) AS n FROM develop_baseline")[0]["n"])

    def record_ci(self, ticket: int, sha: str, verdict: str, detail: dict[str, Any]) -> None:
        self._exec("INSERT INTO ci_runs(ticket,sha,verdict,detail,at) VALUES (?,?,?,?,?)",
                   (ticket, sha, verdict, json.dumps(detail), self.clock()))

    # nightly --------------------------------------------------------------------------------------------------------
    def nightly_begin(self, ref: str, sha: str) -> int:
        cur = self._exec("INSERT INTO nightly_runs(started,ref,sha) VALUES (?,?,?)", (self.clock(), ref, sha))
        assert cur.lastrowid is not None
        self.event("nightly-start", None, run=cur.lastrowid, ref=ref, sha=sha[:12])
        return cur.lastrowid

    def nightly_result(self, run: int, check_id: str, status: str, executed: int, failed: int, skipped: int,
                       seconds: float, lock_wait_s: float, log: str) -> None:
        self._exec("INSERT INTO nightly_results(run,check_id,status,executed,failed,skipped,seconds,lock_wait_s,log) "
                   "VALUES (?,?,?,?,?,?,?,?,?)", (run, check_id, status, executed, failed, skipped, seconds, lock_wait_s, log))

    def nightly_end(self, run: int, status: str, summary: dict[str, Any]) -> None:
        self._exec("UPDATE nightly_runs SET ended=?, status=?, summary=? WHERE id=?",
                   (self.clock(), status, json.dumps(summary), run))
        self.event("nightly-end", None, run=run, status=status)

    def nightly_run(self, run: int | None = None) -> dict[str, Any] | None:
        """One run (default: the latest) with its results."""
        rows = (self._all("SELECT * FROM nightly_runs WHERE id=?", (run,)) if run
                else self._all("SELECT * FROM nightly_runs ORDER BY id DESC LIMIT 1"))
        if not rows:
            return None
        out = dict(rows[0])
        out["summary"] = json.loads(out["summary"])
        out["results"] = [dict(r) for r in self._all("SELECT * FROM nightly_results WHERE run=? ORDER BY id", (out["id"],))]
        return out

    def previous_nightly_status(self, check_id: str, before_run: int) -> str | None:
        """The status of `check_id` in the most recent earlier run that ran it (so a partial run does not erase history)."""
        rows = self._all("SELECT status FROM nightly_results WHERE check_id=? AND run<? ORDER BY run DESC LIMIT 1",
                         (check_id, before_run))
        return rows[0]["status"] if rows else None

    def nightly_running(self) -> bool:
        return bool(self._all("SELECT 1 FROM nightly_runs WHERE ended IS NULL"))

    # checks / interventions / alerts ---------------------------------------------------------------------------------
    def record_check(self, ticket: int, sha: str, check_id: str, result: str, counts: dict[str, Any], log: str) -> None:
        self._exec("INSERT INTO checks(ticket,sha,check_id,result,counts,log,at) VALUES (?,?,?,?,?,?,?)",
                   (ticket, sha, check_id, result, json.dumps(counts), log, self.clock()))

    def checks(self, ticket: int, sha: str | None = None) -> list[dict[str, Any]]:
        if sha:
            rows = self._all("SELECT * FROM checks WHERE ticket=? AND sha=? ORDER BY id", (ticket, sha))
        else:
            rows = self._all("SELECT * FROM checks WHERE ticket=? ORDER BY id", (ticket,))
        return [dict(r) for r in rows]

    def intervention(self, ticket: int | None, kind: str, stage: str | None = None) -> None:
        self._exec("INSERT INTO interventions(ticket,kind,at,stage) VALUES (?,?,?,?)", (ticket, kind, self.clock(), stage))

    def open_alert(self, key: str, text: str) -> bool:
        """True when the alert is new (open once, keyed by condition)."""
        rows = self._all("SELECT closed FROM alerts WHERE key=?", (key,))
        if rows and rows[0]["closed"] is None:
            return False
        self._exec("INSERT INTO alerts(key,text,opened) VALUES (?,?,?) "
                   "ON CONFLICT(key) DO UPDATE SET text=excluded.text, opened=excluded.opened, escalated=NULL, closed=NULL",
                   (key, text, self.clock()))
        self.event("alert", None, key=key, text=text)
        return True

    def close_alert(self, key: str) -> None:
        self._exec("UPDATE alerts SET closed=? WHERE key=? AND closed IS NULL", (self.clock(), key))
