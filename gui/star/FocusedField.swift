import SwiftUI

enum FocusedField: Hashable {
    case trashLevel
    case smallTrashMax
    case minimumClassificationSize
    case numberOfFramesToProcess
    case numberOfFramesToProcessConcurrently
    case numberOfNeighborFrames
    case pixelThreshold
    case maxZoomLevel
    case horizonStripWidth
    case cannyMinThreshold
    case cannyMaxThreshold
    case maxConcurrentHorizons
    case maxConcurrentKeypoints
    case maxConcurrentHomographys
    case maxConcurrentMerges
    case numberStaticNeighborFrames
    case frameStaticNeighborFrames
    case frameAlignedNeighborFrames
    case horizonVerticalShiftAmount
    case minAlignmentFrames
    case alignmentMaxKeypoints
    case alignmentBaseImageDilateSize
    case alignmentBaseImageThresholdValue
    case alignmentNeighborDilateSize
    case alignmentNeighborThresholdValue
    case alignmentGroundHorizonExtension
    case alignmentSkyHorizonExtension
    case homographySmothingEpsilon
    case referenceHorizonSmoothingMaxDistance
    case keypointMemoryMultiplier
    case outlierMemoryMultiplier
    case mergeMemoryMultiplier
    case memoryBudgetFraction
}

