import Foundation

/// The two usage-credit items of the header: whether the account can spend credits ("Credits: available / none / —") and,
/// only while they are being spent, "Credits in use: 25%". Pure, so the wording is testable.
public enum CreditText {
    public struct Item: Equatable, Sendable {
        public var label: String
        public var value: String
        public var text: String { "\(label): \(value)" }
    }

    /// "supported" reads "available"; "none" reads "none"; anything else, including nothing reported yet, reads "—".
    public static func support(_ support: String?) -> Item {
        switch support {
        case "supported": Item(label: "Credits", value: "available")
        case "none": Item(label: "Credits", value: "none")
        default: Item(label: "Credits", value: "—")
        }
    }

    /// nil unless credits are being spent. The amount is the reported fraction as a percent; "—" when none was reported.
    public static func inUse(_ use: CreditUse?) -> Item? {
        guard let use else { return nil }
        let amount = use.amount.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        return Item(label: "Credits in use", value: amount)
    }
}
