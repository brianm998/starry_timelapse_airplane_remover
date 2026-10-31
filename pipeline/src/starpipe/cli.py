"""The starpipe command line (plan §12)."""

from __future__ import annotations

import json
import os
import plistlib
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import click

from . import config as config_mod
from . import doctor as doctor_mod
from . import gitutil, heavy
from .checks import impact, runner


def _say(message: str) -> None:
    click.echo(message, err=True)


@click.group()
@click.version_option(package_name="starpipe", prog_name="starpipe")
def main() -> None:
    """Automated development pipeline for star."""


@main.command(context_settings={"ignore_unknown_options": True})
@click.option("--priority", type=click.IntRange(0, 2), default=None,
              help="0 interactive, 1 pipeline, 2 nightly (default: from STARPIPE_TICKET / STARPIPE_NIGHTLY)")
@click.option("--status", "show_status", is_flag=True, help="Show the holder and the queue, then exit.")
@click.argument("command", nargs=-1, type=click.UNPROCESSED)
def heavy_cmd(priority: int | None, show_status: bool, command: tuple[str, ...]) -> None:
    """Run COMMAND under the machine-wide heavy-job lock: starpipe heavy -- swift test ..."""
    if show_status:
        st = heavy.status()
        for h in st.holders:
            click.echo(f"holder  {h.ticket or 'interactive'}  {h.cmd}")
        for i, w in enumerate(st.queue, 1):
            click.echo(f"queue {i}  p{w.priority}  {w.ticket or 'interactive'}  {w.cmd}")
        if not st.holders and not st.queue:
            click.echo("idle")
        return
    if not command:
        raise click.UsageError("no command given")
    code, _wait = heavy.run(list(command), priority=priority, report=_say)
    sys.exit(code)


main.add_command(heavy_cmd, "heavy")


@main.command()
@click.option("--tier", type=click.Choice(["t0", "t1", "all"]), default="all", show_default=True)
@click.option("--diff", "base", default=None, help="Base ref (default origin/develop, else develop).")
@click.option("--paths", multiple=True, help="Explain / run for these paths instead of the git diff.")
@click.option("--explain", is_flag=True, help="Print which checks the change triggers and why; run nothing.")
@click.option("--allow-skips", is_flag=True, help="Do not treat skipped tests as red.")
@click.option("--worktree", type=click.Path(exists=True, file_okay=False, path_type=Path), default=Path.cwd)
@click.option("--json", "as_json", is_flag=True)
def check(tier: str, base: str | None, paths: tuple[str, ...], explain: bool, allow_skips: bool,
          worktree: Path, as_json: bool) -> None:
    """Run (or explain) the checks a change needs."""
    root = gitutil.repo_root(worktree)
    base_ref = gitutil.resolve_base(root, base)
    changed = list(paths) or gitutil.changed_paths(root, base_ref)
    plan = impact.plan_for(changed)
    tiers = {"t0", "t1"} if tier == "all" else {tier}

    if explain:
        if as_json:
            click.echo(json.dumps({"changed": changed, "t0": plan.t0, "builds": plan.builds,
                                   "tests": plan.tests, "reasons": plan.reasons, "unmapped": plan.unmapped}))
            return
        click.echo(f"{len(changed)} changed path(s) against {base_ref}")
        for label, ids in (("T0", plan.t0), ("T1 build", plan.builds), ("T1 test", plan.tests)):
            for check_id in ids:
                why = "; ".join(plan.reasons.get(check_id, []))
                click.echo(f"  {label:<9}{check_id:<24}{why}")
        for note in plan.notes:
            click.echo(f"  note     {note}")
        for path in plan.unmapped:
            click.echo(f"  WARNING  {path} matches no rule in adapter_star.RULES")
        if not plan.t1():
            click.echo("  (no build or test needed)")
        return

    results = runner.run_plan(plan, root, base_ref, tiers, allow_skips=allow_skips, say=_say)
    if as_json:
        click.echo(json.dumps([r.__dict__ for r in results]))
    expected = ([*plan.t0] if "t0" in tiers else []) + (plan.t1() if "t1" in tiers else [])
    sys.exit(0 if len(results) == len(expected) and all(r.green for r in results) else 1)


@main.command()
@click.option("--worktree", type=click.Path(exists=True, file_okay=False, path_type=Path), default=Path.cwd)
def doctor(worktree: Path) -> None:
    """Check the owner's prerequisites and the tools the pipeline needs."""
    findings = doctor_mod.run(gitutil.repo_root(worktree))
    marks = {"ok": "ok  ", "warn": "warn", "fail": "FAIL"}
    for f in findings:
        click.echo(f"{marks[f.level]}  {f.name:<32}{f.detail}")
    sys.exit(doctor_mod.exit_code(findings))


@main.group()
def gh() -> None:
    """GitHub setup."""


@gh.command("setup")
def gh_setup() -> None:
    """Create the pipeline's labels (idempotent)."""
    from .github import GitHub, GitHubError

    try:
        created, present = GitHub(config_mod.load()).ensure_labels()
    except GitHubError as exc:
        raise click.ClickException(str(exc)) from exc
    click.echo(f"created {len(created)} label(s)" + (": " + ", ".join(created) if created else ""))
    click.echo(f"{len(present)} already present")


@main.group()
def ticket() -> None:
    """File and check pipeline tickets."""


def _read_body(body_file: Path) -> str:
    return sys.stdin.read() if str(body_file) == "-" else body_file.read_text()


@ticket.command("lint")
@click.argument("file", type=click.Path(path_type=Path))
def ticket_lint(file: Path) -> None:
    """Check a ticket body against plan §6.3 (FILE may be - for stdin)."""
    from . import tickets

    result = tickets.lint(_read_body(file))
    for message in result.errors:
        click.echo(f"error    {message}")
    for message in result.warnings:
        click.echo(f"warning  {message}")
    if result.ok:
        click.echo("ok")
    sys.exit(0 if result.ok else 1)


@ticket.command("new")
@click.option("--title", required=True)
@click.option("--body-file", required=True, type=click.Path(path_type=Path), help="Ticket body; - for stdin.")
@click.option("--blocked-by", default="", help="Comma-separated issue numbers that must land first.")
@click.option("--priority", type=click.Choice(["p0", "p1", "p2", "p3"]), default=None)
@click.option("--propose", is_flag=True, help="File it for the owner to approve (starpipe approve) instead of running it.")
@click.option("--by", default=None, help="Who is filing (default: $STARPIPE_AGENT, else 'interactive').")
@click.option("--force", is_flag=True, help="File even if an open issue has a near-identical title.")
def ticket_new(title: str, body_file: Path, blocked_by: str, priority: str | None, propose: bool, by: str | None,
               force: bool) -> None:
    """Lint, file, label and link a ticket; prints its number and URL."""
    from . import tickets
    from .github import GitHub

    try:
        blockers = [int(n.lstrip("#")) for n in blocked_by.split(",") if n.strip()]
    except ValueError as exc:
        raise click.BadParameter("expected numbers like 41,42", param_hint="--blocked-by") from exc
    cfg = config_mod.load()
    try:
        number = tickets.file_ticket(GitHub(cfg), title, _read_body(body_file), blockers, priority, propose=propose,
                                     by=by or os.environ.get("STARPIPE_AGENT") or "interactive", force=force,
                                     max_open=cfg.max_open_tickets, max_proposed=cfg.max_proposed)
    except tickets.FilingError as exc:
        raise click.ClickException(str(exc)) from exc
    click.echo(f"#{number} https://github.com/{cfg.owner}/{cfg.repo}/issues/{number}" + (" (proposed)" if propose else ""))


def _num(value: str) -> int:
    return int(value.lstrip("#"))


@main.command()
def proposals() -> None:
    """The tickets waiting for the owner's approval, and who filed each."""
    from . import tickets
    from .github import GitHub, GitHubError

    try:
        found = tickets.proposals(GitHub(config_mod.load()))
    except GitHubError as exc:
        raise click.ClickException(str(exc)) from exc
    for p in found:
        click.echo(f"#{p.number:<5} {p.title[:70]:<70}  by {p.by}")
    if not found:
        click.echo("no proposals waiting")


@main.command()
@click.argument("numbers", nargs=-1, required=True, type=_num)
@click.option("--priority", type=click.Choice(["p0", "p1", "p2", "p3"]), default=None)
def approve(numbers: tuple[int, ...], priority: str | None) -> None:
    """Approve proposed tickets: they join the pipeline's queue."""
    from . import tickets
    from .github import GitHub

    cfg = config_mod.load()
    for n in numbers:
        try:
            tickets.approve(GitHub(cfg), n, priority, cfg.max_open_tickets)
        except tickets.FilingError as exc:
            raise click.ClickException(str(exc)) from exc
        click.echo(f"#{n} approved")


@main.command()
@click.argument("number", type=_num)
@click.argument("reason", required=False, default="")
def reject(number: int, reason: str) -> None:
    """Turn a proposal down: comment, close as not planned."""
    from . import tickets
    from .github import GitHub

    try:
        tickets.reject(GitHub(config_mod.load()), number, reason)
    except tickets.FilingError as exc:
        raise click.ClickException(str(exc)) from exc
    click.echo(f"#{number} rejected")


def _client() -> Any:
    from . import client as client_mod

    return client_mod.Client(config_mod.load())


def _post(path: str, body: dict[str, object] | None = None) -> None:
    from . import client as client_mod

    try:
        _client().call("POST", path, body or {})
    except (client_mod.DaemonDown, RuntimeError) as exc:
        raise click.ClickException(str(exc)) from exc
    click.echo("ok")


@main.command()
@click.option("--json", "as_json", is_flag=True)
def status(as_json: bool) -> None:
    """Daemon health, the heavy lock, and the tickets with what each is doing."""
    from . import client as client_mod

    data: dict[str, Any]
    try:
        data = _client().call("GET", "/v1/status")
    except client_mod.DaemonDown as exc:
        data = client_mod.offline_status()
        click.echo(f"daemon down ({exc}); showing the database", err=True)
    if as_json:
        click.echo(json.dumps(data))
        return
    if data.get("daemon"):
        d = data["daemon"]
        click.echo(f"daemon up, pid {d['pid']}" + (f"  last error: {d['error']}" if d.get("error") else ""))
    if data.get("pause"):
        click.echo(f"PAUSED: {data['pause']}")
    if data.get("usage_pause_until"):
        click.echo(f"usage limit: model stages wait until {time.ctime(float(data['usage_pause_until']))}")
    heavy_state: dict[str, Any] = data.get("heavy") or {}
    for h in heavy_state.get("holders", []):
        click.echo(f"heavy lock: {h['ticket'] or 'interactive'}  {h['cmd']}")
    for i, w in enumerate(heavy_state.get("queue", []), 1):
        click.echo(f"  queued {i}: p{w['priority']} {w['ticket'] or 'interactive'}  {w['cmd']}")
    for t in data["tickets"]:
        click.echo(f"#{t['number']:<5} p{t['priority']}  {t['title'][:48]:<48}  {t['activity']}")
    if not data["tickets"]:
        click.echo("no tickets in flight")


@main.command()
@click.argument("number", type=_num)
@click.option("--json", "as_json", is_flag=True)
def show(number: int, as_json: bool) -> None:
    """A ticket's plan, stages with times, checks and question."""
    from . import client as client_mod

    try:
        t = _client().call("GET", f"/v1/tickets/{number}")
    except (client_mod.DaemonDown, RuntimeError) as exc:
        raise click.ClickException(str(exc)) from exc
    if as_json:
        click.echo(json.dumps(t))
        return
    click.echo(f"#{t['number']} {t['title']}  [{t['state']}]  {t['activity']}")
    if t.get("branch"):
        click.echo(f"branch {t['branch']}")
    if t.get("plan"):
        click.echo(f"plan: {t['plan']['summary']}")
    for s in t["stages"]:
        took = (s["ended"] or time.time()) - s["started"]
        wait = f" (+{s['lock_wait_s'] / 60:.0f}m lock wait)" if s["lock_wait_s"] >= 60 else ""
        click.echo(f"  {s['stage']:<8} attempt {s['attempt']}  {s['model']:<6} {took / 60:5.1f}m{wait}  {s['outcome'] or 'running'}")
    for c in t["checks"][-8:]:
        click.echo(f"  check {c['check_id']:<22}{c['result']}")
    if t.get("question"):
        click.echo(f"question: {t['question']['text']}")


@main.command()
@click.argument("number", type=_num)
@click.argument("text")
def answer(number: int, text: str) -> None:
    """Answer a ticket's open question (same effect as an owner comment on the issue)."""
    _post(f"/v1/tickets/{number}/answer", {"text": text})


@main.command()
@click.argument("number", type=_num)
@click.argument("stage", required=False, default="explore")
def retry(number: int, stage: str) -> None:
    """Re-run from a stage, keeping the branch and plan."""
    _post(f"/v1/tickets/{number}/retry", {"stage": stage})


@main.command()
@click.argument("numbers", nargs=-1, required=True, type=_num)
def requeue(numbers: tuple[int, ...]) -> None:
    """Move tickets from their own PR and CI onto the landing train (their PRs are closed; the next batch carries them)."""
    for n in numbers:
        _post(f"/v1/tickets/{n}/requeue", {})


@main.command()
@click.argument("number", type=_num)
@click.argument("reason", required=False, default="")
def cancel(number: int, reason: str) -> None:
    """Stop the ticket and keep its branch."""
    _post(f"/v1/tickets/{number}/cancel", {"reason": reason})


@main.command()
@click.argument("number", type=_num)
@click.argument("priority", type=click.Choice(["p0", "p1", "p2", "p3"]))
def prio(number: int, priority: str) -> None:
    """Change a ticket's priority (rewrites the label)."""
    _post(f"/v1/tickets/{number}/prio", {"priority": int(priority[1])})


@main.command()
@click.argument("scope", type=click.Choice(["all", "claims", "landing"]), default="all")
def pause(scope: str) -> None:
    """Hold work: all, claims (no new tickets) or landing."""
    _post("/v1/pause", {"scope": scope})


@main.command()
def resume() -> None:
    """Release a pause."""
    _post("/v1/resume")


@main.command()
@click.argument("number", type=_num)
@click.argument("stage", required=False)
@click.option("-n", "lines", default=40, show_default=True)
def logs(number: int, stage: str | None, lines: int) -> None:
    """Tail a ticket's stage transcripts."""
    folder = config_mod.home() / "tickets" / str(number) / "transcripts"
    files = sorted(folder.glob(f"{stage or '*'}-*.jsonl"), key=lambda f: f.stat().st_mtime)
    if not files:
        raise click.ClickException(f"no transcripts under {folder}")
    for line in files[-1].read_text().splitlines()[-lines:]:
        row = json.loads(line)
        click.echo(f"{time.strftime('%H:%M:%S', time.localtime(row['t']))} {row['type']:<18} {row['repr'][:200]}")


@main.group()
def nightly() -> None:
    """The nightly run (T4): every local suite and the Gherkin features on origin/develop."""


@nightly.command("run")
@click.option("--ref", default=None, help="A ref to test instead of origin/develop (a scratch branch with a planted red).")
@click.option("--suite", "suites", multiple=True, help="Only checks with this id or id prefix, e.g. test:logging or gherkin:cli/")
@click.option("--ui/--no-ui", default=False, help="Also the mac gui @ui features (needs UI automation and the display).")
@click.option("--no-file", is_flag=True, help="Do not file tickets for new reds; say what would be filed.")
def nightly_run(ref: str | None, suites: tuple[str, ...], ui: bool, no_file: bool) -> None:
    """Start a nightly in the daemon now (it runs in the background; see `nightly status`)."""
    _post("/v1/nightly/run", {"ref": ref, "suites": list(suites), "ui": ui, "file_tickets": not no_file})


@nightly.command("status")
@click.option("--json", "as_json", is_flag=True)
def nightly_status(as_json: bool) -> None:
    """The latest nightly: per-check status and time."""
    from . import client as client_mod

    try:
        run = _client().call("GET", "/v1/nightly")
    except client_mod.DaemonDown as exc:
        raise click.ClickException(str(exc)) from exc
    if as_json or not run:
        click.echo(json.dumps(run) if as_json else "no nightly has run")
        return
    state = "running" if run["ended"] is None else run["status"]
    click.echo(f"nightly #{run['id']} {run['ref']} {run['sha'][:10]}  {state}")
    for r in run["results"]:
        mark = "ok  " if r["status"] == "pass" else "RED "
        counts = f"{r['executed']} tests" if r["executed"] else ""
        click.echo(f"  {mark}{r['check_id']:<44}{r['seconds'] / 60:7.1f} min  {counts}  {'' if r['status'] == 'pass' else r['status']}")
    for key in ("new_reds", "filed"):
        if run["summary"].get(key):
            click.echo(f"{key}: " + ", ".join(run["summary"][key]))


@main.command()
@click.option("--days", default=7, show_default=True)
def digest(days: int) -> None:
    """The weekly report: landed tickets, interventions, park reasons, lock use. Reads the database, read-only."""
    from . import digest as digest_mod
    from .checks import ledger
    from .db import Database, db_path

    if not db_path().exists():
        raise click.ClickException("no database yet: the daemon has never run")
    click.echo(digest_mod.build(Database(read_only=True), time.time(), days, ledger.ledger_path()).render())


@main.group()
def daemon() -> None:
    """The starpiped process."""


@daemon.command("run")
def daemon_run() -> None:
    """Run the daemon in the foreground (launchd runs this)."""
    import asyncio
    import logging

    from . import daemon as daemon_mod
    from . import selfupdate

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    selfupdate.record_start()
    if selfupdate.crash_loop():  # the runtime we switched to does not stay up: go back, and say so
        name = selfupdate.rollback(_plist_path())
        from .db import Database
        from .notify import Notifier

        Notifier(Database()).alert("runtime-rollback", None, f"the new runtime kept crashing: rolled back to {name}")
        sys.exit(1)
    asyncio.run(daemon_mod.build(config_mod.load()).run())


@daemon.command("self-test")
def daemon_self_test() -> None:
    """Check this runtime can run the daemon: every module imports, config and database open, the SDK and prompts are there."""
    from . import selfupdate

    problems = selfupdate.self_test_in_process()
    for p in problems:
        click.echo(f"PROBLEM  {p}")
    click.echo("ok" if not problems else f"{len(problems)} problem(s)")
    sys.exit(1 if problems else 0)


LABEL = "com.brianm998.starpiped"


def _plist_path() -> Path:
    return Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"


@daemon.command("install")
def daemon_install() -> None:
    """Write the launchd agent and load it (KeepAlive, starts at login)."""
    from . import daemon as daemon_mod

    checkout = daemon_mod.checkout_root(config_mod.load(), Path.cwd())
    from . import selfupdate

    # a pinned runtime if `self-update` has made one (launchd then follows its `current` symlink); else the main checkout, never a
    # worktree that will be deleted
    main_shim = checkout / "pipeline" / "bin" / "starpipe"
    shim = (selfupdate.current_shim() if selfupdate.link("current") else
            main_shim if main_shim.exists() else Path(__file__).resolve().parents[2] / "bin" / "starpipe")
    template = (Path(__file__).resolve().parents[2] / "launchd" / f"{LABEL}.plist.in").read_text()
    out = (template.replace("@SHIM@", str(shim)).replace("@CHECKOUT@", str(checkout))
           .replace("@HOME@", str(config_mod.home())).replace("@PATH@", os.environ.get("PATH", "/usr/bin:/bin")))
    plistlib.loads(out.encode())  # refuse to write a malformed agent
    (config_mod.home() / "logs").mkdir(parents=True, exist_ok=True)
    _plist_path().parent.mkdir(parents=True, exist_ok=True)
    _plist_path().write_text(out)
    subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(_plist_path())], check=False)
    click.echo(f"installed {_plist_path()}")


@daemon.command("uninstall")
def daemon_uninstall() -> None:
    """Unload and remove the launchd agent."""
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"], check=False)
    _plist_path().unlink(missing_ok=True)
    click.echo("uninstalled")


@daemon.command("start")
def daemon_start() -> None:
    """Start the launchd agent."""
    subprocess.run(["launchctl", "kickstart", f"gui/{os.getuid()}/{LABEL}"], check=False)


@daemon.command("stop")
def daemon_stop() -> None:
    """Stop the daemon (SIGTERM to the pid the API reports); launchd restarts it unless uninstalled."""
    from . import client as client_mod

    try:
        pid = int(_client().call("GET", "/v1/status")["daemon"]["pid"])
    except (client_mod.DaemonDown, KeyError, TypeError) as exc:
        raise click.ClickException("the daemon is not running") from exc
    os.kill(pid, signal.SIGTERM)
    click.echo(f"sent SIGTERM to {pid}")


@main.command("self-update")
@click.option("--ref", default=None, help="What to build the runtime from (default origin/<base branch>).")
@click.option("--now", is_flag=True, help="Switch even if stage sessions are running (they resume from their recorded ids).")
@click.option("--dry-run", is_flag=True, help="Build and self-test the new runtime, but do not switch.")
@click.option("--rollback", "do_rollback", is_flag=True, help="Go back to the previous runtime.")
@click.option("--wait-minutes", default=60, show_default=True, help="How long to wait for the sessions to finish.")
def self_update(ref: str | None, now: bool, dry_run: bool, do_rollback: bool, wait_minutes: int) -> None:
    """Pin the daemon to a copy of pipeline/ at one commit, so a moving checkout cannot change it underneath (plan §14.4)."""
    from . import client as client_mod
    from . import daemon as daemon_mod
    from . import gitutil, selfupdate

    if do_rollback:
        try:
            click.echo(f"rolled back to {selfupdate.rollback(_plist_path())}")
        except RuntimeError as exc:
            raise click.ClickException(str(exc)) from exc
        return
    cfg = config_mod.load()
    repo = daemon_mod.checkout_root(cfg, Path.cwd())
    if ref is None:
        ref = f"origin/{cfg.base_branch}"
        gitutil.remote_fetch(repo, cfg.owner, cfg.repo, cfg.base_branch)

    def sessions() -> int:
        try:
            return int(client_mod.Client(cfg).call("GET", "/v1/runtime")["sessions"])
        except client_mod.DaemonDown:
            return 0

    try:
        report = selfupdate.update(repo, ref, _plist_path(), sessions=sessions, wait_s=wait_minutes * 60.0, now=now, dry_run=dry_run)
    except (RuntimeError, OSError) as exc:
        raise click.ClickException(str(exc)) from exc
    click.echo(f"{report.sha[:12]}: {report.detail}")
    sys.exit(0 if (report.switched or (dry_run and report.tested) or report.detail.startswith("already")) else 1)


@main.command()
def runtime() -> None:
    """Which pinned runtime the daemon runs, and which one is kept for rollback."""
    from . import selfupdate

    for name in ("current", "previous"):
        rt = selfupdate.link(name)
        click.echo(f"{name:<9}{rt.name if rt else '-'}" + (f"  ({rt})" if rt else ""))
    if selfupdate.link("current") is None:
        click.echo("the daemon runs from the checkout; `starpipe self-update` pins it")


if __name__ == "__main__":  # pragma: no cover
    main(prog_name="starpipe")
