from __future__ import annotations

from types import SimpleNamespace
from typing import Any

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


def _info(**over: Any) -> SimpleNamespace:
    base: dict[str, Any] = {"status": "rejected", "rate_limit_type": "five_hour", "overage_status": None, "resets_at": 5000.0,
                            "utilization": None, "overage_resets_at": None, "overage_disabled_reason": None}
    return SimpleNamespace(**{**base, **over})


@pytest.mark.parametrize("overage", ["allowed", "allowed_warning"])
def test_a_rejected_base_window_with_usable_credits_is_not_a_stop(overage: str) -> None:
    assert agent.parse_usage_limit(_info(overage_status=overage)) is None


@pytest.mark.parametrize("overage", [None, "rejected", "something_new"])
def test_a_rejected_base_window_without_usable_credits_pauses_until_its_reset(overage: str | None) -> None:
    assert agent.parse_usage_limit(_info(overage_status=overage)) == 5000.0


def test_a_rejected_overage_window_pauses_even_though_overage_status_says_allowed() -> None:
    assert agent.parse_usage_limit(_info(rate_limit_type="overage", overage_status="allowed")) == 5000.0


def test_an_event_that_is_not_a_rejection_never_pauses() -> None:
    assert agent.parse_usage_limit(_info(status="allowed")) is None
    assert agent.parse_usage_limit(_info(status="allowed_warning", overage_status="rejected")) is None


def test_a_rejection_without_a_reset_time_pauses_for_the_default(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(agent.time, "time", lambda: 1000.0)
    assert agent.parse_usage_limit(_info(resets_at=None)) == 1000.0 + agent.DEFAULT_USAGE_PAUSE_S


def test_credit_report_copies_the_typed_fields() -> None:
    info = _info(utilization=0.5, overage_status="allowed", overage_resets_at=9000.0, overage_disabled_reason="out_of_credits")
    assert agent.credit_report_of(info) == {"status": "rejected", "window": "five_hour", "utilization": 0.5,
                                            "overage_status": "allowed", "overage_resets_at": 9000.0,
                                            "overage_disabled_reason": "out_of_credits"}
    assert agent.credit_report_of(SimpleNamespace())["overage_status"] is None
