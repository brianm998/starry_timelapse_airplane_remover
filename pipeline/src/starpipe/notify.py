"""Notifications (plan §11): alerts are keyed by condition and open once; ntfy pages are optional."""

from __future__ import annotations

import urllib.request
from collections.abc import Callable

from .config import home
from .db import Database

PAGES = {"needs-input", "develop-red", "phantom-landing", "daemon-down", "runtime-rollback", "self-update-failed"}
Sender = Callable[[str, str], None]


def ntfy_url() -> str | None:
    f = home() / "ntfy.env"
    if f.exists():
        for line in f.read_text().splitlines():
            key, _, value = line.strip().partition("=")
            if key.removeprefix("export ").strip() == "STARPIPE_NTFY_URL" and value:
                return value.strip().strip("\"'")
    return None


def send_ntfy(title: str, text: str) -> None:
    url = ntfy_url()
    if url:
        req = urllib.request.Request(url, data=text.encode(), headers={"Title": title})
        urllib.request.urlopen(req, timeout=10).close()


class Notifier:
    def __init__(self, db: Database, send: Sender = send_ntfy) -> None:
        self.db, self.send = db, send

    def alert(self, kind: str, ticket: int | None, text: str) -> None:
        key = f"{kind}:{ticket}" if ticket is not None else kind
        if self.db.open_alert(key, text) and kind in PAGES:
            try:
                self.send(f"star pipeline: {kind}", text)
            except OSError:
                pass  # a failed page must never take a stage down

    def clear(self, kind: str, ticket: int | None) -> None:
        self.db.close_alert(f"{kind}:{ticket}" if ticket is not None else kind)
