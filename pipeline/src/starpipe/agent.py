"""Model stage execution (plan §7.4, §7.5): the AgentRunner protocol and the Claude Agent SDK implementation.

Everything the stages decide lives behind `AgentRunner`, so tests drive them with a scripted fake. The SDK runner
below could not be exercised live while this was written (no OAuth token on this Mac yet); see plan §19.
"""

from __future__ import annotations

import asyncio
import json
import os
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Literal, Protocol, cast

from . import guards
from .config import home
from .contracts import Contract
from .plan import Plan

Status = Literal["accepted", "no-result", "timeout", "usage-limit", "crash"]

STAGE_TOOLS: dict[str, list[str]] = {
    "explore": ["submit_plan", "close_ticket", "ask_question", "file_followup"],
    "develop": ["run_checks", "submit_change", "ask_question", "file_followup"],
    "fix": ["run_checks", "submit_change", "ask_question", "file_followup"],
    "review": ["submit_review", "ask_question", "file_followup"],
    "resolve": ["submit_resolution"],
    "ci-fix": ["run_checks", "submit_change", "ask_question", "file_followup"],
    "conflict": ["run_checks", "submit_change", "ask_question"],
}
READ_ONLY_STAGES = {"explore", "review", "resolve"}
DEFAULT_USAGE_PAUSE_S = 30 * 60
SESSION_ENV_DROP = ("ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")

TOOL_DESCRIPTIONS = {
    "submit_plan": "Submit the plan that ends EXPLORE. Returns what is wrong, or 'accepted'.",
    "close_ticket": "End EXPLORE by closing the ticket: reason (duplicate-of #n | already-done | no-defect | "
                    "not-this-repo) and evidence (commit SHAs on origin/develop, or file:line).",
    "run_checks": "Run the T0/T1 checks for this worktree under the heavy lock. Blocks until done.",
    "submit_change": "Submit the finished change: summary, deviations [{what, evidence}], tests_added "
                     "[{target, id}], parity_reason, memory_notes.",
    "submit_review": "Submit the review: verdict approve|changes, findings [{file, line, severity, issue, "
                     "suggested_fix}], parity_accepted.",
    "ask_question": "Ask the owner: question, why_unanswerable (why the repo, ticket and memory do not answer it), "
                    "options, recommendation, blocking.",
    "file_followup": "Record out-of-scope work: title, body, blocks (does this ticket wait on it).",
    "submit_resolution": "Resolve a question: kind answer|followup|close|escalate, text, reasons (what settles it).",
}


@dataclass
class StageRequest:
    ticket: int
    stage: str
    attempt: int
    prompt: str
    system_append: str
    model: str
    effort: str
    budget_s: float
    contract: Contract
    fence: guards.Fence
    resume: str | None = None
    on_session: Callable[[str], None] = lambda _sid: None  # called as soon as the session id is known


@dataclass
class StageOutcome:
    status: Status
    session_id: str | None = None
    resets_at: float | None = None
    summary: str = ""
    cost_usd: float = 0.0
    transcript: Path | None = None
    tool_calls: list[str] = field(default_factory=list[str])


class AgentRunner(Protocol):
    async def run(self, req: StageRequest) -> StageOutcome: ...


def sanitized_env(ticket: int, nightly: bool = False) -> dict[str, str]:
    """The session's environment: no inherited Claude session variables, the OAuth token from claude.env."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE") and k not in SESSION_ENV_DROP}
    token_file = home() / "claude.env"
    if token_file.exists():
        for line in token_file.read_text().splitlines():
            key, sep, value = line.strip().partition("=")
            if sep and key and not key.startswith("#"):
                env[key.removeprefix("export ").strip()] = value.strip().strip("\"'")
    env["STARPIPE_TICKET"] = str(ticket)
    env["MCP_TOOL_TIMEOUT"] = str(4 * 3600 * 1000)
    if nightly:
        env["STARPIPE_NIGHTLY"] = "1"
    return env


def tool_schema(name: str) -> dict[str, Any]:
    from .contracts import ChangeSubmission, Resolution, Review

    models: dict[str, Any] = {"submit_plan": Plan, "submit_change": ChangeSubmission, "submit_review": Review,
                              "submit_resolution": Resolution}
    if name in models:
        return models[name].model_json_schema()
    free = {"type": "object", "additionalProperties": True}
    props: dict[str, Any] = {
        "close_ticket": {"reason": {"type": "string"}, "evidence": {"type": "array", "items": {"type": "string"}}},
        "ask_question": {"question": {"type": "string"}, "why_unanswerable": {"type": "string"},
                         "options": {"type": "array", "items": {"type": "string"}},
                         "recommendation": {"type": "string"}, "blocking": {"type": "boolean"}},
        "file_followup": {"title": {"type": "string"}, "body": {"type": "string"}, "blocks": {"type": "boolean"}},
    }
    return {**free, "properties": props[name]} if name in props else free


def parse_usage_limit(info: Any) -> float | None:
    """The reset time of a rejected rate-limit event, or None when it is not a rejection."""
    status = getattr(info, "status", None)
    if status != "rejected":
        return None
    resets = getattr(info, "resets_at", None)
    return float(resets) if resets else time.time() + DEFAULT_USAGE_PAUSE_S


def _session_id_of(message: object) -> str | None:
    """The session id a message carries: a `session_id` field, or the `init` system message's data."""
    direct: object = getattr(message, "session_id", None)
    if isinstance(direct, str) and direct:
        return direct
    data: object = getattr(message, "data", None)
    if isinstance(data, dict):
        inner = cast("dict[str, object]", data).get("session_id")
        if isinstance(inner, str) and inner:
            return inner
    return None


class SdkRunner:
    """Runs one stage session through the Claude Agent SDK."""

    def __init__(self, shim: str, transcripts: Path | None = None) -> None:
        self.shim = shim
        self.transcripts = transcripts

    def _hook(self, fence: guards.Fence) -> Any:
        async def hook(inp: dict[str, Any], _tid: str | None, _ctx: Any) -> dict[str, Any]:
            decision = guards.decide(inp["tool_name"], inp["tool_input"], fence, shim=self.shim)
            out: dict[str, Any] = {"hookEventName": "PreToolUse"}
            if decision.kind == "deny":
                out |= {"permissionDecision": "deny", "permissionDecisionReason": decision.reason}
            elif decision.kind == "rewrite":
                out |= {"permissionDecision": "allow", "updatedInput": {**inp["tool_input"], "command": decision.command}}
            else:
                return {}
            return {"hookSpecificOutput": out}
        return hook

    async def run(self, req: StageRequest) -> StageOutcome:
        from claude_agent_sdk import (
            AssistantMessage,
            ClaudeAgentOptions,
            HookMatcher,
            RateLimitEvent,
            ResultError,  # type: ignore[attr-defined]  # noqa: F401 (older SDKs)
            ResultMessage,
            TextBlock,
            ToolUseBlock,
            create_sdk_mcp_server,
            query,
            tool,
        )

        contract = req.contract
        sdk_tools: list[Any] = []
        for name in STAGE_TOOLS[req.stage]:
            def make(tool_name: str) -> Any:
                @tool(tool_name, TOOL_DESCRIPTIONS[tool_name], tool_schema(tool_name))
                async def call(args: dict[str, Any]) -> dict[str, Any]:
                    text = await asyncio.to_thread(getattr(contract, tool_name), args)
                    return {"content": [{"type": "text", "text": text}]}
                return call
            sdk_tools.append(make(name))
        server = create_sdk_mcp_server("star", tools=sdk_tools)

        options = ClaudeAgentOptions(
            model=req.model, effort=cast(Any, req.effort), cwd=str(req.fence.worktree), permission_mode="bypassPermissions",
            setting_sources=["project"], resume=req.resume,
            system_prompt={"type": "preset", "preset": "claude_code", "append": req.system_append},
            mcp_servers={"star": server}, env=sanitized_env(req.ticket),
            hooks={"PreToolUse": [HookMatcher(hooks=[self._hook(req.fence)])]},
            disallowed_tools=sorted(guards.FORBIDDEN_TOOLS | ({"Write", "Edit", "NotebookEdit"} if req.fence.read_only else set())),
        )
        outcome = StageOutcome("no-result")
        log_path = (self.transcripts or req.fence.ticket_dir / "transcripts") / f"{req.stage}-{req.attempt}.jsonl"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        outcome.transcript = log_path
        started = time.monotonic()

        async def consume() -> None:
            with log_path.open("a") as log:
                async for message in query(prompt=req.prompt, options=options):
                    log.write(json.dumps({"t": time.time(), "type": type(message).__name__,
                                          "repr": repr(message)[:4000]}) + "\n")
                    log.flush()
                    sid = _session_id_of(message)
                    if sid and outcome.session_id != sid:
                        outcome.session_id = sid
                        req.on_session(sid)  # recorded now, so a daemon kill mid-stage can still resume it
                    if isinstance(message, RateLimitEvent):
                        resets = parse_usage_limit(message.rate_limit_info)
                        if resets:
                            outcome.status, outcome.resets_at = "usage-limit", resets
                    elif isinstance(message, AssistantMessage):
                        for block in message.content:
                            if isinstance(block, ToolUseBlock):
                                outcome.tool_calls.append(block.name)
                            elif isinstance(block, TextBlock):
                                outcome.summary = block.text[-2000:]
                    elif isinstance(message, ResultMessage):
                        outcome.session_id = message.session_id
                        outcome.cost_usd = message.total_cost_usd or 0.0
                        if message.is_error and message.api_error_status in (429, 529):
                            outcome.status = "usage-limit"
                            outcome.resets_at = outcome.resets_at or time.time() + DEFAULT_USAGE_PAUSE_S

        async def watchdog() -> None:
            while True:
                await asyncio.sleep(5)
                if time.monotonic() - started - contract.lock_wait_s > req.budget_s:
                    raise TimeoutError

        task = asyncio.create_task(consume())
        dog = asyncio.create_task(watchdog())
        try:
            done, _ = await asyncio.wait({task, dog}, return_when=asyncio.FIRST_COMPLETED)
            if dog in done:
                task.cancel()
                outcome.status = "timeout"
            else:
                dog.cancel()
                task.result()
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001  # the CLI died, the connection broke, or the SDK raised on an error result
            outcome.summary = f"{type(exc).__name__}: {exc}"[:500]
            if outcome.status != "usage-limit":
                outcome.status = "crash"
        finally:
            for t in (task, dog):
                t.cancel()
        if contract.result is not None and outcome.status not in ("timeout",):
            outcome.status = "accepted"
        return outcome
