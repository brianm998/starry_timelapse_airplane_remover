"""Configuration: ~/.star-pipeline/config.toml over the defaults of plans/PIPELINE.md §2."""

from __future__ import annotations

import os
import tomllib
from pathlib import Path

from pydantic import BaseModel, ConfigDict


def home() -> Path:
    """The pipeline's state directory. STARPIPE_HOME overrides it (tests, a second install)."""
    return Path(os.environ.get("STARPIPE_HOME") or Path.home() / ".star-pipeline")


def token_path() -> Path:
    return home() / "api.token"


class Config(BaseModel):
    model_config = ConfigDict(extra="forbid")

    owner: str = "brianm998"
    repo: str = "starry_timelapse_airplane_remover"
    base_branch: str = "develop"

    # models: sonnet for every model stage and for the escalation attempt, by the owner's choice on 2026-10-31 (the plan said
    # opus). Per-stage and per-ticket choice is a ticket still to come. fable / effort max stay off (ODYS-4134 in Preffect)
    model: str = "sonnet"
    model_escalate: str = "sonnet"
    allow_fable: bool = False
    # Opus only when the owner asks for it: a `model_<stage>: opus` in a ticket body is ignored unless the owner picked it in the
    # monitor, ran `starpipe allow-opus <n>`, or sets this. Tickets filed by agent sessions had copied opus from the skill's example.
    allow_opus: bool = False

    # What limits starting work is resources, not a count of tickets: LLM sessions running at once and measured CPU use (load.py).
    max_llm_sessions: int = 3
    cpu_limit_pct: float = 85.0  # rolling average over cpu_window_s; only a reason to wait while another session is running
    cpu_window_s: int = 60
    landing_mode: str = "batch"  # "batch": the landing train, one CI for many tickets; "single": a PR and a CI per ticket
    batch_max: int = 5  # tickets in one batch
    batch_window_s: int = 120  # wait this long for more tickets once one is ready and no batch is running
    max_in_ci: int = 3  # tickets in CI or landing at once; a finished ticket waits as `ready` for room (runners are shared)
    heavy_slots: int = 1
    auto_self_update: bool = True  # switch the daemon to a new pinned runtime when origin/develop has newer pipeline/ code; the kill switch
    nightly_start: str = "03:00"
    digest_weekday: int = 6  # Monday is 0
    digest_hour: int = 8
    nightly_enabled: bool = False  # a multi-hour job that has never run unattended: the owner turns it on
    nightly_ui: bool = False  # the mac gui @ui features: need UI automation permission and the display
    # NOT the T4 nightly above: the daemon dispatches ONE full run of the "Gherkin" workflow on GitHub, local time, once a day, only
    # when code Gherkin covers changed since the last green full run (gherkin_nightly.py). A push to develop no longer runs Gherkin.
    gherkin_nightly_enabled: bool = True
    gherkin_nightly_start: str = "23:00"
    test_data: str = ""  # shared dataset cache; empty: $STAR_TEST_DATA, else ~/.star-test-data
    quiet_start: str = "22:00"
    quiet_end: str = "07:00"
    # Gherkin's matrix takes about 3 h (median 174, slowest 214 min, 2026-10-31): a job still running after this stops blocking, so the
    # limit has to sit clear of a normal Gherkin run
    ci_blocking_wait_s: int = 4 * 3600
    # Workflows whose result a PR does not wait for. Gherkin's matrix takes ~3 h and is mostly queueing for GitHub's few macOS runners,
    # so waiting for it capped landings at a few a day (2026-10-31). Its runs on the PR are cancelled at once, to free those runners;
    # the push to develop runs it, and the post-merge watch files a regression ticket if it goes red.
    ci_post_merge_workflows: tuple[str, ...] = ("Gherkin",)
    heavy_wait_report_s: float = 60.0
    api_port: int = 47231
    java_home: str = ""  # JDK 21 for star-desktop builds; empty: $JAVA_HOME, else the adapter's candidates
    remote: str = "https"  # "https" (the daemon, token from github.env or gh) or "origin" (tests, a local bare repo)
    ci_poll_s: float = 60.0
    ci_settle_s: float = 90.0
    max_auto_tickets: int = 2
    max_open_tickets: int = 30  # open issues labelled `pipeline`: `ticket new` and `approve` refuse past this
    max_proposed: int = 10  # open issues labelled `pipe:proposed`: waiting on the owner
    poll_s: float = 60.0
    checkout: str = ""  # the main checkout the worktrees hang off; default: found from the cwd


def load(path: Path | None = None) -> Config:
    path = path or home() / "config.toml"
    if not path.exists():
        return Config()
    with path.open("rb") as handle:
        return Config(**tomllib.load(handle))
