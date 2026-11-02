"""Spoken alerts from the daemon: a sound, then a voice, for a ticket that landed or needs the owner.

The daemon runs in the owner's GUI session, so `afplay` and `say` reach the speakers. Everything here is off the stage's
path: `announce` only queues, one worker thread plays the announcements one after another (two never talk over each other),
and a missing, failing or slow binary is swallowed.
"""

from __future__ import annotations

import logging
import queue
import subprocess
import threading
from typing import Literal, Protocol

log = logging.getLogger("starpipe.announce")

Kind = Literal["landed", "attention"]
AFPLAY, SAY = "/usr/bin/afplay", "/usr/bin/say"
# kind -> (sound, voice, sentence)
CLIPS: dict[str, tuple[str, str, str]] = {
    "landed": ("/System/Library/Sounds/Glass.aiff", "Samantha", "Star issue number {n} has landed"),
    "attention": ("/System/Library/Sounds/Sosumi.aiff", "Daniel", "Star issue number {n} needs your attention"),
}
TIMEOUT_S = 30


class Announcer(Protocol):
    def announce(self, kind: Kind, n: int) -> None: ...


class SilentAnnouncer:
    """The default: makes no sound (so a stray Engine in a test or script is quiet)."""

    def announce(self, kind: Kind, n: int) -> None:
        pass


class SayAnnouncer:
    def __init__(self) -> None:
        self._queue: queue.Queue[tuple[Kind, int]] = queue.Queue()
        self._worker: threading.Thread | None = None
        self._lock = threading.Lock()

    def announce(self, kind: Kind, n: int) -> None:
        with self._lock:
            if self._worker is None:
                self._worker = threading.Thread(target=self._drain, name="announcer", daemon=True)  # never holds up shutdown
                self._worker.start()
        self._queue.put((kind, n))

    def _drain(self) -> None:
        while True:
            kind, n = self._queue.get()
            try:
                self.play(kind, n)
            except Exception:
                log.warning("announcement %s #%d failed", kind, n, exc_info=True)

    @staticmethod
    def play(kind: Kind, n: int) -> None:
        sound, voice, sentence = CLIPS[kind]
        for argv in ([AFPLAY, sound], [SAY, "-v", voice, sentence.format(n=n)]):
            try:
                subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               timeout=TIMEOUT_S, check=False)
            except (OSError, subprocess.SubprocessError):
                log.warning("%s failed", argv[0], exc_info=True)
