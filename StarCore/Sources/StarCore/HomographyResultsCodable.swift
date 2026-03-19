import Foundation
import logging
import KHTSwift

public struct HomographyResultsCodable: Codable, Sendable {
    public let frameIndex: Int
    public let neighborHomography: [AlignmentWarpInfoCodable]

    public var total: Int { neighborHomography.count }

    public init(for frameIndex: Int,
                with neighborHomography: [AlignmentWarpInfoCodable])
    {
        self.frameIndex = frameIndex
        self.neighborHomography = neighborHomography.sorted { $0.frameIndex < $1.frameIndex }
    }
    
    public init(from result: HomographyResult) {
        self.frameIndex = Int(result.frameIndex)
        self.neighborHomography = result.warpInfo
          .map { $0.toCodable() }
          .sorted { $0.frameIndex < $1.frameIndex }
    }

    public func adjust(for newFrameIndex: Int) -> HomographyResultsCodable {
        let frameDistance = newFrameIndex - frameIndex
        return HomographyResultsCodable(
          for: newFrameIndex,
          with: neighborHomography.map {
            AlignmentWarpInfoCodable(
              homography: $0.homography,
              deviation: $0.deviation,
              alignmentState: $0.alignmentState,
              frameIndex: $0.frameIndex + frameDistance
            )
        }
        )
    }

    func mappedHomography() -> [Int: MatWrapper] {
        var ret: [Int: MatWrapper] = [:]
        for homography in neighborHomography {
            let warpInfo = AlignmentWarpInfo.from(codable: homography)
            let offset = homography.frameIndex - frameIndex
            ret[offset] = warpInfo.homography
        }
        return ret
    }

    // the average of the deviation of neighbors by frame distance
    public var compositeDeviation: Double {
        var ret: Double = 0
        var count: Double = 0
        
        for homographyInfo in neighborHomography {
            if let homography = homographyInfo.homography {
                let offset = Double(abs(homographyInfo.frameIndex - frameIndex))
                ret += homographyDeviation(homography)/offset
                count += 1
            }
        }

        ret /= count
        
        return ret
    }

    // apply some basic heurstics to the neighbor homography to see if it looks ok
    // weeds out some obvously bad homographies
    public var alignmentLooksOk: Bool {
        
        var slopes: [Double] = []
                    
        for homography in neighborHomography {
            let frameDistance = abs(self.frameIndex-Int(homography.frameIndex))
            slopes.append(homography.deviation/Double(frameDistance))
        }

        var goodWarps: [AlignmentWarpInfoCodable] = []
        var badWarps: [AlignmentWarpInfoCodable] = []

        slopes.sort(by: { $0 < $1 })
        
        let medianIndex = slopes.count/2
        if medianIndex < slopes.count {
            let medianSlope = slopes[medianIndex]
            //Log.d("frame \(frameIndex) got medianSlope \(medianSlope)")
            for homography in neighborHomography {
                let frameDistance = abs(self.frameIndex-Int(homography.frameIndex))
                let alignmentSlope = homography.deviation/Double(frameDistance)
                /*
                 two checks here:
                 - deviation isn't too large in general
                   fast clouds without stars can get large deviation
                 - alignment slope is close to constant
                   deviation should be evenly spaced by frame distance
                 */


                let maxHomographyDivergence: Double = 20 // XXX make this a parameter
                let maxSlopeDivergence: Double = 1.08    // XXX make this a parameter
                
                if homography.deviation < maxHomographyDivergence*Double(frameDistance),  
                   alignmentSlope < medianSlope * maxSlopeDivergence,
                   alignmentSlope > medianSlope / maxSlopeDivergence
                {
                    // rough estimate
                    goodWarps.append(homography)
                } else {
                    badWarps.append(homography)
                }
            }
        } else {
            Log.d("frame \(frameIndex) has NO medianSlope :(")
            // ALL FAIL :(
            // here we don't know the median, so all are bad :(
            badWarps = neighborHomography
        }
        
        return goodWarps.count != 0 && badWarps.count == 0
    }
}

