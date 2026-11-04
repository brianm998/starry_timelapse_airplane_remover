import Foundation

/// How a ticket's question is laid out as choices: one row per option, then a final "Other" row for a free-text answer.
public enum QuestionChoices {
    public enum Choice: Equatable, Sendable {
        case option(String, isRecommended: Bool)
        case other
    }

    /// One row per option in the order given, then `.other`; no rows at all for a question without options,
    /// which is answered in the plain free-text field.
    public static func rows(for question: QuestionRow) -> [Choice] {
        guard !question.options.isEmpty else { return [] }
        let recommended = question.recommendation.map(normalised) ?? ""
        // Only the first match is marked, so duplicate options never show two "Recommended" rows.
        var marked = false
        var rows: [Choice] = question.options.map { option in
            let hit = !marked && !recommended.isEmpty && normalised(option) == recommended
            marked = marked || hit
            return .option(option, isRecommended: hit)
        }
        rows.append(.other)
        return rows
    }

    public static func hasOptions(_ question: QuestionRow) -> Bool { !question.options.isEmpty }

    /// What clicking `choice` sends: the option's own text, or for Other what the owner typed, trimmed.
    /// Nil when there is nothing to send (Other with empty or blank text).
    public static func answerText(for choice: Choice, typed: String) -> String? {
        switch choice {
        case .option(let text, _): return text
        case .other:
            let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func normalised(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
