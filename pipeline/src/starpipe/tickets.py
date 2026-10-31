"""Ticket body lint and filing (plan §6.3, §6.4)."""

from __future__ import annotations

import re
from dataclasses import dataclass, field

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


def validate_choice(key: str, value: str, allow_fable: bool = False) -> str | None:
    """Why a model_*/effort_* value is not usable, or None when it is (or the key is not one of those)."""
    if key.startswith("model_"):
        allowed = (*ALLOWED_MODELS, *((FABLE,) if allow_fable else ()))
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


def file_ticket(gh: GitHub, title: str, body: str, blocked_by: list[int] | None = None,
                priority: str | None = None, allow_fable: bool = False) -> int:
    """Lint, create, label and link. All or nothing: a failure closes what was created and says so."""
    if priority is not None and priority not in PRIORITIES:
        raise FilingError(f"priority must be one of {', '.join(PRIORITIES)}")
    result = lint(body, title, allow_fable)
    if not result.ok:
        raise FilingError("ticket lint failed:\n  " + "\n  ".join(result.errors))
    number: int | None = None
    try:
        number = gh.create_issue(title, body)
        gh.add_labels(number, ["pipeline", *([priority] if priority else [])])
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
