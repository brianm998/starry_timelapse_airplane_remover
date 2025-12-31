import Foundation
import kht_bridge

public enum AlignmentState: Int, Codable, CaseIterable, Sendable {
    case unableToDetectKeypoints = 0
    case notEnoughKeypoints
    case noHomographyFound
    case homographySuccess
    case unknown

    // MARK: - Init from Objective-C enum
    public init?(objcState: AlignmentStateObjC) {
        self.init(rawValue: objcState.rawValue)
    }

    // MARK: - Convert to Objective-C enum
    public var objcValue: AlignmentStateObjC? {
        AlignmentStateObjC(rawValue: self.rawValue)
    }
}
