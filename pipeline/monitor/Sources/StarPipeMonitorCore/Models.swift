import Foundation

// The shapes of the daemon's /v1 documents. Keys are spelled out (no snake_case strategy) because dictionary keys such as
// job names must not be rewritten. tests/test_snapshot.py fails when the daemon's snapshot and Fixtures/snapshot.json
// disagree, and the Swift tests decode the same fixture, so this file cannot drift from the daemon unnoticed.

public struct Snapshot: Codable, Sendable, Equatable {
    public var daemon: DaemonInfo?
    public var pause: String?
    public var usagePauseUntil: String?
    public var heavy: HeavyState
    public var tickets: [TicketSnap]
    public var groups: [String]
    public var runtime: RuntimeInfo
    public var landing: Landing
    public var develop: Develop
    public var interventionsWeek: [String: Int]
    public var eventsCursor: Int
    public var now: Double
    public var version: String
    public var repo: String
    public var nightly: NightlyInfo?

    enum CodingKeys: String, CodingKey {
        case daemon, pause, heavy, tickets, groups, runtime, landing, develop, now, version, repo, nightly
        case usagePauseUntil = "usage_pause_until"
        case interventionsWeek = "interventions_week"
        case eventsCursor = "events_cursor"
    }
}

/// The latest nightly (plan §8.1 T4): `line` is the daemon's one-line summary, so the app never composes its own.
public struct NightlyInfo: Codable, Sendable, Equatable {
    public var id: Int
    public var at: Double
    public var running: Bool
    public var status: String
    public var ref: String
    public var sha: String
    public var reds: Int
    public var line: String
}

public struct DaemonInfo: Codable, Sendable, Equatable {
    public var pid: Int
    public var since: Double
    public var lastPoll: Double?
    public var error: String

    enum CodingKeys: String, CodingKey { case pid, since, error; case lastPoll = "last_poll" }
}

public struct HeavyState: Codable, Sendable, Equatable {
    public var holders: [Holder]
    public var queue: [Waiter]
}

public struct Holder: Codable, Sendable, Equatable {
    public var pid: Int
    public var ticket: String
    public var cmd: String
    public var since: Double
}

public struct Waiter: Codable, Sendable, Equatable {
    public var priority: Int
    public var enqueuedAt: Double
    public var pid: Int
    public var ticket: String
    public var cmd: String

    enum CodingKeys: String, CodingKey { case priority, pid, ticket, cmd; case enqueuedAt = "enqueued_at" }
}

public struct RuntimeInfo: Codable, Sendable, Equatable {
    public var sha: String
    public var behindDevelop: Int

    enum CodingKeys: String, CodingKey { case sha; case behindDevelop = "behind_develop" }
}

public struct Landing: Codable, Sendable, Equatable {
    public var paused: Bool
    public var stopLine: String?

    enum CodingKeys: String, CodingKey { case paused; case stopLine = "stop_line" }
}

public struct Develop: Codable, Sendable, Equatable {
    public var gate: [String: String]
    public var knownRed: Int

    enum CodingKeys: String, CodingKey { case gate; case knownRed = "known_red" }
}

public struct TicketSnap: Codable, Sendable, Equatable, Identifiable {
    public var number: Int
    public var title: String
    public var state: String
    public var priority: Int
    public var group: String
    public var activity: String
    public var blockedBy: [Int]
    public var prNumber: Int?
    public var branch: String?
    public var worktree: String?
    public var parkReason: String?
    public var question: String?
    public var stages: [StageSnap]

    public var id: Int { number }

    enum CodingKeys: String, CodingKey {
        case number, title, state, priority, group, activity, branch, worktree, question, stages
        case blockedBy = "blocked_by"
        case prNumber = "pr_number"
        case parkReason = "park_reason"
    }
}

public struct StageSnap: Codable, Sendable, Equatable {
    public var stage: String
    public var attempt: Int
    public var model: String
    public var started: Double
    public var ended: Double?
    public var lockWaitS: Double
    public var outcome: String?

    enum CodingKeys: String, CodingKey {
        case stage, attempt, model, started, ended, outcome
        case lockWaitS = "lock_wait_s"
    }
}

/// `GET /v1/tickets/{n}`: what the detail pane shows beyond the snapshot row.
public struct TicketDetail: Codable, Sendable, Equatable {
    public var number: Int
    public var plan: PlanSummary?
    public var checks: [CheckRow]
    public var question: QuestionRow?
}

public struct PlanSummary: Codable, Sendable, Equatable {
    public var summary: String
    public var acceptance: [AcceptanceRow]
}

public struct AcceptanceRow: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var check: String
}

public struct CheckRow: Codable, Sendable, Equatable {
    public var checkId: String
    public var result: String

    enum CodingKeys: String, CodingKey { case result; case checkId = "check_id" }
}

public struct QuestionRow: Codable, Sendable, Equatable {
    public var text: String
}

/// One line of the event stream (`GET /v1/events` as server-sent events).
public struct ServerEvent: Sendable, Equatable {
    public var id: Int
    public var ticket: Int?
    public var kind: String
    public var data: [String: String]
    public var at: Double
}

public enum GroupTitle {
    public static func title(_ group: String) -> String {
        switch group {
        case "needs_you": "Needs you"
        case "running": "Running"
        case "waiting": "Waiting"
        case "queued": "Queued"
        case "landed_today": "Landed today"
        case "failed": "Failed"
        default: group
        }
    }
}
