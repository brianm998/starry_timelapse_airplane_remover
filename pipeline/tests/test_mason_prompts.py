"""Pin the rules in .mason/prompts/develop.md for a red sent back to the develop agent."""

from pathlib import Path

DEVELOP = Path(__file__).resolve().parents[2] / ".mason" / "prompts" / "develop.md"


def _text() -> str:
    return DEVELOP.read_text()


def test_feedback_placeholder_kept_at_end() -> None:
    assert _text().rstrip().endswith("{feedback}")


def test_outside_the_diff_rule() -> None:
    t = _text()
    assert "git diff --name-only $(git merge-base HEAD origin/develop)" in t
    assert "If none of them is in your diff" in t
    assert 'do not just answer "No code change"' in t


def test_probe_base_and_fresh_build() -> None:
    t = _text()
    assert "Probe the base" in t
    assert "`origin/develop`" in t
    assert "fresh `.build`" in t


def test_unchanged_head_same_red_is_reported() -> None:
    t = _text()
    assert "your head is unchanged" in t
    assert "must not be treated as cached-trustworthy" in t
    assert "uncached rerun" in t
