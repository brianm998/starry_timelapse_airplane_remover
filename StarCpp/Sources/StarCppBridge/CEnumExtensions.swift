// CEnumExtensions.swift — Swift-friendly extensions for C enums
// Since plain C enums (not NS_ENUM) are imported as global constants,
// we add static properties to make them usable with dot syntax.
import StarCpp

public extension AlignmentType {
    static let sky   = AlignmentTypeSky
    static let earth = AlignmentTypeEarth
}

public extension FeatureMatchMethod {
    static let bruteForce = FeatureMatchMethodBruteForce
    static let knnLowes   = FeatureMatchMethodKNNLowes
    static let FLANN      = FeatureMatchMethodFLANN
}

public extension AlignmentStateObjC {
    static let unableToDetectKeypoints = AlignmentStateObjCUnableToDetectKeypoints
    static let notEnoughKeypoints      = AlignmentStateObjCNotEnoughKeypoints
    static let noHomographyFound       = AlignmentStateObjCNoHomographyFound
    static let homographySuccess       = AlignmentStateObjCHomographySuccess
    static let usedExistingHomography  = AlignmentStateObjCUsedExistingHomography
    static let noAlignment             = AlignmentStateObjCNoAlignment
    static let unknown                 = AlignmentStateObjCUnknown
}

public extension ObjCAlignmentStep {
    static let start                       = ObjCAlignmentStepStart
    static let baseKeypointDetection       = ObjCAlignmentStepBaseKeypointDetection
    static let baseKeypointDetectionComplete = ObjCAlignmentStepBaseKeypointDetectionComplete
    static let neighborKeypointDetection   = ObjCAlignmentStepNeighborKeypointDetection
    static let neighborKeypointMatch       = ObjCAlignmentStepNeighborKeypointMatch
    static let aligningNeighbor            = ObjCAlignmentStepAligningNeighbor
    static let loadingNeighbor             = ObjCAlignmentStepLoadingNeighbor
    static let complete                    = ObjCAlignmentStepComplete
}
