import Foundation

// What the proposal pane says, worked out here (not in the view) so it can be tested: the issue body split into blocks the view
// lays out, the readiness wording, ages and the comment overflow line.

/// The issue body is GitHub markdown written to the ticket format. SwiftUI's `Text` renders inline markdown but ignores blocks, so
/// the view gets the blocks and renders each one's inline text itself.
public enum MarkdownBlocks {
    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        /// `indent` is the nesting depth (two spaces, or a tab, per level).
        case bullet(indent: Int, text: String)
        case paragraph(String)
        /// A fenced code block's lines joined by newlines; the info string (language) is dropped.
        case code(String)
    }

    /// Split markdown into headings (`#`…`######`), bullets (`-`, `*`, `+`, `1.`), paragraphs and fenced code (``` or ~~~).
    /// A bullet's indented continuation lines belong to it, a paragraph runs to the next blank line, whole-line HTML comments
    /// (the pipeline's `<!-- starpipe:… -->` markers) are dropped, and a fence left open runs to the end.
    public static func split(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var fence = ""
        var inBullet = false   // the last line read belonged to a bullet, so an indented line continues it

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }

        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if trimmed.hasPrefix(fence) && trimmed.allSatisfy({ $0 == fence.first }) {
                    blocks.append(.code(code!.joined(separator: "\n")))
                    code = nil
                } else {
                    code!.append(line)
                }
                continue
            }
            if let f = fenceOpener(trimmed) {
                flush()
                inBullet = false
                fence = f
                code = []
                continue
            }
            if trimmed.isEmpty { flush(); inBullet = false; continue }
            if trimmed.hasPrefix("<!--") && trimmed.hasSuffix("-->") { continue }
            if let (level, text) = heading(trimmed) {
                flush()
                inBullet = false
                blocks.append(.heading(level: level, text: text))
            } else if let text = bulletText(trimmed) {
                flush()
                inBullet = true
                blocks.append(.bullet(indent: indentLevel(line), text: text))
            } else if inBullet, line.first == " " || line.first == "\t", case .bullet(let indent, let text)? = blocks.last {
                blocks[blocks.count - 1] = .bullet(indent: indent, text: text + " " + trimmed)
            } else {
                inBullet = false
                paragraph.append(trimmed)
            }
        }
        flush()
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        return blocks
    }

    private static func fenceOpener(_ trimmed: String) -> String? {
        for mark in ["```", "~~~"] where trimmed.hasPrefix(mark) {
            let run = trimmed.prefix { $0 == mark.first }
            return String(run)
        }
        return nil
    }

    private static func heading(_ trimmed: String) -> (Int, String)? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return (hashes, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func bulletText(_ trimmed: String) -> String? {
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
        }
        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty, trimmed.dropFirst(digits.count).hasPrefix(". ") {
            return trimmed.dropFirst(digits.count + 2).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func indentLevel(_ line: String) -> Int {
        var spaces = 0
        for c in line {
            if c == " " { spaces += 1 } else if c == "\t" { spaces += 2 } else { break }
        }
        return spaces / 2
    }
}

/// The Readiness box: one line per fact, each flagged when it should catch the owner's eye.
public enum ProposalReadinessText {
    public struct Line: Equatable, Sendable {
        public var text: String
        public var warn: Bool
    }

    public static func lines(_ r: ProposalReadiness) -> [Line] {
        var lines = [Line(text: r.lintOk ? "Ticket lint: passes" : "Ticket lint: fails", warn: !r.lintOk)]
        lines += r.errors.map { Line(text: "error: \($0)", warn: true) }
        lines += r.warnings.map { Line(text: "warning: \($0)", warn: false) }
        lines.append(r.hasPlan ? Line(text: "Carries a ## Plan, so the pipeline skips EXPLORE", warn: false)
                               : Line(text: "No ## Plan: an agent explores the code first", warn: false))
        if r.pipeline.isEmpty {
            lines.append(Line(text: "No ## Pipeline overrides", warn: false))
        } else {
            let asked = r.pipeline.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            lines.append(Line(text: "## Pipeline asks for: \(asked)", warn: false))
        }
        lines.append(Line(text: "queue: \(r.queue.open) of \(r.queue.max) slots used", warn: false))
        if r.queue.open >= r.queue.max {
            lines.append(Line(text: "Approving will be refused: the queue is full", warn: true))
        }
        return lines
    }
}

public enum ProposalText {
    /// "3 days ago" for an ISO 8601 timestamp, measured against `now` (epoch seconds, the snapshot's clock); nil when unparseable.
    public static func age(iso: String?, now: Double) -> String? {
        guard let iso, let then = parse(iso) else { return nil }
        let seconds = Int(now - then.timeIntervalSince1970)
        if seconds < 60 { return "just now" }
        let units: [(String, Int)] = [("year", 365 * 86400), ("month", 30 * 86400), ("day", 86400), ("hour", 3600), ("minute", 60)]
        for (name, size) in units where seconds >= size {
            let n = seconds / size
            return "\(n) \(name)\(n == 1 ? "" : "s") ago"
        }
        return "just now"
    }

    /// "3d ago", "5h ago", "12m ago" for the proposal rows; nil when unparseable.
    public static func shortAge(iso: String?, now: Double) -> String? {
        guard let iso, let then = parse(iso) else { return nil }
        let seconds = Int(now - then.timeIntervalSince1970)
        if seconds < 60 { return "just now" }
        let units: [(String, Int)] = [("y", 365 * 86400), ("mo", 30 * 86400), ("d", 86400), ("h", 3600), ("m", 60)]
        for (name, size) in units where seconds >= size { return "\(seconds / size)\(name) ago" }
        return "just now"
    }

    private static func parse(_ iso: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: iso) ?? fractional.date(from: iso)
    }

    /// "author · 2 hours ago" above a comment.
    public static func commentHeader(_ c: ProposalComment, now: Double) -> String {
        [c.author ?? "unknown", age(iso: c.createdAt, now: now)].compactMap { $0 }.joined(separator: " · ")
    }

    /// "N earlier comments on GitHub" when the issue has more comments than the daemon sent; nil otherwise.
    public static func commentOverflow(count: Int, sent: Int) -> String? {
        let missing = count - sent
        guard missing > 0 else { return nil }
        return "\(missing) earlier comment\(missing == 1 ? "" : "s") on GitHub"
    }
}
