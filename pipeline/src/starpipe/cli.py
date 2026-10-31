"""The starpipe command line (plan §12). Phase 1: heavy, check, doctor."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import click

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


if __name__ == "__main__":  # pragma: no cover
    main(prog_name="starpipe")
