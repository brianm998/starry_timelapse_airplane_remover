import Foundation

/// The sidebar's ticket search: a query and which fields it looks in. Case-insensitive substring match.
public struct TicketSearch: Equatable, Sendable {
    public var query = ""
    /// The ticket's identity: its number (`#123` or `123`) and its branch name.
    public var matchName = true
    public var matchTitle = true
    public var matchBody = true

    public init(query: String = "", matchName: Bool = true, matchTitle: Bool = true, matchBody: Bool = true) {
        self.query = query
        self.matchName = matchName
        self.matchTitle = matchTitle
        self.matchBody = matchBody
    }

    /// An empty query filters nothing.
    public var isActive: Bool { !query.isEmpty }

    /// Empties the query; the field toggles stay as they are.
    public mutating func clear() { query = "" }

    public func matches(_ ticket: TicketSnap) -> Bool {
        guard isActive else { return true }
        func has(_ text: String) -> Bool { text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        if matchName && (has("#\(ticket.number)") || has(ticket.branch ?? "")) { return true }
        if matchTitle && has(ticket.title) { return true }
        if matchBody && has(ticket.body) { return true }
        return false
    }

    public func filter(_ tickets: [TicketSnap]) -> [TicketSnap] { isActive ? tickets.filter(matches) : tickets }
}
