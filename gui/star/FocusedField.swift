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
    case cannyMinThreshold
    case cannyMaxThreshold
    case numberStaticNeighborFrames
    case frameStaticNeighborFrames
    case alignmentMaxKeypoints
    case alignmentBaseImageDilateSize
    case alignmentBaseImageThresholdValue
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
    case mergeStreamingThresholdMB
    case outlierMemoryMultiplier
    case mergeMemoryMultiplier
    case horizonMemoryMultiplier
    case horizonReservationFloorMB
    case memoryBudgetFraction
}

