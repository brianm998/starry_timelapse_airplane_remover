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
