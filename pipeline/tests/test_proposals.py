from __future__ import annotations

from pathlib import Path

import pytest

from starpipe import tickets
from starpipe.agent import StageOutcome, StageRequest
from starpipe.tickets import FilingError

from .fakes import GOOD_BODY, FakeGitHub, accepted
from .test_engine import Rig


@pytest.fixture
def gh() -> FakeGitHub:
    return FakeGitHub()


def labels(gh: FakeGitHub, n: int) -> set[str]:
    return {lab["name"] for lab in gh.issues[n]["labels"]}


def test_a_proposal_waits_for_approval_and_says_who_filed_it(gh: FakeGitHub) -> None:
    n = tickets.file_ticket(gh, "Add a thing", GOOD_BODY, priority="p1", propose=True, by="review agent")
    assert labels(gh, n) == {"pipe:proposed", "p1"}, "no `pipeline` label: it will not run"
    assert "<!-- starpipe:filed-by:review agent -->" in gh.issues[n]["body"] and "Filed by: review agent" in gh.issues[n]["body"]
    assert [(p.number, p.by) for p in tickets.proposals(gh)] == [(n, "review agent")]


def test_an_ordinary_ticket_carries_the_pipeline_label_and_its_author(gh: FakeGitHub) -> None:
    n = tickets.file_ticket(gh, "Do a thing", GOOD_BODY)
    assert labels(gh, n) == {"pipeline"} and "Filed by: interactive" in gh.issues[n]["body"]
    assert tickets.proposals(gh) == []


def test_a_near_duplicate_title_is_refused_unless_forced(gh: FakeGitHub) -> None:
    first = tickets.file_ticket(gh, "Speed up the merge step", GOOD_BODY)
    with pytest.raises(FilingError, match=f"duplicate of open issue #{first}"):
        tickets.file_ticket(gh, "Speed up the merge step.", GOOD_BODY, propose=True)
    second = tickets.file_ticket(gh, "Speed up the merge step.", GOOD_BODY, propose=True, force=True)
    assert second != first
    tickets.file_ticket(gh, "Something quite different", GOOD_BODY)  # unrelated titles are fine


def test_closed_issues_and_pull_requests_do_not_count_as_duplicates(gh: FakeGitHub) -> None:
    gh.add_issue(1, "Speed up the merge step", labels=())
    gh.issues[1]["state"] = "closed"
    gh.add_issue(2, "Speed up the merge step", labels=())
    gh.issues[2]["pull_request"] = {}
    assert tickets.file_ticket(gh, "Speed up the merge step", GOOD_BODY) == 3


def test_the_proposal_and_open_ticket_caps(gh: FakeGitHub) -> None:
    proposals = ["Show the retry budget in the monitor", "Rename the heavy lock config key"]
    for title in proposals:
        tickets.file_ticket(gh, title, GOOD_BODY, propose=True, max_proposed=2)
    with pytest.raises(FilingError, match="2 proposals are already waiting"):
        tickets.file_ticket(gh, "Document how the nightly picks datasets", GOOD_BODY, propose=True, max_proposed=2)
    for title in ["Fix the tab colours", "Speed up gradle verification", "Add an overview page"]:
        tickets.file_ticket(gh, title, GOOD_BODY, max_open=3)
    with pytest.raises(FilingError, match="3 tickets are already open"):
        tickets.file_ticket(gh, "Translate the settings sheet into German", GOOD_BODY, max_open=3)
    # a full queue does not stop a proposal, and a full proposal list does not stop an ordinary ticket
    tickets.file_ticket(gh, "Investigate windows path length limits", GOOD_BODY, propose=True, max_proposed=5, max_open=3)


def test_lint_still_applies_to_a_proposal(gh: FakeGitHub) -> None:
    with pytest.raises(FilingError, match="lint failed"):
        tickets.file_ticket(gh, "Bad", "## Goal\nx\n", propose=True)
    assert gh.issues == {}


def test_approving_adds_the_pipeline_label_and_removes_the_proposal_one(gh: FakeGitHub) -> None:
    n = tickets.file_ticket(gh, "Add a thing", GOOD_BODY, propose=True)
    tickets.approve(gh, n, "p0")
    assert labels(gh, n) == {"pipeline", "p0"}
    with pytest.raises(FilingError, match="already approved"):
        tickets.approve(gh, n)


def test_approve_refuses_closed_issues_pull_requests_and_a_full_queue(gh: FakeGitHub) -> None:
    n = tickets.file_ticket(gh, "Add a thing", GOOD_BODY, propose=True)
    gh.issues[n]["state"] = "closed"
    with pytest.raises(FilingError, match="is closed"):
        tickets.approve(gh, n)
    gh.add_issue(50, "A PR", labels=())
    gh.issues[50]["pull_request"] = {}
    with pytest.raises(FilingError, match="pull request"):
        tickets.approve(gh, 50)
    gh.add_issue(51, "Waiting", labels=("pipe:proposed",))
    gh.add_issue(52, "Already running")
    with pytest.raises(FilingError, match="1 tickets are already open"):
        tickets.approve(gh, 51, max_open=1)


def test_rejecting_closes_with_a_reason_and_clears_the_label(gh: FakeGitHub) -> None:
    n = tickets.file_ticket(gh, "Add a thing", GOOD_BODY, propose=True)
    tickets.reject(gh, n, "out of scope for now")
    assert gh.issues[n]["state"] == "closed" and "pipe:proposed" not in labels(gh, n)
    assert "out of scope for now" in gh.comment_list[n][-1]["body"]
    assert tickets.proposals(gh) == []


def test_a_proposal_does_not_run_until_it_is_approved(tmp_path: Path) -> None:
    rig = Rig(tmp_path)
    n = tickets.file_ticket(rig.gh, "Add a thing", GOOD_BODY, propose=True)
    rig.engine.sync_issues()
    assert rig.db.ticket(n) is None, "the daemon only takes issues labelled `pipeline`"
    tickets.approve(rig.gh, n)
    rig.engine.sync_issues()
    assert rig.db.ticket(n) is not None and rig.state(n) == "queued"


async def test_a_followup_a_stage_files_is_a_proposal(tmp_path: Path) -> None:
    from .fakes import accepted, plan_args

    rig = Rig(tmp_path)
    rig.gh.add_issue(7, "t")
    rig.engine.sync_issues()

    def explore(req: StageRequest) -> StageOutcome:
        req.contract.file_followup({"title": "Rename the config key", "body": "Out of scope here."})
        req.contract.submit_plan(plan_args())
        return accepted(req)

    rig.agent.on("explore", explore)
    rig.agent.on("develop", lambda r: StageOutcome("no-result"))
    await rig.engine.drive(7)
    follow = next(i for i in rig.gh.issues.values() if i["title"] == "Rename the config key")
    assert {lab["name"] for lab in follow["labels"]} == {"pipe:filed-by-pipeline", "pipe:proposed"}
    assert "pipeline stage of #7" in follow["body"]


async def test_a_ticket_the_pipeline_filed_is_closed_at_once_not_after_a_veto_window(tmp_path: Path) -> None:
    """The pipeline files with the owner's token, so its tickets look owner-authored; the label says otherwise."""

    rig = Rig(tmp_path)
    rig.gh.add_issue(9, "regression on develop: x", labels=("pipeline", "pipe:filed-by-pipeline"))
    rig.engine.sync_issues()
    sha = __import__("subprocess").run(["git", "-C", str(rig.engine.repo), "rev-parse", "origin/develop"], capture_output=True,
                                       text=True).stdout.strip()

    def close(req: StageRequest) -> StageOutcome:
        assert "accepted" in req.contract.close_ticket({"reason": "no-defect", "evidence": [sha]})
        return accepted(req)

    rig.agent.on("explore", close)
    await rig.engine.drive(9)
    assert rig.state(9) == "closed" and rig.gh.issues[9]["state"] == "closed"


async def test_the_owners_own_ticket_still_waits_the_veto_window(tmp_path: Path) -> None:

    rig = Rig(tmp_path)
    rig.gh.add_issue(9, "mine")
    rig.engine.sync_issues()
    sha = __import__("subprocess").run(["git", "-C", str(rig.engine.repo), "rev-parse", "origin/develop"], capture_output=True,
                                       text=True).stdout.strip()

    def close(req: StageRequest) -> StageOutcome:
        req.contract.close_ticket({"reason": "no-defect", "evidence": [sha]})
        return accepted(req)

    rig.agent.on("explore", close)
    await rig.engine.drive(9)
    assert rig.state(9) == "paused" and rig.gh.issues[9]["state"] == "open"
