import Foundation
import StarCppBridge

public enum AlignmentState: Int, Codable, CaseIterable, Sendable, CustomStringConvertible {
    case unableToDetectKeypoints = 0
    case notEnoughKeypoints
    case noHomographyFound
    case homographySuccess
    case usedExistingHomography
    case noAlignment
    case unknown

    /// Shown in the gui's alignment window and inside the cli's per-frame progress line, so it
    /// is localized. Safe to translate: the enum persists as its `Int` rawValue, and nothing
    /// compares these strings.
    public var description: String {
        switch self {
        case .unableToDetectKeypoints:
            localized("alignment_state.unable_to_detect_keypoints")
        case .notEnoughKeypoints:
            localized("alignment_state.not_enough_keypoints")
        case .noHomographyFound:
            localized("alignment_state.no_homography_found")
        case .homographySuccess:
            localized("alignment_state.homography_success")
        case .usedExistingHomography:
            localized("alignment_state.used_existing_homography")
        case .noAlignment:
            localized("alignment_state.no_alignment")
        case .unknown:
            localized("alignment_state.unknown")
        }
    }
    
    // MARK: - Init from Objective-C enum
    public init?(objcState: AlignmentStateObjC) {
        self.init(rawValue: Int(objcState.rawValue))
    }

    // MARK: - Convert to Objective-C enum
    public var objcValue: AlignmentStateObjC? {
        // AlignmentStateObjC is a plain C enum. Swift's Clang importer picks
        // a different rawValue integer width per platform: UInt32 on macOS
        // (Clang) but Int32 on Windows (MSVC) and Linux (Clang on glibc).
        // numericCast bridges the gap without a #if os() wedge here.
        AlignmentStateObjC(rawValue: numericCast(self.rawValue))
    }
}
