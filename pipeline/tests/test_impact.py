from __future__ import annotations

import subprocess
from pathlib import Path

from starpipe import adapter_star as star
from starpipe.checks import impact

ROOT = Path(__file__).resolve().parents[2]


def test_starcore_change_builds_dependents_and_tests_only_starcore() -> None:
    plan = impact.plan_for(["StarCore/Sources/StarCore/Foo.swift"])
    assert plan.builds == ["build:StarCore", "build:cli", "build:daemon", "build:gui"]
    assert plan.tests == ["test:StarCore"]
    assert plan.t0 == ["t0:diff-check", "t0:artifacts"]


def test_logging_change_builds_the_whole_chain() -> None:
    plan = impact.plan_for(["logging/Sources/x.swift"])
    assert plan.builds == ["build:logging", "build:StarCpp", "build:StarCore", "build:cli",
                           "build:daemon", "build:gui"]
    assert plan.tests == ["test:logging"]


def test_docs_and_markdown_need_nothing() -> None:
    plan = impact.plan_for(["docs/index.html", "plans/X.md", "README.md"])
    assert plan.t1() == [] and plan.unmapped == []


def test_localization_change_runs_the_i18n_check_without_builds() -> None:
    plan = impact.plan_for(["StarCore/Sources/StarCore/Resources/Localizations/en.json"])
    assert "t0:i18n" in plan.t0 and plan.t1() == []


def test_proto_change_builds_daemon_and_desktop_and_checks_sync() -> None:
    plan = impact.plan_for(["daemon/proto/star.proto"])
    assert "t0:proto-sync" in plan.t0
    assert {"build:daemon", "build:desktop"} <= set(plan.builds)


def test_unmatched_path_is_reported() -> None:
    assert impact.plan_for(["brand_new_dir/x.swift"]).unmapped == ["brand_new_dir/x.swift"]


def test_every_check_a_rule_names_exists() -> None:
    for rule in star.RULES:
        for check in (*rule.builds, *rule.tests):
            assert check in star.CHECKS, check


def test_no_top_level_source_directory_is_unmapped() -> None:
    names = subprocess.run(["git", "-C", str(ROOT), "ls-files"], capture_output=True, text=True,
                           check=True).stdout.splitlines()
    top = sorted({n.split("/", 1)[0] for n in names if "/" in n})
    assert impact.unmapped_top_levels(top) == []


def test_a_check_id_with_a_slash_is_a_flat_log_name() -> None:
    from starpipe.checks import runner

    assert runner.log_name("build:pipeline/monitor") == "build_pipeline_monitor"
    assert "/" not in runner.log_name("test:pipeline/monitor")


def test_the_monitor_has_its_own_build_and_test() -> None:
    plan = impact.plan_for(["pipeline/monitor/Sources/StarPipeMonitor/App.swift"])
    assert plan.builds == ["build:pipeline/monitor"] and plan.tests == ["test:pipeline/monitor"]
    assert "t0:pipeline-static" in plan.t0  # still a pipeline/ change
    plain = impact.plan_for(["pipeline/src/starpipe/daemon.py"])
    assert plain.builds == [] and plain.tests == ["test:pipeline"]


def test_the_pipeline_tests_run_from_the_pipeline_directory() -> None:
    """From the repo root pytest never reads pipeline/pyproject.toml, so asyncio_mode=auto is not applied and every async test
    fails. The nightly found this: the check had only ever passed while the suite had no async tests."""
    spec = star.CHECKS["test:pipeline"]
    assert spec.cwd == "pipeline" and "--project" not in spec.argv
    assert 'asyncio_mode = "auto"' in (Path(__file__).resolve().parents[1] / "pyproject.toml").read_text()
