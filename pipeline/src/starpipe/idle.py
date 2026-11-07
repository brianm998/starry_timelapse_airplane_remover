"""How long the owner has left the keyboard and mouse alone, so a UI test run (XCUITest drives the real cursor and keyboard, and
keeps a window on the display) starts only when nobody is using this Mac.

`hid_idle_seconds` reads IOHIDSystem's HIDIdleTime, the same figure the screensaver uses. Every outside effect of `wait_until_idle`
is injected, so the tests run it without a Mac or a clock."""

from __future__ import annotations

import re
import subprocess
import time
from collections.abc import Callable

_HID_IDLE = re.compile(r'"HIDIdleTime"\s*=\s*(\d+)')


def hid_idle_seconds() -> float | None:
    """Seconds since the last key or mouse event, or None when it cannot be read (not a Mac, ioreg missing or failing)."""
    try:
        out = subprocess.run(["ioreg", "-c", "IOHIDSystem", "-d", "4"], capture_output=True, text=True, timeout=10, check=False).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    found = _HID_IDLE.search(out)
    return int(found.group(1)) / 1e9 if found else None


def is_idle(need_s: float, read: Callable[[], float | None] = hid_idle_seconds) -> bool:
    """Idle for `need_s`. An unreadable idle time counts as idle: a gate that cannot see would otherwise hold work for ever."""
    seen = read()
    return seen is None or seen >= need_s


def wait_until_idle(
    need_s: float,
    *,
    poll_s: float = 15.0,
    report: Callable[[str], None] | None = None,
    report_every_s: float = 300.0,
    read: Callable[[], float | None] = hid_idle_seconds,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> float:
    """Block until the keyboard and mouse have been idle for `need_s`; the seconds spent waiting."""
    started = clock()
    last_report = started
    announced = False
    while not is_idle(need_s, read):
        now = clock()
        if report and (not announced or now - last_report >= report_every_s):
            announced, last_report = True, now
            report(f"holding a UI test run until the keyboard and mouse have been idle {need_s:.0f}s "
                   f"(idle now {read() or 0:.0f}s, waited {now - started:.0f}s)")
        sleep(poll_s)
    return clock() - started
