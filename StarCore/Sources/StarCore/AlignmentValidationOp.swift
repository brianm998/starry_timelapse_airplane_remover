import Foundation
import logging

/*
 This operation takes the full detected homography for the entire sequence,
 and then cleans it up to make sure it is not wrong anywhere.
 */
final class AlignmentValidationOp: AsyncOperation, @unchecked Sendable {
    let frames: [FrameAirplaneRemover]
    let configManager: ConfigManager
    
    init(frames: [FrameAirplaneRemover], configManager: ConfigManager) {
        self.frames = frames
        self.configManager = configManager
    }

    override func execute() {
        task = Task {
            defer {
                Log.d("end")
                finish()
            }

            Log.d("start")
            let config = await configManager.config()
            if config.tripodHeadWasMoving {
                await validateMovingStarAlignment()
            } else {
                // tripod was stationary
                try await self.validateStaticStarAlignment()
            }

            // XXX still need to handle earth alignment if enabled
        }
    }

    // runs on a static sequence after homography is known for each frame and its neighbors
    // finds the 'best' homography and applies it to all frames, to keep the video smooth.
    public func validateStaticStarAlignment() async throws {
        Log.d("doing static star alignment validation")
        var homographies: [HomographyResultsCodable] = []
        for frame in frames {
            if let homography = await frame.getNeighborStarHomography(),
               homography.alignmentLooksOk
            {
                homographies.append(homography)
            }
        }
        if homographies.count == 0 {
            Log.e("ERROR, canceling no homographies found")
            self.cancel()
            // have this abort the operation
            return
        }
        Log.d("found \(homographies.count) neighbor homography groups")

        // sort by composite deviation (average deviation per once frame distance)
        homographies.sort { $0.compositeDeviation < $1.compositeDeviation }

        let medianHomography = homographies[homographies.count/2]
        Log.d("found median homography at frameIndex \(medianHomography.frameIndex)")
        
        // apply the chosen median homography to all frames 
        for frame in frames {
            await frame.set(
              neighborStarHomography:
                medianHomography.adjust(
                  for: frame.frameIndex
                )
            )
        }
        Log.d("done validating static star alignment")
    }


    func validateMovingStarAlignment() async {

        Log.d("validateMovingStarAlignment (gap-fill approach) \(frames.count) frames")

        // Collect results ordered by frame index

        var homographies: [HomographyResultsCodable] = []
        for frame in frames {
            if let homography = await frame.getNeighborStarHomography() {
                homographies.append(homography)
            }
        }

        guard !homographies.isEmpty else {
            Log.e("No homography results found")
            return
        }
        Log.d("validateMovingStarAlignment (gap-fill approach) \(homographies.count) homographies")

        // Classify frames
        let goodFlags = homographies.map(isGood)

        Log.d("found \(goodFlags.count) good flags out of \(homographies.count)")
        
        // Find contiguous bad segments
        var i = 0
        while i < homographies.count {

            // Skip good frames
            if goodFlags[i] {
                i += 1
                continue
            }

            let start = i
            while i < homographies.count && !goodFlags[i] {
                i += 1
            }
            let end = i - 1   // inclusive


            /*
             instead of taking the first 'good' homography,
             look a the previous N 'good' homographies within M distance from i
             choose the one with the median deviation among them all
             */
            let leftGood  = bestHomography(before: start, in: homographies)
            let rightGood = bestHomography(after:  i-1,   in: homographies)

            Log.d("Bad segment \(start)...\(end), leftGood=\(leftGood != nil), rightGood=\(rightGood != nil)")

            // Apply correction strategy
            for idx in start...end {
                let bad = homographies[idx]
                let t = bad.frameIndex

                Log.d("rebuild @ \(idx)")

                let newHomography: [AlignmentWarpInfoCodable]?

                switch (leftGood, rightGood) {

                    // 4a️ Only left side good → flat copy
                case (let lg?, nil):
                    newHomography = zip(lg.neighborHomography, bad.neighborHomography).map {
                        AlignmentWarpInfoCodable(
                          homography: $0.homography,
                          deviation: $0.deviation,
                          alignmentState: .homographySuccess,
                          frameIndex: $1.frameIndex
                        )
                    }

                    // 4b️ Only right side good → flat copy
                case (nil, let rg?):
                    newHomography = zip(rg.neighborHomography, bad.neighborHomography).map {
                        AlignmentWarpInfoCodable(
                          homography: $0.homography,
                          deviation: $0.deviation,
                          alignmentState: .homographySuccess,
                          frameIndex: $1.frameIndex
                        )
                    }

                    // 4c️ Both sides good → interpolate
                case (let lg?, let rg?):
                    let h0 = lg.neighborHomography
                    let h1 = rg.neighborHomography

                    let alpha = Double(idx - start + 1) /
                      Double(end - start + 2)

                    newHomography = interpolateHomography(
                      h0,
                      h1,
                      bad.neighborHomography,
                      alpha: alpha
                    )

                default:
                    newHomography = nil
                }
                if let newHomography {
                    let fuck = HomographyResultsCodable(
                        for: idx, 
                        with: newHomography
                    )
                    Log.d("frame \(idx) is getting newHomography \(newHomography)")
                    await frames[idx].set(
                      neighborStarHomography: fuck
                    )
                }
            }
        }

        Log.d("validateMovingStarAlignment done")
    }
}

func bestHomography(
  before index: Int,
  in homographies: [HomographyResultsCodable],
  checking checkCount: Int = 10 
) -> HomographyResultsCodable? {
    if index <= 0 { return nil }
    let startIndex = index > checkCount ? index - checkCount : 0
    var homographyBasket: [HomographyResultsCodable] = []
    for i in startIndex..<index {
        if homographies[i].alignmentLooksOk {
            homographyBasket.append(homographies[i])
        }
    }
    return bestMedianHomography(in: homographyBasket)
}

func bestHomography(
  after index: Int,
  in homographies: [HomographyResultsCodable],
  checking checkCount: Int = 10 
) -> HomographyResultsCodable? {
    if index >= homographies.count { return nil }
    let startIndex = index+1
    let endIndex = index + checkCount < homographies.count ? index + checkCount : homographies.count 
    var homographyBasket: [HomographyResultsCodable] = []
    for i in startIndex..<endIndex {
        if homographies[i].alignmentLooksOk {
            homographyBasket.append(homographies[i])
        }
    }
    return bestMedianHomography(in: homographyBasket)
}

// returns the best median homography sorted by composite deviation from identity
func bestMedianHomography(
  in homographies: [HomographyResultsCodable]
) -> HomographyResultsCodable? {
    if homographies.count == 0 { return nil }

    let sorted = homographies.sorted() { $0.compositeDeviation < $1.compositeDeviation }

    return sorted[sorted.count/2]
}

func isGood(_ r: HomographyResultsCodable) -> Bool {
    r.alignmentLooksOk &&
    r.neighborHomography.contains { $0.alignmentState == .homographySuccess }
}


func interpolateHomography(
  _ w0: [AlignmentWarpInfoCodable],
  _ w1: [AlignmentWarpInfoCodable],
  _ bad: [AlignmentWarpInfoCodable],
  alpha: Double
) -> [AlignmentWarpInfoCodable] {
    var ret: [AlignmentWarpInfoCodable] = []
    let sortedW0 = w0.sorted { $0.frameIndex < $1.frameIndex }
    let sortedW1 = w1.sorted { $0.frameIndex < $1.frameIndex }
    let sortedBad = bad.sorted { $0.frameIndex < $1.frameIndex }
    for i in 0..<sortedW0.count {
        ret.append(
          AlignmentWarpInfoCodable(
            homography: interpolateHomography(
              sortedW0[i].homography ?? [],
              sortedW1[i].homography ?? [],
              alpha: alpha
            ),
            alignmentState: .homographySuccess,
            frameIndex: sortedBad[i].frameIndex 
          )
        )
    }
    return ret
}

// interpolate linearly between two homographies with given alpha 
func interpolateHomography(
  _ h0: [Double],
  _ h1: [Double],
  alpha: Double
) -> [Double] {
      zip(h0,h1).map { (1.0 - alpha) * $0 + alpha * $1 }
}
