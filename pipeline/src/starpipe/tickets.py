"""Ticket body lint and filing (plan §6.3, §6.4)."""

from __future__ import annotations

import difflib
import re
from dataclasses import dataclass, field
from typing import Any

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
    return result


class FilingError(RuntimeError):
    pass


PROPOSED = "pipe:proposed"
DUPLICATE_RATIO = 0.8
FILED_BY = re.compile(r"<!-- starpipe:filed-by:([\w .@-]+) -->")


def filed_by(by: str) -> str:
    """The attribution every ticket carries: a hidden marker for tools and a visible line for people."""
    return f"\n\n<!-- starpipe:filed-by:{by} -->\nFiled by: {by}\n"


def _open_with(gh: GitHub, label: str) -> list[dict[str, Any]]:
    return [i for i in gh.paged(f"issues?state=open&labels={label}&per_page=100") if "pull_request" not in i]


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
