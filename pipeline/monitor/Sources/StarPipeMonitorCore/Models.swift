import Foundation

// The shapes of the daemon's /v1 documents. Keys are spelled out (no snake_case strategy) because dictionary keys such as
// job names must not be rewritten. tests/test_snapshot.py fails when the daemon's snapshot and Fixtures/snapshot.json
// disagree, and the Swift tests decode the same fixture, so this file cannot drift from the daemon unnoticed.

public struct Snapshot: Codable, Sendable, Equatable {
    public var daemon: DaemonInfo?
    public var pause: String?
    /// Whether the daemon's spoken alerts are muted.
    public var muted: Bool
    /// How many tickets may run at once (the owner's override, else config.toml).
    public var maxActive: Int
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
        case daemon, pause, muted, heavy, tickets, groups, runtime, landing, develop, now, version, repo, nightly
        case usagePauseUntil = "usage_pause_until"
        case maxActive = "max_active"
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
    /// The model of the stage running now; nil when no stage is open.
    public var model: String?
    public var blockedBy: [Int]
    public var prNumber: Int?
    public var branch: String?
    public var worktree: String?
    public var parkReason: String?
    public var question: String?
    public var stages: [StageSnap]

    public var id: Int { number }

    enum CodingKeys: String, CodingKey {
        case number, title, state, priority, group, activity, model, branch, worktree, question, stages
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
    /// The open issues this ticket waits for; empty from a daemon that predates the field.
    public var blockers: [BlockerRef]

    enum CodingKeys: String, CodingKey { case number, plan, checks, question, blockers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        plan = try c.decodeIfPresent(PlanSummary.self, forKey: .plan)
        checks = try c.decode([CheckRow].self, forKey: .checks)
        question = try c.decodeIfPresent(QuestionRow.self, forKey: .question)
        blockers = try c.decodeIfPresent([BlockerRef].self, forKey: .blockers) ?? []
    }
}

/// An open issue a ticket is blocked by. The title is empty when the daemon could not look it up.
public struct BlockerRef: Codable, Sendable, Equatable, Identifiable {
    public var number: Int
    public var title: String

    public init(number: Int, title: String) {
        self.number = number
        self.title = title
    }

    public var id: Int { number }
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

/// What the Overview page shows, worked out from the snapshot alone.
public enum Overview {
    /// States with a model stage open (the daemon's ACTIVE_STATES).
    public static let activeStates: Set<String> = ["exploring", "developing", "verifying", "review"]
    /// The landing queue in landing order: CI first, then the ticket landing, then the ones about to publish.
    public static let landingStates = ["ci", "landing", "ready"]
    /// The most tickets the daemon accepts for `max_active`.
    public static let maxActiveCap = 6

    public struct Session: Equatable, Sendable, Identifiable {
        public var ticket: TicketSnap
        /// The open stage's name, else the ticket's state.
        public var stage: String
        public var id: Int { ticket.number }
    }

    public struct ModelGroup: Equatable, Sendable, Identifiable {
        public var model: String
        public var sessions: [Session]
        public var id: String { model }
    }

    /// Tickets with a model session open, grouped by model (alphabetical), each group's tickets by number.
    public static func activeModels(_ tickets: [TicketSnap]) -> [ModelGroup] {
        var byModel: [String: [Session]] = [:]
        for t in tickets where activeStates.contains(t.state) {
            guard let model = t.model else { continue }
            let stage = t.stages.last { $0.ended == nil }?.stage ?? t.state
            byModel[model, default: []].append(Session(ticket: t, stage: stage))
        }
        return byModel.keys.sorted().map { ModelGroup(model: $0, sessions: byModel[$0]!.sorted { $0.ticket.number < $1.ticket.number }) }
    }

    public static func landingQueue(_ tickets: [TicketSnap]) -> [TicketSnap] {
        landingStates.flatMap { state in tickets.filter { $0.state == state }.sorted { $0.number < $1.number } }
    }
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
