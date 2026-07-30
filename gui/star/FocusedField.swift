import SwiftUI

enum FocusedField: Hashable {
    case trashLevel
    case smallTrashMax
    case minimumClassificationSize
    case numberOfFramesToProcess
    case numberOfFramesToProcessConcurrently
    case numberOfNeighborFrames
    case alignmentKeypointDivisor
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
    case referenceHorizonBrightnessRefinementSearchRadius
    case referenceHorizonBrightnessRefinementHistogramBuckets
    case referenceHorizonNeighborhoodSize
    case horizonSpikeMaxWidth
    case horizonSpikeMaxDeviationFraction
    case horizonSpikeWindowHalf
    case keypointMemoryMultiplier
    case maxConcurrentKeypointOps
    case outlierMemoryMultiplier
    case mergeMemoryMultiplier
    case horizonMemoryMultiplier
    case horizonReservationFloorMB
    case memoryBudgetFraction
}

