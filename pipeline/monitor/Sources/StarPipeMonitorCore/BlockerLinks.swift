import Foundation

/// The links that name a queued ticket's open blockers, in the sidebar row and the detail pane.
public enum BlockerLinks {
    public struct Link: Equatable, Sendable, Identifiable {
        /// `#84`
        public var label: String
        public var url: URL
        public var id: String { label }
    }

    public struct DetailRow: Equatable, Sendable, Identifiable {
        public var number: Int
        public var label: String
        public var title: String
        public var url: URL
        public var id: Int { number }
    }

    /// `https://github.com/<repo>/issues/<n>`; nil without a repo.
    public static func issueURL(repo: String, number: Int) -> URL? {
        repo.isEmpty ? nil : URL(string: "https://github.com/\(repo)/issues/\(number)")
    }

    /// The row's `queued:` prefix and one link per blocker, or nil when the row is plain activity text
    /// (not blocked, an activity line of another shape, or no repo to link to).
    public static func row(activity: String, blockedBy: [Int], repo: String) -> (prefix: String, links: [Link])? {
        guard !blockedBy.isEmpty, activity.hasPrefix("queued:") else { return nil }
        let links = blockedBy.compactMap { n in issueURL(repo: repo, number: n).map { Link(label: "#\(n)", url: $0) } }
        return links.count == blockedBy.count ? ("queued:", links) : nil
    }

    /// The detail pane's "Blocked by" lines, one per blocker; empty means the section is not shown.
    public static func detailRows(blockers: [BlockerRef], repo: String) -> [DetailRow] {
        blockers.compactMap { b in
            issueURL(repo: repo, number: b.number).map { DetailRow(number: b.number, label: "#\(b.number)", title: b.title, url: $0) }
        }
    }
}
