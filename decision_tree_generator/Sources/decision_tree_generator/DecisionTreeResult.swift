import Foundation

// used for sorting and displaying results of tests on decision trees

struct DecisionTreeResult: Comparable {
    let score: Double
    let message: String

    public static func < (lhs: Self, rhs: Self) -> Bool {
        return lhs.score < rhs.score
    }
}

