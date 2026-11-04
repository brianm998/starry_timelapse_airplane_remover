"""Ticket body lint and filing (plan §6.3, §6.4)."""

from __future__ import annotations

import difflib
import re
from dataclasses import dataclass, field
from typing import Any

from pydantic import ValidationError

from . import plan as planmod
from .github import GitHub, GitHubError

SECTIONS = ["Goal", "Context", "Acceptance criteria", "Tests", "Out of scope"]
MODEL_STAGES = ("explore", "develop", "fix", "review", "resolve", "ci_fix", "conflict")  # "ci-fix" is "ci_fix" in a key
ALLOWED_MODELS = ("opus", "sonnet", "haiku")
FABLE = "fable"  # allowed only when Config.allow_fable
EFFORTS = ("low", "medium", "high", "xhigh", "max")
PIPELINE_KEYS = {"gherkin", "skip_review", *(f"{kind}_{s}" for s in MODEL_STAGES for kind in ("model", "effort"))}
PRIORITIES = ["p0", "p1", "p2", "p3"]
MAX_CRITERIA = 6
VAGUE_NONE = re.compile(r"^(visual|hard to test|ui|cosmetic|n/?a|none)\W*$", re.IGNORECASE)


@dataclass
class Lint:
    errors: list[str] = field(default_factory=lambda: list[str]())
    warnings: list[str] = field(default_factory=lambda: list[str]())

    @property
    def ok(self) -> bool:
        return not self.errors


def split_sections(body: str) -> dict[str, str]:
    out: dict[str, list[str]] = {}
    current: str | None = None
    in_fence = False
    for line in body.splitlines():
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
        header = None if in_fence else re.fullmatch(r"##\s+(.+?)\s*", line)
        if header:
            current = str(header.group(1))
            out.setdefault(current, [])
        elif current is not None:
            out[current].append(line)
    return {k: "\n".join(v).strip() for k, v in out.items()}


def pipeline_entries(section: str) -> list[tuple[str, str, str]]:
    """The '## Pipeline' entries as (key, value, raw part); a part without ':' has an empty key and value."""
    out: list[tuple[str, str, str]] = []
    for line in section.splitlines():
        for part in filter(None, (p.strip() for p in line.split("·"))):
            key, colon, value = part.partition(":")
            out.append((key.strip().lstrip("-* "), value.strip(), part) if colon else ("", "", part))
    return out


def parse_pipeline(body: str) -> dict[str, str]:
    """The key: value choices of a ticket body's '## Pipeline' section (later entries win; unvalidated)."""
    return {k: v for k, v, _ in pipeline_entries(split_sections(body).get("Pipeline", "")) if k}


NO_FEATURES = ("", "no", "none", "-")


def gherkin_features(body: str, plan: dict[str, Any] | None) -> list[str]:
    """The Gherkin features to prove on a ticket's own branch: the Pipeline `gherkin:` value, then the plan's
    `gherkin_features_to_run`, de-duplicated in first-seen order. `gherkin: no` (or none named) is an empty list."""
    named = parse_pipeline(body).get("gherkin", "")
    wanted = [f for f in re.split(r"[,\s]+", named) if f] if named.strip().lower() not in NO_FEATURES else []
    wanted += [str(f).strip() for f in (plan or {}).get("gherkin_features_to_run", []) if str(f).strip()]
    return list(dict.fromkeys(wanted))


def feature_title(features: list[str]) -> str:
    """The display_title of a dispatched subset run: gherkin.yml's run-name is `Gherkin: <features input>`."""
    return "Gherkin: " + ",".join(features)


def allowed_models(allow_fable: bool = False) -> tuple[str, ...]:
    return (*ALLOWED_MODELS, *((FABLE,) if allow_fable else ()))


def with_pipeline_models(body: str, models: dict[str, str]) -> str:
    """`body` with a `model_<stage>` entry per `models` item in its '## Pipeline' section.

    A chosen stage's entry is replaced where it stands (or added at the end of the section); every other entry is
    kept as written. The section is created at the end of the body when there is none."""
    if not models:
        return body
    chosen = {f"model_{stage}": f"model_{stage}: {model}" for stage, model in models.items()}
    lines = body.splitlines()
    start = end = None
    in_fence = False
    for i, line in enumerate(lines):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
        if in_fence or not re.fullmatch(r"##\s+(.+?)\s*", line):
            continue
        if start is not None:
            end = i
            break
        if re.fullmatch(r"##\s+Pipeline\s*", line):
            start = i
    if start is None:
        return body.rstrip("\n") + "\n\n## Pipeline\n" + " · ".join(chosen.values()) + "\n"
    end = len(lines) if end is None else end
    parts: list[str] = []
    done: set[str] = set()
    for key, _, raw in pipeline_entries("\n".join(lines[start + 1:end])):
        if key not in chosen:
            parts.append(raw)
        elif key not in done:
            parts.append(chosen[key])
            done.add(key)
    parts += [v for k, v in chosen.items() if k not in done]
    section = [lines[start], " · ".join(parts)]
    if end < len(lines):
        section.append("")  # keep the blank line before the next heading
    return "\n".join([*lines[:start], *section, *lines[end:]]) + "\n"


def validate_choice(key: str, value: str, allow_fable: bool = False) -> str | None:
    """Why a model_*/effort_* value is not usable, or None when it is (or the key is not one of those)."""
    if key.startswith("model_"):
        allowed = allowed_models(allow_fable)
        if value not in allowed:
            return f"model '{value}' is not allowed (one of {', '.join(allowed)})"
    elif key.startswith("effort_") and value not in EFFORTS:
        return f"effort '{value}' is not one of {', '.join(EFFORTS)}"
    return None


# the '## Plan' section of an owner-filed ticket -----------------------------------------------------------------------
PLAN_KEYS = ("summary", "parity", "localization", "approach", "file", "risk")
TEST_KINDS = ("unit", "daemon", "cli-gherkin", "ui")
DASH = r"(?:—|--)"
TEST_LINE = re.compile(rf"^(?P<kind>{'|'.join(TEST_KINDS)}):\s*(?P<target>\S+)\s+(?P<name>\S+)\s*{DASH}\s*shows:\s*(?P<shows>\S+?)"
                       rf"(?:\s*{DASH}\s*(?P<fails>fails before fix))?\s*$")
FILE_LINE = re.compile(rf"^(?P<file>[^\s:]+):(?P<line>\d+)\s*{DASH}\s*(?P<claim>\S.*)$")


def _split_dash(text: str) -> tuple[str, str]:
    """'both — why' as ('both', 'why'); no dash is (text, '')."""
    head, *tail = re.split(rf"\s*{DASH}\s*", text, maxsplit=1)
    return head.strip(), tail[0].strip() if tail else ""


def ticket_plan(body: str) -> tuple[planmod.Plan | None, list[str]]:
    """The `Plan` a ticket body carries in its '## Plan' section, or what is wrong with it.

    `(None, [])` is a body with no '## Plan'. The syntax is checked here with no worktree; whether the files and lines exist,
    the criteria are mapped and the bug rules hold is `Contract.check_plan`'s job (the same call EXPLORE's plan goes through)."""
    sections = split_sections(body)
    if "Plan" not in sections:
        return None, []
    errors: list[str] = []
    fields: dict[str, str] = {}
    approach: list[str] = []
    risks: list[str] = []
    findings: list[dict[str, Any]] = []
    for raw in sections["Plan"].splitlines():
        line = raw.strip().lstrip("-* ").strip()
        if not line:
            continue
        key, colon, value = line.partition(":")
        key, value = key.strip(), value.strip()
        if not colon or key not in PLAN_KEYS:
            errors.append(f"'## Plan' line '{line}': unknown key (one of {', '.join(PLAN_KEYS)})")
        elif not value:
            errors.append(f"'## Plan' {key}: is empty")
        elif key == "approach":
            approach.append(value)
        elif key == "risk":
            risks.append(value)
        elif key == "file":
            m = FILE_LINE.match(value)
            if m and int(m.group("line")) >= 1:
                findings.append({"file": m.group("file"), "line": int(m.group("line")), "claim": m.group("claim")})
            else:
                errors.append(f"'## Plan' file '{value}': expected '<repo path>:<line> — <what is there and why it matters>'")
        elif key in fields:
            errors.append(f"'## Plan' has two '{key}:' lines")
        else:
            fields[key] = value
    for needed in ("summary", "parity", "localization"):
        if needed not in fields:
            errors.append(f"'## Plan' needs a '{needed}:' line")
    if not approach:
        errors.append("'## Plan' needs at least one '- approach:' line")

    parity, reason = "neither", ""
    if "parity" in fields:
        parity, reason = _split_dash(fields["parity"])
        if parity not in ("neither", "both", "gui-only", "desktop-only"):
            errors.append(f"'## Plan' parity '{parity}' is not neither, both, gui-only or desktop-only")
        elif parity in ("gui-only", "desktop-only") and not reason:
            errors.append(f"'## Plan' parity {parity} needs a reason: '{parity} — <why>'")
    localization = fields.get("localization", "").lower()
    if "localization" in fields and localization not in ("yes", "no"):
        errors.append("'## Plan' localization must be yes or no")

    criteria = {ident: rest for ident, rest in
                re.findall(r"^\s*[-*]\s*(A\d+):(.*)$", sections.get("Acceptance criteria", ""), re.MULTILINE)}
    acceptance = [{"id": ident, "check": (m.group(1) if (m := re.search(r"\bcheck:\s*(.+)$", rest)) else rest).strip()}
                  for ident, rest in criteria.items()]

    gherkin = parse_pipeline(body).get("gherkin", "").strip()
    features: list[str] = []
    if not gherkin:
        errors.append("'## Plan' needs an explicit 'gherkin: <features|no>' entry under '## Pipeline'")
    elif gherkin.lower() not in NO_FEATURES:
        features = [f for f in re.split(r"[,\s]+", gherkin) if f]

    tests: dict[str, Any] = {"new": [], "none_reason": ""}
    test_text = sections.get("Tests", "")
    if (none := re.match(r"none:\s*(.*)", test_text, re.IGNORECASE | re.DOTALL)):
        tests["none_reason"] = none.group(1).strip()
    else:
        for raw in test_text.splitlines():
            line = raw.strip().lstrip("-* ").strip()
            if not line:
                continue
            m = TEST_LINE.match(line)
            if not m:
                errors.append(f"'## Tests' line '{line}': a plan ticket needs '- <{'|'.join(TEST_KINDS)}>: <target> <name> — "
                              "shows: A<n>[ — fails before fix]' or 'none: <reason>'")
            elif m.group("shows") not in criteria:
                errors.append(f"'## Tests' line '{line}': shows: {m.group('shows')} is not an acceptance criterion of this ticket")
            else:
                tests["new"].append({"target": m.group("target"), "name": m.group("name"), "kind": m.group("kind"),
                                     "shows": m.group("shows"), "fails_before_fix": bool(m.group("fails"))})
    if errors:
        return None, errors
    try:
        return planmod.Plan.model_validate({
            "summary": fields["summary"], "findings": findings, "approach": approach, "tests": tests,
            "gherkin_features_to_run": features, "acceptance": acceptance, "parity": parity, "parity_reason": reason,
            "touches_localization": localization == "yes", "risks": risks}), []
    except ValidationError as exc:
        return None, [f"'## Plan' {'.'.join(map(str, e['loc']))}: {e['msg']}" for e in exc.errors()]


def lint(body: str, title: str = "", allow_fable: bool = False) -> Lint:
    result = Lint()
    sections = split_sections(body)
    for name in SECTIONS:
        if name not in sections:
            result.errors.append(f"missing section '## {name}'")
        elif not sections[name]:
            result.errors.append(f"section '## {name}' is empty")

    criteria = re.findall(r"^\s*[-*]\s*(A\d+):(.*)$", sections.get("Acceptance criteria", ""), re.MULTILINE)
    if "Acceptance criteria" in sections and not criteria:
        result.errors.append("no acceptance criteria: expected lines like '- A1: <outcome> — check: <how>'")
    for ident, rest in criteria:
        if not re.search(r"\bcheck:\s*\S", rest):
            result.errors.append(f"{ident} has no 'check:'")
    if len(criteria) > MAX_CRITERIA:
        result.warnings.append(f"{len(criteria)} acceptance criteria; over {MAX_CRITERIA} usually means several tickets")

    tests = sections.get("Tests", "")
    if tests:
        none = re.match(r"none:\s*(.*)", tests, re.IGNORECASE | re.DOTALL)
        if none:
            reason = none.group(1).strip()
            if not reason:
                result.errors.append("'none:' under '## Tests' needs a reason")
            elif VAGUE_NONE.match(reason) and re.search(r"\b(bug|fix|regress)", title + " " + sections.get("Goal", ""), re.IGNORECASE):
                result.errors.append("a bug ticket's 'none:' reason cannot be just 'visual' or 'hard to test'")
        elif not re.search(r"^\s*[-*\d]", tests, re.MULTILINE):
            result.errors.append("'## Tests' must be a list of tests or 'none: <reason>'")

    for key, value, part in pipeline_entries(sections.get("Pipeline", "")):
        if not key:
            result.errors.append(f"'## Pipeline' entry '{part}' is not key: value")
        elif key not in PIPELINE_KEYS:
            result.errors.append(f"unknown '## Pipeline' key '{key}' (known: {', '.join(sorted(PIPELINE_KEYS))})")
        elif (bad := validate_choice(key, value, allow_fable)):
            result.errors.append(f"'## Pipeline' {key}: {bad}")
    result.errors += ticket_plan(body)[1]  # a body with no '## Plan' adds nothing
    return result


class FilingError(RuntimeError):
    pass


PROPOSED = "pipe:proposed"
DUPLICATE_RATIO = 0.8
FILED_BY = re.compile(r"<!-- starpipe:filed-by:([\w .@-]+) -->")


def filed_by(by: str) -> str:
    """The attribution every ticket carries: a hidden marker for tools and a visible line for people."""
    return f"\n\n<!-- starpipe:filed-by:{by} -->\nFiled by: {by}\n"


def open_issues(gh: GitHub, label: str) -> list[dict[str, Any]]:
    """Open issues (not pull requests) carrying `label`, as full GitHub issue dicts."""
    return [i for i in gh.paged(f"issues?state=open&labels={label}&per_page=100") if "pull_request" not in i]


_open_with = open_issues


def duplicate_of(gh: GitHub, title: str) -> dict[str, Any] | None:
    for issue in gh.paged("issues?state=open&per_page=100"):
        if "pull_request" not in issue and difflib.SequenceMatcher(
                None, title.lower().rstrip("."), issue["title"].lower().rstrip(".")).ratio() >= DUPLICATE_RATIO:
            return issue
    return None


def file_ticket(gh: GitHub, title: str, body: str, blocked_by: list[int] | None = None,
                priority: str | None = None, *, propose: bool = False, by: str = "interactive", force: bool = False,
                max_open: int = 30, max_proposed: int = 10, allow_fable: bool = False) -> int:
    """Lint, create, label and link. All or nothing: a failure closes what was created and says so.

    `propose` files it for the owner to approve (`starpipe approve`) instead of running it: no `pipeline` label, `pipe:proposed`
    instead. Either way it carries who filed it, is checked against open issues for a near-duplicate title, and is refused past
    the caps. `force` skips the duplicate check, not the caps or the lint."""
    if priority is not None and priority not in PRIORITIES:
        raise FilingError(f"priority must be one of {', '.join(PRIORITIES)}")
    result = lint(body, title, allow_fable)
    if not result.ok:
        raise FilingError("ticket lint failed:\n  " + "\n  ".join(result.errors))
    try:
        if not force and (dup := duplicate_of(gh, title)) is not None:
            raise FilingError(f"looks like a duplicate of open issue #{dup['number']} ({dup['title']}); --force files it anyway")
        if propose and len(_open_with(gh, PROPOSED)) >= max_proposed:
            raise FilingError(f"{max_proposed} proposals are already waiting for approval: `starpipe proposals`")
        if not propose and len(_open_with(gh, "pipeline")) >= max_open:
            raise FilingError(f"{max_open} tickets are already open for the pipeline; wait, or raise max_open_tickets")
    except GitHubError as exc:
        raise FilingError(f"could not check the open issues: {exc}") from exc
    number: int | None = None
    try:
        if propose:
            gh.ensure_label(PROPOSED)
        number = gh.create_issue(title, body.rstrip() + filed_by(by))
        gh.add_labels(number, [PROPOSED if propose else "pipeline", *([priority] if priority else [])])
        for blocker in blocked_by or []:
            gh.block(number, blocker)
    except GitHubError as exc:
        if number is None:
            raise FilingError(f"could not create the issue: {exc}") from exc
        try:
            gh.close_issue(number)
            undone = f"closed #{number}"
        except GitHubError as undo_exc:
            undone = f"#{number} is left open ({undo_exc})"
        raise FilingError(f"filing failed ({exc}); {undone}") from exc
    return number


@dataclass
class Proposal:
    number: int
    title: str
    by: str


def proposals(gh: GitHub) -> list[Proposal]:
    out: list[Proposal] = []
    for issue in _open_with(gh, PROPOSED):
        m = FILED_BY.search(issue.get("body") or "")
        out.append(Proposal(int(issue["number"]), issue["title"], m.group(1) if m else "unknown"))
    return out


def approve(gh: GitHub, number: int, priority: str | None = None, max_open: int = 30) -> None:
    """The owner's go-ahead for a proposal: `pipeline` goes on, `pipe:proposed` comes off."""
    if priority is not None and priority not in PRIORITIES:
        raise FilingError(f"priority must be one of {', '.join(PRIORITIES)}")
    try:
        issue = gh.issue(number)
        names = {lab["name"] for lab in issue.get("labels", [])}
        if "pull_request" in issue:
            raise FilingError(f"#{number} is a pull request")
        if issue.get("state") != "open":
            raise FilingError(f"#{number} is closed")
        if "pipeline" in names:
            raise FilingError(f"#{number} is already approved")
        if len(_open_with(gh, "pipeline")) >= max_open:
            raise FilingError(f"{max_open} tickets are already open for the pipeline; wait, or raise max_open_tickets")
        gh.add_labels(number, ["pipeline", *([priority] if priority else [])])
        gh.remove_label(number, PROPOSED)
    except GitHubError as exc:
        raise FilingError(f"could not approve #{number}: {exc}") from exc


def reject(gh: GitHub, number: int, reason: str) -> None:
    try:
        gh.comment(number, f"Not taking this up: {reason}" if reason else "Not taking this up.")
        gh.remove_label(number, PROPOSED)
        gh.close_issue(number)
    except GitHubError as exc:
        raise FilingError(f"could not reject #{number}: {exc}") from exc
