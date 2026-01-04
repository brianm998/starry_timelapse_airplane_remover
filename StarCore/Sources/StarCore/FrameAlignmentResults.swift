import Foundation

public struct FrameAlignmentResults: Codable, Sendable {
    public let numberAligned: [AlignmentWarpInfoCodable]
    public let numberFailed: [AlignmentWarpInfoCodable]

    public var total: Int { numberAligned.count + numberFailed.count }

    public func matches(
      deviations: [Int: Double], // frame offset to expected deviance
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
                
                if let expectedDeviation = deviations[frameOffset] {
                    // compare deviation to median
                    if deviation < expectedDeviation * variance,
                       deviation > expectedDeviation / variance
                    {
                        // this neighbor was aligned good enough
                        alignedDeviationCount += 1
                    }
                }
            }
        }
        return alignedDeviationCount == self.numberAligned.count 
    }
}

