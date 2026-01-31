import Foundation
import kht_bridge

public struct HomographyResultsCodable: Codable, Sendable {
    public let homography: [AlignmentWarpInfoCodable]

    public var total: Int { homography.count }

    public init(with homography: [AlignmentWarpInfoCodable]) {
        self.homography = homography
    }
    
    public init(from result: HomographyResult) {
        self.homography = result.warpInfo.map { $0.toCodable() }
    }

/*
    public var wasSuccessfullyAligned: Bool {
        self.numberAligned.count != 0 &&
        self.numberFailed.count == 0
    }
    
    public func matches(
      deviations: [Int: [Double]], // frame offset to expected min/max deviance
      by variance: Double,       // 1.25 for 25% change allowed
      at frameIndex: Int,        // frame index of frame being processed
      successfulHomographyOnly: Bool = false
    ) -> Bool {
        var alignedDeviationCount = 0
        for result in self.numberAligned {
            if (successfulHomographyOnly && result.alignmentState == .homographySuccess) || !successfulHomographyOnly,
               let homography = result.homography
            {
                let frameOffset = result.frameIndex - frameIndex
                let deviation = homographyDeviation(homography)
                
                if let deviationMinMax = deviations[frameOffset] {
                    let minExpectedDeviation = deviationMinMax[0]
                    let maxExpectedDeviation = deviationMinMax[1]

                    // compare deviation to expected results
                    if deviation < maxExpectedDeviation * variance,
                       deviation > minExpectedDeviation / variance
                    {
                        // this neighbor was aligned good enough
                        alignedDeviationCount += 1
                    }
                }
            }
        }
        return alignedDeviationCount == self.numberAligned.count 
    }
*/
}

