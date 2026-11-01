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

    max_active: int = 2
    heavy_slots: int = 1
    auto_self_update: bool = True  # switch the daemon to a new pinned runtime when origin/develop has newer pipeline/ code; the kill switch
    nightly_start: str = "03:00"
    digest_weekday: int = 6  # Monday is 0
    digest_hour: int = 8
    nightly_enabled: bool = False  # a multi-hour job that has never run unattended: the owner turns it on
    nightly_ui: bool = False  # the mac gui @ui features: need UI automation permission and the display
    test_data: str = ""  # shared dataset cache; empty: $STAR_TEST_DATA, else ~/.star-test-data
    quiet_start: str = "22:00"
    quiet_end: str = "07:00"
    ci_blocking_wait_s: int = 3 * 3600
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
