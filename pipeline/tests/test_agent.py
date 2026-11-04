from __future__ import annotations

import pytest

from starpipe import agent
from starpipe.engine import BUDGET_S, prompt_text


@pytest.mark.parametrize("stage", sorted(BUDGET_S))
def test_stage_env_sets_bash_timeouts_to_the_stage_budget(stage: str) -> None:
    env = agent.sanitized_env(7, budget_s=BUDGET_S[stage])
    expected = str(BUDGET_S[stage] * 1000)
    assert env["BASH_DEFAULT_TIMEOUT_MS"] == expected
    assert env["BASH_MAX_TIMEOUT_MS"] == expected


def test_preamble_says_a_declined_tool_call_is_not_the_owner() -> None:
    text = " ".join(prompt_text("_preamble").split())
    assert "doesn't want to take this action" in text
    assert "not from a person" in text
    assert "ask_question" in text.split("not from a person", 1)[1]
