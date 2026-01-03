import Foundation
import kht_bridge

public enum AlignmentState: Int, Codable, CaseIterable, Sendable, CustomStringConvertible {
    case unableToDetectKeypoints = 0
    case notEnoughKeypoints
    case noHomographyFound
    case homographySuccess
    case usedExistingHomography
    case noAlignment
    case unknown

    public var description: String {
        switch self {
        case .unableToDetectKeypoints:
            "no keypoints detected"
        case .notEnoughKeypoints:
            "not enough keypoints"
        case .noHomographyFound:
            "no homography found"
        case .homographySuccess:
            "success"
        case .usedExistingHomography:
            "used existing"
        case .noAlignment:
            "none"
        case .unknown:
            "unknown"
        }
    }
    
    // MARK: - Init from Objective-C enum
    public init?(objcState: AlignmentStateObjC) {
        self.init(rawValue: objcState.rawValue)
    }

    // MARK: - Convert to Objective-C enum
    public var objcValue: AlignmentStateObjC? {
        AlignmentStateObjC(rawValue: self.rawValue)
    }
}
