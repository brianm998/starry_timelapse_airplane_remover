"""What limits starting work: CPU use and how many LLM sessions are running (owner's rule, 2026-10-31), not a fixed number of tickets.

Measured CPU utilisation, never the load average: on this Mac the load average sits at 20 to 27 because of other sessions and would
block everything for good. CPU is judged on a rolling average (one busy second is not a reason to wait), and it is only a reason to wait
while something else is already running, so the pipeline can never stall itself.
"""

from __future__ import annotations

import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, field

import psutil


@dataclass
class CpuMeter:
    window_s: float = 60.0
    clock: Callable[[], float] = time.monotonic
    sampler: Callable[[], float] = lambda: psutil.cpu_percent(interval=None)
    samples: deque[tuple[float, float]] = field(default_factory=lambda: deque[tuple[float, float]]())

    def sample(self) -> None:
        now = self.clock()
        self.samples.append((now, self.sampler()))
        while self.samples and now - self.samples[0][0] > self.window_s:
            self.samples.popleft()

    def average(self) -> float:
        """Mean CPU % over the window, or 0 when nothing has been sampled yet (it does not block before it knows)."""
        if not self.samples:
            return 0.0
        return sum(v for _, v in self.samples) / len(self.samples)


@dataclass
class Room:
    ok: bool
    reason: str = ""
    llm_active: int = 0
    cpu: float = 0.0


def room(active: int, cpu: float, max_sessions: int, cpu_limit: float) -> Room:
    """May another LLM session start? Always yes when none is running; else only under both limits."""
    if active <= 0:
        return Room(True, "", active, cpu)
    if active >= max_sessions:
        return Room(False, f"{active} of {max_sessions} LLM sessions are running", active, cpu)
    if cpu >= cpu_limit:
        return Room(False, f"CPU is at {cpu:.0f}% (limit {cpu_limit:.0f}%)", active, cpu)
    return Room(True, "", active, cpu)
