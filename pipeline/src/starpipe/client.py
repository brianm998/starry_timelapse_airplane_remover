"""The CLI's side of the local API (plan §12). Mutations go through the daemon; reads fall back to the database."""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any, cast

from .config import Config, token_path
from .db import Database, db_path


class DaemonDown(RuntimeError):
    pass


class Client:
    def __init__(self, config: Config) -> None:
        self.base = f"http://127.0.0.1:{config.api_port}"

    def call(self, method: str, path: str, body: dict[str, Any] | None = None) -> Any:
        try:
            token = token_path().read_text().strip()
        except OSError as exc:
            raise DaemonDown("no api token: the daemon has never run") from exc
        req = urllib.request.Request(self.base + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            raise RuntimeError(f"{exc.code}: {exc.read().decode(errors='replace')}") from exc
        except OSError as exc:
            raise DaemonDown(f"the daemon is not answering on {self.base}") from exc


def offline_status() -> dict[str, Any]:
    """`status` with the daemon down: the database, read-only."""
    if not db_path().exists():
        return {"daemon": None, "tickets": []}
    db = Database(read_only=True)
    tickets: list[dict[str, Any]] = [{"number": t.number, "title": t.title, "state": t.state, "priority": t.priority, "activity": t.state,
                "blocked_by": []} for t in db.tickets() if t.state not in ("landed", "closed", "cancelled")]
    return cast("dict[str, Any]", {"daemon": None, "pause": db.get("pause"), "tickets": tickets})
