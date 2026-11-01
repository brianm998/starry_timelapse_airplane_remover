import Foundation

/// The + sheet's text box: whatever was on the clipboard, read as issue links separated by any whitespace.
public enum IssueLinks {
    /// The non-empty whitespace-separated tokens of `text`, duplicates collapsed, in first-seen order.
    public static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// `GET /v1/issues/resolve`: an issue link the daemon accepted.
public struct ResolvedIssue: Decodable, Sendable, Equatable {
    public var number: Int
    public var title: String
    public var state: String
    public var queued: Bool
    /// The models the daemon allows per stage, and the stages that take one (absent from an older daemon).
    public var models: [String]?
    public var stages: [String]?
}

/// `POST /v1/enqueue`'s request: the issue numbers and the batch's per-stage model choices.
public enum EnqueueRequest {
    /// The picker value that means "the config's model": nothing is written to the issue.
    public static let defaultChoice = "Default"

    /// `choices` ({stage: picker value}) without the defaults; `models` is left out of the body when nothing is chosen.
    public static func body(numbers: [Int], choices: [String: String]) -> [String: Any] {
        var body: [String: Any] = ["numbers": numbers]
        let chosen = choices.filter { !$0.value.isEmpty && $0.value != defaultChoice }
        if !chosen.isEmpty { body["models"] = chosen }
        return body
    }
}

/// One entry of `POST /v1/enqueue`'s results: "labelled", "already queued", "rejected: …" or "error: …".
public struct EnqueueResult: Decodable, Sendable, Equatable {
    public var number: Int
    public var result: String
}
