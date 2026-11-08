"""gherkin/hang-watchdog.sh: dumps when stard's log goes quiet, says nothing while it grows (ticket #54)."""
from __future__ import annotations

import os
import subprocess
import time
import uuid
from collections.abc import Iterator
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "gherkin" / "hang-watchdog.sh"
BANNER = "stard hang watchdog: dump"
NAME = f"fakestardwd-{uuid.uuid4().hex}"  # per run: another ticket's checks run this file at the same time, and pgrep -f matches theirs too


@pytest.fixture
def fake_stard(tmp_path: Path) -> Iterator[tuple[subprocess.Popen[bytes], Path]]:
    """A process (a script, since a copied system binary is killed on macOS) matched by NAME and whose command line carries `--scratch <tmp>`; its log is <tmp>/logs/stard.log."""
    exe = tmp_path / NAME
    exe.write_text("#!/bin/bash\nsleep 120\n")
    exe.chmod(0o755)
    scratch = tmp_path / "scratch"
    (scratch / "logs").mkdir(parents=True)
    log = scratch / "logs" / "stard.log"
    log.write_text("starAlignment(complete)\nResourceGovernor: CPU gate 2/2\n")
    proc = subprocess.Popen([str(exe), "--scratch", str(scratch)])
    yield proc, log
    proc.kill()
    proc.wait()


def watch(seconds: float, limit: int = 2, path_prefix: str = "") -> str:
    """Run the watchdog for `seconds`, then stop it and return its output."""
    env = {**os.environ, "HANG_WATCHDOG_PGREP": f"-f {NAME}"}
    if path_prefix:
        env["PATH"] = path_prefix + os.pathsep + env["PATH"]
    p = subprocess.Popen(["bash", str(SCRIPT), str(limit), "1"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
    time.sleep(seconds)
    p.terminate()
    out, _ = p.communicate(timeout=30)
    return out


def testWatchdogDumpsWhenStardLogGoesQuiet(fake_stard: tuple[subprocess.Popen[bytes], Path], tmp_path: Path) -> None:
    proc, _log = fake_stard
    # The machine's real JVMs (Gradle daemons, Android Studio, another job's test worker) would make this timing depend on how many are
    # running; a jps that lists none keeps it deterministic.  testWatchdogBoundsEachJvmDump covers the jstack loop.
    shims = tmp_path / "nojvms"
    shims.mkdir()
    (shims / "jps").write_text("#!/bin/bash\nexit 0\n")
    (shims / "jps").chmod(0o755)
    out = watch(9, path_prefix=str(shims))
    assert out.count(BANNER) >= 1, out
    assert out.count(BANNER) <= 2, out  # a first dump and one more, then silence for that pid
    assert f"pid {proc.pid}" in out
    assert "--- ps" in out
    assert str(proc.pid) in out.split("--- ps", 1)[1]
    assert "ResourceGovernor: CPU gate 2/2" in out  # the log tail
    assert "--- jstack of every JVM" in out  # tools that are absent degrade to a note, the dump still completes
    assert "::endgroup::" in out


def testWatchdogBoundsEachJvmDump(fake_stard: tuple[subprocess.Popen[bytes], Path], tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """macOS has no `timeout`, so a jstack of a big JVM (Android Studio, Gradle daemons) used to be unbounded and the dump never
    reached ::endgroup::.  Shims for jps (three live "JVMs") and a jstack that never answers: each is cut off after HANG_WATCHDOG_JVM_SECONDS."""
    jvms = [subprocess.Popen(["sleep", "60"]) for _ in range(3)]
    try:
        shims = tmp_path / "jvmshims"
        shims.mkdir()
        for name, body in {"jps": "".join(f"echo {j.pid}\n" for j in jvms), "jstack": "exec sleep 30\n"}.items():
            shim = shims / name
            shim.write_text("#!/bin/bash\n" + body)
            shim.chmod(0o755)
        monkeypatch.setenv("HANG_WATCHDOG_JVM_SECONDS", "1")
        out = watch(9, path_prefix=str(shims))
    finally:
        for j in jvms:
            j.kill()
            j.wait()
    assert out.count("== jvm") >= 3, out
    assert "::endgroup::" in out, out


def testWatchdogRunsGdbAndStacksThroughTimeout(fake_stard: tuple[subprocess.Popen[bytes], Path], tmp_path: Path) -> None:
    """`timeout` is an external program: handing it a shell function fails with 'failed to run command' (Linux has timeout, macOS
    does not).  Shims named timeout, sudo and gdb, first on PATH, make this run the Linux path: the gdb section must get through them."""
    shims = tmp_path / "shims"
    shims.mkdir()
    for name, body in {
        "timeout": 'shift\nexec "$@"\n',  # like the real one: runs a program, cannot run a function
        "sudo": 'shift\nexec "$@"\n',  # `sudo -n <cmd>`
        "gdb": 'echo "GDB-SHIM-RAN $*"\n',
    }.items():
        shim = shims / name
        shim.write_text("#!/bin/bash\n" + body)
        shim.chmod(0o755)
    out = watch(7, path_prefix=str(shims))
    gdb = out.split("--- gdb backtrace", 1)[1].split("--- tail of", 1)[0]
    assert "GDB-SHIM-RAN -p" in gdb, out
    assert "failed to run command" not in out, out
    assert "not found" not in gdb, out


def testWatchdogStaysSilentWhileStardLogGrows(fake_stard: tuple[subprocess.Popen[bytes], Path]) -> None:
    _proc, log = fake_stard
    grower = subprocess.Popen(["bash", "-c", f"while :; do echo tick >> '{log}'; sleep 0.5; done"])
    try:
        out = watch(7)
    finally:
        grower.kill()
        grower.wait()
    assert BANNER not in out, out


def testWatchdogWritesDumpsToOutFile(fake_stard: tuple[subprocess.Popen[bytes], Path], tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """HANG_WATCHDOG_OUT: the dump also lands in a file (CI uploads it; a cancelled job's log is lost).  Unset, nothing is written."""
    shims = tmp_path / "nojvms"
    shims.mkdir()
    (shims / "jps").write_text("#!/bin/bash\nexit 0\n")
    (shims / "jps").chmod(0o755)
    dumps = tmp_path / "out" / "hang-watchdog.log"
    dumps.parent.mkdir()
    monkeypatch.setenv("HANG_WATCHDOG_OUT", str(dumps))
    out = watch(7, path_prefix=str(shims))
    assert BANNER in out, out
    text = dumps.read_text()
    assert BANNER in text
    assert "--- ps" in text
    assert "ResourceGovernor: CPU gate 2/2" in text  # the log tail
    assert text.count(BANNER) == out.count(BANNER)

    monkeypatch.delenv("HANG_WATCHDOG_OUT")
    dumps.unlink()
    assert BANNER in watch(7, path_prefix=str(shims))
    assert not dumps.exists()


def testWatchdogDumpsStardOnWindows(fake_stard: tuple[subprocess.Popen[bytes], Path], tmp_path: Path) -> None:
    """Git Bash has no pgrep and MSYS cannot signal Windows pids.  Shims for uname (MINGW64), powershell (a stard.exe row with
    `--scratch <dir>`, a thread table), cygpath and a jps printing a pid no MSYS `kill -0` can see: stard is found without pgrep, the dump
    has the thread table, the stard.log tail and the JVM (so the kill -0 guard is skipped)."""
    proc, log = fake_stard
    scratch = log.parent.parent
    shims = tmp_path / "winshims"
    shims.mkdir()
    for name, body in {
        "uname": 'echo MINGW64_NT-10.0-20348\n',
        "powershell": (
            'case "$*" in\n'
            f'  *Win32_Process*) printf \'{proc.pid}\\t"C:\\\\x\\\\stard.exe" --scratch "{scratch}"\\r\\n\' ;;\n'
            '  *Threads*) echo "THREAD-TABLE-SHIM Wait UserRequest" ;;\n'
            '  *) echo "PROCESS-TABLE-SHIM" ;;\n'
            'esac\n'
        ),
        "cygpath": 'for a; do :; done\necho "$a"\n',
        "pgrep": "exit 1\n",  # stard must not be found through pgrep
        "jps": "echo 4999999\n",
        "jstack": 'echo "JSTACK-SHIM $1"\n',
    }.items():
        shim = shims / name
        shim.write_text("#!/bin/bash\n" + body)
        shim.chmod(0o755)
    out = watch(9, path_prefix=str(shims))
    assert BANNER in out, out
    assert f"pid {proc.pid}" in out
    assert "THREAD-TABLE-SHIM" in out, out
    assert "PROCESS-TABLE-SHIM" in out, out
    assert "ResourceGovernor: CPU gate 2/2" in out  # the log tail, found through the --scratch of the command line
    assert "== jvm 4999999" in out, out
    assert "JSTACK-SHIM 4999999" in out, out
    assert "--- gdb backtrace" not in out


def dump_now(path_prefix: str = "", why: str = "") -> str:
    env = {**os.environ, "HANG_WATCHDOG_PGREP": f"-f {NAME}"}
    if path_prefix:
        env["PATH"] = path_prefix + os.pathsep + env["PATH"]
    args = ["bash", str(SCRIPT), "--dump-now"] + ([why] if why else [])
    return subprocess.run(args, check=False, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, timeout=120).stdout


def testDumpNowDumpsAtOnceWithStardQuiet(fake_stard: tuple[subprocess.Popen[bytes], Path], tmp_path: Path) -> None:
    """--dump-now (ticket #415) dumps once and exits without waiting for stard's log to go quiet; here it is not even stale."""
    proc, _log = fake_stard
    shims = tmp_path / "nojvms"
    shims.mkdir()
    (shims / "jps").write_text("#!/bin/bash\nexit 0\n")
    (shims / "jps").chmod(0o755)
    start = time.time()
    out = dump_now(str(shims), "uiX ran 5s")
    assert time.time() - start < 30
    assert out.count(BANNER) == 1, out
    assert f"pid {proc.pid}" in out and "uiX ran 5s" in out, out
    assert "ResourceGovernor: CPU gate 2/2" in out  # the log tail
    assert "--- jstack of every JVM" in out
    assert "::endgroup::" in out


def testDumpNowWithoutStardStillDumpsTheJvms(tmp_path: Path) -> None:
    """The Windows hang had no wedged stard to find: the dump must still list the JVMs' stacks."""
    jvm = subprocess.Popen(["sleep", "60"])  # off Windows the dump skips a pid that is not alive
    try:
        shims = tmp_path / "shims"
        shims.mkdir()
        for name, body in {"jps": f"echo {jvm.pid}\n", "jstack": 'echo "JSTACK-SHIM $1"\n', "pgrep": "exit 1\n"}.items():
            (shims / name).write_text("#!/bin/bash\n" + body)
            (shims / name).chmod(0o755)
        out = dump_now(str(shims))
    finally:
        jvm.kill()
        jvm.wait()
    assert BANNER in out and "pid none" in out, out
    assert "no stard is running" in out, out
    assert f"JSTACK-SHIM {jvm.pid}" in out, out
    assert "::endgroup::" in out
    assert "--- tail of" not in out
