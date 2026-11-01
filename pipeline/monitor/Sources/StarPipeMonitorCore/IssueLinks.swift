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
}

/// One entry of `POST /v1/enqueue`'s results: "labelled", "already queued", "rejected: …" or "error: …".
public struct EnqueueResult: Decodable, Sendable, Equatable {
    public var number: Int
    public var result: String
}
