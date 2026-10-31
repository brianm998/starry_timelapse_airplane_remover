"""From changed paths to the checks a change triggers, and why (plan §8.2)."""

from __future__ import annotations

from dataclasses import dataclass, field

from .. import adapter_star as star

T0_ALWAYS = ["t0:diff-check", "t0:artifacts"]


@dataclass
class Plan:
    t0: list[str] = field(default_factory=list[str])
    builds: list[str] = field(default_factory=list[str])
    tests: list[str] = field(default_factory=list[str])
    reasons: dict[str, list[str]] = field(default_factory=dict[str, list[str]])  # check id -> paths/notes
    notes: list[str] = field(default_factory=list[str])
    unmapped: list[str] = field(default_factory=list[str])

    def t1(self) -> list[str]:
        return [*self.builds, *self.tests]

    def why(self, check: str, why: str) -> None:
        reasons = self.reasons.setdefault(check, [])
        if why not in reasons and len(reasons) < 3:
            reasons.append(why)


def _closure(package: str) -> list[str]:
    seen: list[str] = []
    todo = [package]
    while todo:
        pkg = todo.pop(0)
        if pkg not in seen:
            seen.append(pkg)
            todo.extend(star.DEPENDENTS.get(pkg, []))
    return seen


def plan_for(paths: list[str]) -> Plan:
    plan = Plan(t0=list(T0_ALWAYS))
    builds: set[str] = set()
    tests: set[str] = set()

    for path in paths:
        if path.startswith(star.NO_CHECK_PREFIXES) or path.endswith(star.NO_CHECK_SUFFIXES):
            if path.startswith("i18n/") and "t0:i18n" not in plan.t0:
                plan.t0.append("t0:i18n")
            continue
        if "/Resources/Localizations/" in path and "t0:i18n" not in plan.t0:
            plan.t0.append("t0:i18n")
        if path.startswith("daemon/proto/") and "t0:proto-sync" not in plan.t0:
            plan.t0.append("t0:proto-sync")
        if path.startswith("gherkin/") and "t0:gherkin-generated" not in plan.t0:
            plan.t0.append("t0:gherkin-generated")
        if path.startswith("pipeline/") and "t0:pipeline-static" not in plan.t0:
            plan.t0.append("t0:pipeline-static")

        rule = next((r for r in star.RULES if path.startswith(r.prefixes)), None)
        if rule is None:
            plan.unmapped.append(path)
            continue
        if rule.note and rule.note not in plan.notes:
            plan.notes.append(rule.note)
        if rule.package:
            for pkg in _closure(rule.package):
                check = f"build:{pkg}"
                if check in star.CHECKS:
                    builds.add(check)
                    plan.why(check, path if pkg == rule.package else f"depends on {rule.package} ({path})")
        for check in rule.builds:
            builds.add(check)
            plan.why(check, path)
        for check in rule.tests:
            tests.add(check)
            plan.why(check, path)

    order = list(star.CHECKS)
    plan.builds = sorted(builds, key=order.index)
    plan.tests = sorted(tests, key=order.index)
    return plan


def unmapped_top_levels(top_levels: list[str]) -> list[str]:
    """Top-level directories holding source that neither a rule nor the ignore list covers."""
    prefixes = [p for r in star.RULES for p in r.prefixes] + list(star.NO_CHECK_PREFIXES)
    return sorted(
        d for d in top_levels
        if d not in star.IGNORED_TOP_LEVEL and not any(p.startswith(d + "/") for p in prefixes)
    )
