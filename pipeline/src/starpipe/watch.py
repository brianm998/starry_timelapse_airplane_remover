"""The process watch (plan §9.2): find stalled work by pid with psutil, never by command-line substring.

Two rules, per target (a stage session's CLI, or a heavy-lock holder), judged on the whole process tree under it:
* silent more than `cont_after` and a descendant is stopped (state T): SIGCONT its own descendants (memory
  processes-sigstopped-on-this-mac), and count it;
* silent more than `kill_after` with no progress at all: kill the tree, so the attempt ladder takes over.
A target waiting in the heavy-lock queue is not stalled, so a tree that holds a queued waiter is never killed for silence.
Progress is CPU movement anywhere in the tree (psutil has no IO counters on macOS), or new output (the caller's `activity`).
"""

from __future__ import annotations

import os
import signal
import time
from collections.abc import Callable
from dataclasses import dataclass, field

import psutil

CONT_AFTER_S = 10 * 60
KILL_AFTER_S = 30 * 60
CPU_EPSILON = 0.05


@dataclass
class Target:
    label: str
    pid: int
    activity: Callable[[], float] = lambda: 0.0  # mtime of the last output, 0 when unknown
    waiting_pids: frozenset[int] = frozenset()  # heavy-lock waiters: a tree holding one is queued, not hung


@dataclass
class Tree:
    pids: list[int]  # the root first, then its descendants
    stopped: list[int]
    cpu: float


@dataclass
class Action:
    kind: str  # sigcont | kill
    label: str
    pids: list[int]


@dataclass
class _State:
    last_progress: float
    cpu: float = 0.0
    activity: float = 0.0
    conts: int = 0


Snapshot = Callable[[int], Tree | None]
Signal = Callable[[int, int], None]


def snapshot(pid: int) -> Tree | None:
    """The tree under `pid` as psutil sees it; None when it is gone."""
    try:
        root = psutil.Process(pid)
        procs = [root, *root.children(recursive=True)]
    except psutil.Error:
        return None
    pids: list[int] = []
    stopped: list[int] = []
    cpu = 0.0
    for p in procs:
        try:
            times = p.cpu_times()
            cpu += times.user + times.system
            if p.status() == psutil.STATUS_STOPPED:
                stopped.append(p.pid)
            pids.append(p.pid)
        except psutil.Error:
            continue
    return Tree(pids, stopped, cpu)


def _send(pid: int, sig: int) -> None:
    try:
        os.kill(pid, sig)
    except ProcessLookupError:
        pass


@dataclass
class Watch:
    cont_after: float = CONT_AFTER_S
    kill_after: float = KILL_AFTER_S
    snap: Snapshot = snapshot
    send: Signal = _send
    states: dict[str, _State] = field(default_factory=lambda: dict[str, _State]())
    sigconts: int = 0

    def tick(self, targets: list[Target], now: float | None = None) -> list[Action]:
        now = time.time() if now is None else now
        actions: list[Action] = []
        live: set[str] = set()
        for t in targets:
            tree = self.snap(t.pid)
            if tree is None:
                continue
            live.add(t.label)
            st = self.states.setdefault(t.label, _State(now, tree.cpu, t.activity()))
            activity = t.activity()
            if tree.cpu > st.cpu + CPU_EPSILON or activity > st.activity:
                st.last_progress = now
            st.cpu, st.activity = tree.cpu, activity
            silent = now - st.last_progress
            descendants = [p for p in tree.stopped if p != t.pid]
            if silent > self.cont_after and descendants:
                for pid in descendants:
                    self.send(pid, signal.SIGCONT)
                st.conts += 1
                self.sigconts += 1
                actions.append(Action("sigcont", t.label, descendants))
            elif silent > self.kill_after and not (t.waiting_pids & set(tree.pids)):
                for pid in reversed(tree.pids):  # leaves first, so a parent cannot respawn what we just killed
                    self.send(pid, signal.SIGKILL)
                actions.append(Action("kill", t.label, tree.pids))
                self.states.pop(t.label, None)
        for gone in set(self.states) - live:
            del self.states[gone]
        return actions
