import Foundation
import logging
import kht_bridge

/// Refines the horizon mask for a single frame using two complementary passes:
///
/// **Pass 1 – Warped-mask aggregation (temporal)**
/// Warp each neighbour's per-frame horizon mask into the current frame's
/// coordinate system using the star homography, then take the per-column
/// *minimum* Y across all neighbours.  Using minimum (topmost horizon) rather
/// than median means any single neighbour that correctly identifies a mountain
/// peak as ground propagates that information to the current frame.
///
/// **Pass 2 – Alignment-error sky tracking (spatial)**
/// Warp each neighbour's *original image* with the star homography and compute
/// the per-pixel absolute difference from the current frame's original image.
///
/// For a static-camera timelapse the star homography captures the Earth's
/// rotation.  After warping, sky content aligns (low error) but ground content
/// does not (higher error) because the ground is stationary while the stars
/// rotate.  For a panning camera the effect is smaller but the parallax between
/// nearby objects and stars still produces a detectable signal.
///
/// For each column the error profile is scanned downward from the top of the
/// search range; the first y where smoothed error exceeds the local sky baseline
/// is the detected sky/ground boundary — which correctly identifies mountain
/// peaks rather than just the mountain base.
///
/// The two passes are combined by taking the per-column minimum (topmost
/// horizon) and a final light smoothing pass is applied.
public struct HomographyHorizonDetector {

    // MARK: - Configuration

    /// Half-width (in columns) of the sliding-window average applied to both
    /// warped-mask and error-boundary results.
    public var smoothingRadius: Int = 50

    /// How many pixels above the warped-mask baseline to search for the true
    /// skyline via the alignment-error pass.
    public var errorSearchRange: Int = 400

    /// Half-height (±rows) of the vertical sliding window used to smooth the
    /// per-column error profile before thresholding.
    public var errorBlurRadius: Int = 5

    /// Error at a candidate y must exceed the local sky baseline by at least
    /// this multiplicative factor to be accepted as a sky/ground boundary.
    public var errorThresholdFactor: Double = 2.0

    /// Half-width (in columns) of the horizontal sampling window used when
    /// computing the alignment-error profile for Pass 2.  Sampling a wider
    /// horizontal strip captures more stars per sample, giving a more reliable
    /// error signal and reducing spurious spikes.  The detected horizon Y is
    /// still assigned per output column; only the *sampling* window is wider
    /// than a single column.
    public var errorSampleHalfWidth: Int = 50

    public init() {}

    // MARK: - Public entry point

    /// - Parameters:
    ///   - currentWidth:             Width of the current frame in pixels.
    ///   - currentHeight:            Height of the current frame in pixels.
    ///   - neighborHorizonFilenames: Paths to per-frame horizon mask images for
    ///     each neighbour (`.horizon` type, `.original` size).  Used in Pass 1.
    ///   - neighborOriginalFilenames: Paths to original source images for each
    ///     neighbour (`.original` type, `.original` size).  Used in Pass 2.
    ///   - neighborHomographies:     One 9-element row-major 3×3 homography per
    ///     neighbour.  The arrays must all have the same length.
    ///   - currentImage:             Current frame's original image.  Required
    ///     for Pass 2; if `nil` only Pass 1 runs.
    public func detect(
      currentWidth: Int,
      currentHeight: Int,
      neighborHorizonFilenames: [String],
      neighborOriginalFilenames: [String],
      neighborHomographies: [[Double]],
      currentImage: PixelatedImage? = nil
    ) -> HorizonMask? {

        // ------------------------------------------------------------------
        // Pass 1: warp each neighbour's horizon mask, take per-column MIN.
        // ------------------------------------------------------------------
        var perMaskColumnY: [[Int?]] = []

        for (filename, homography) in zip(neighborHorizonFilenames, neighborHomographies) {
            guard let mask = PixelatedImage(filename: filename) else {
                Log.d("HomographyHorizonDetector: could not load horizon mask \(filename)")
                continue
            }
            guard let warped = mask.warpedAsHorizonMask(with: homography) else {
                Log.d("HomographyHorizonDetector: warp failed for \(filename)")
                continue
            }
            perMaskColumnY.append(perColumnFirstDark(in: warped))
        }

        var maskY: [Int?]
        if perMaskColumnY.isEmpty {
            Log.w("HomographyHorizonDetector: no valid warped masks for Pass 1")
            maskY = [Int?](repeating: nil, count: currentWidth)
        } else {
            Log.d("HomographyHorizonDetector: Pass 1 – \(perMaskColumnY.count) warped masks, MIN aggregation")
            let rawY: [Int?] = (0..<currentWidth).map { x in
                let ys = perMaskColumnY.compactMap { col -> Int? in
                    guard x < col.count else { return nil }
                    return col[x]
                }.sorted()
                guard !ys.isEmpty else { return nil }
                return ys[0]    // minimum = topmost horizon = most conservative
            }
            maskY = smooth(rawY, radius: smoothingRadius)
        }

        // ------------------------------------------------------------------
        // Pass 2: alignment-error sky tracking.
        // ------------------------------------------------------------------
        var errorY: [Int?]
        if let currentImage = currentImage, !neighborOriginalFilenames.isEmpty {
            Log.d("HomographyHorizonDetector: Pass 2 – alignment-error pass with \(neighborOriginalFilenames.count) neighbours")
            errorY = alignmentErrorBoundary(
              currentImage: currentImage,
              currentWidth: currentWidth,
              neighborOriginalFilenames: neighborOriginalFilenames,
              neighborHomographies: neighborHomographies,
              baselineY: maskY
            )
        } else {
            errorY = [Int?](repeating: nil, count: currentWidth)
        }

        // ------------------------------------------------------------------
        // Combine: per-column minimum (topmost horizon from either pass).
        // ------------------------------------------------------------------
        let combined: [Int?] = (0..<currentWidth).map { x in
            let m = maskY[x]
            let e = errorY[x]
            switch (m, e) {
            case (nil, nil):           return nil
            case (let v?,  nil):       return v
            case (nil,     let v?):    return v
            case (let v1?, let v2?):   return min(v1, v2)
            }
        }
        let finalY = smooth(combined, radius: 10)

        // Log representative samples for debugging.
        let sampleStride = max(1, currentWidth / 8)
        let samples = stride(from: 0, to: currentWidth, by: sampleStride)
          .map { x -> String in finalY[x].map { "x\(x)→y\($0)" } ?? "x\(x)→nil" }
        Log.d("HomographyHorizonDetector final samples: \(samples)")

        let nsHorizonY: [Any] = finalY.map { y -> Any in
            if let y { return NSNumber(value: y) }
            return NSNull()
        }
        let maskMat = PixelatedImageBridge.binaryHorizonMask(
          withWidth:  Int32(currentWidth),
          height:     Int32(currentHeight),
          horizonY:   nsHorizonY)
        guard let maskImage = PixelatedImage(mat: maskMat) else { return nil }
        return HorizonMask(maskImage)
    }

    // MARK: - Pass 2: alignment-error boundary detection

    /// For each neighbour, warps the original image with the star homography,
    /// diffs against the current frame, and finds the per-column y where the
    /// error first rises above the local sky baseline.  Returns the per-column
    /// minimum across all neighbours (topmost boundary = most conservative).
    private func alignmentErrorBoundary(
      currentImage: PixelatedImage,
      currentWidth: Int,
      neighborOriginalFilenames: [String],
      neighborHomographies: [[Double]],
      baselineY: [Int?]
    ) -> [Int?] {
        var perNeighborBoundaryY: [[Int?]] = []

        for (filename, homography) in zip(neighborOriginalFilenames, neighborHomographies) {
            guard let neighborImage = PixelatedImage(filename: filename) else {
                Log.d("HomographyHorizonDetector: could not load original image \(filename)")
                continue
            }
            guard let warped = neighborImage.warped(with: homography) else {
                Log.d("HomographyHorizonDetector: warp failed for original \(filename)")
                continue
            }
            guard let diff = warped.absDiff(with: currentImage) else {
                Log.d("HomographyHorizonDetector: absDiff failed for \(filename)")
                continue
            }
            let boundaryY = errorBoundaryPerColumn(
              in: diff,
              baselineY: baselineY,
              sampleHalfWidth: errorSampleHalfWidth
            )
            perNeighborBoundaryY.append(boundaryY)
        }

        guard !perNeighborBoundaryY.isEmpty else {
            Log.w("HomographyHorizonDetector: no valid error images for Pass 2")
            return [Int?](repeating: nil, count: currentWidth)
        }

        // Take per-column minimum: if ANY neighbour shows the sky/mountain
        // boundary above the warped-mask baseline, use that estimate.
        let rawY: [Int?] = (0..<currentWidth).map { x in
            let ys = perNeighborBoundaryY.compactMap { col -> Int? in
                guard x < col.count else { return nil }
                return col[x]
            }.sorted()
            guard !ys.isEmpty else { return nil }
            return ys[0]    // minimum
        }
        return smooth(rawY, radius: smoothingRadius)
    }

    /// For each column in the grayscale error image, scans **upward** from the
    /// warped-mask baseline using a two-phase search:
    ///
    /// 1. **Enter** the high-error zone (error ≥ threshold).  This is the
    ///    bottom edge of the region where the sky/mountain misalignment is
    ///    visible.
    /// 2. **Exit** the high-error zone (error drops back below threshold).
    ///    This exit point — the first y going upward where the error is no
    ///    longer bad — is the actual sky/ground boundary (mountain peak).
    ///
    /// Why two phases?  The high-error band caused by Earth-rotation-induced
    /// misalignment is centred on the mountain peak, not the base.  The top
    /// of that band (phase-2 exit) is the most accurate estimate of the
    /// skyline.  Clouds higher in the sky also create error bands, but because
    /// we stop at the *first* exit from the first high-error zone, clouds
    /// encountered later (higher up) are ignored.
    ///
    /// The search is bounded below by `baseline` and above by
    /// `baseline - errorSearchRange`, so this pass can only move the horizon
    /// *upward* (more ground), never downward.
    ///
    /// **Wide-sample / narrow-apply**: error is averaged over
    /// `[x-sampleHalfWidth .. x+sampleHalfWidth]` horizontally (to capture
    /// more stars per sample) via per-row prefix sums, while the output is
    /// still written per column.
    ///
    /// If the error zone is entered but never exited, the column returns `nil`,
    /// falling back to the merged horizon (sustained high-error = Milky Way,
    /// aurora, airglow — not a narrow mountain-peak band).
    private func errorBoundaryPerColumn(
      in errorImage: PixelatedImage,
      baselineY: [Int?],
      sampleHalfWidth: Int
    ) -> [Int?] {
        let width     = errorImage.width
        let height    = errorImage.height
        let rowStride = errorImage.bytesPerRow
        // absDiffGrayscale always outputs a 1-channel image; bpp should be 1.
        let bpp       = max(1, errorImage.bytesPerPixel)
        let buf       = errorImage.mat.buffer(of: UInt8.self)
        let blurR     = errorBlurRadius

        // ------------------------------------------------------------------
        // Pre-compute horizontally-blurred error image in a single O(W·H) pass.
        //
        // hBlurred[y * width + x] = mean of errorImage[y][x-hw .. x+hw]
        //
        // Stars are sparse; sampling a wider horizontal strip captures far
        // more of them per profile point.  Per-row prefix sums make each
        // horizontal query O(1) regardless of sampleHalfWidth.
        // ------------------------------------------------------------------
        var hBlurred = [Float](repeating: 0.0, count: height * width)
        do {
            var psum = [Int](repeating: 0, count: width + 1)
            for y in 0..<height {
                psum[0] = 0
                for x in 0..<width {
                    psum[x + 1] = psum[x] + Int(buf[y * rowStride + x * bpp])
                }
                let base = y * width
                for x in 0..<width {
                    let xLo  = max(0, x - sampleHalfWidth)
                    let xHi  = min(width - 1, x + sampleHalfWidth)
                    let span = xHi - xLo + 1
                    let sum  = psum[xHi + 1] - psum[xLo]
                    hBlurred[base + x] = Float(sum) / Float(span)
                }
            }
        }

        var result = [Int?](repeating: nil, count: width)

        for x in 0..<width {
            let baseline   = baselineY[x] ?? height
            let searchTop  = max(blurR, baseline - errorSearchRange)
            guard searchTop + blurR < baseline else { continue }

            // Sky-baseline: mean of hBlurred values in the 40-row reference band
            // at the top of the search range (definite sky).
            let refBottom = min(searchTop + 40, baseline - 1)
            var skySum: Float = 0.0
            var skyCount = 0
            for y in searchTop...refBottom {
                skySum   += hBlurred[y * width + x]
                skyCount += 1
            }
            let skyBase = skyCount > 0 ? skySum / Float(skyCount) : 0.0

            // Ground error must clear a minimum absolute floor AND a
            // multiplicative factor above the sky baseline.
            let thresh = skyBase + max(6.0, max(6.0, skyBase) * Float(errorThresholdFactor))

            // 2-D smoothed error: horizontal pre-blurred + vertical average.
            func smoothedError(at y: Int) -> Float {
                var sum: Float = 0.0
                var count = 0
                for dy in -blurR...blurR {
                    let ys = y + dy
                    if ys >= 0 && ys < height {
                        sum   += hBlurred[ys * width + x]
                        count += 1
                    }
                }
                return count > 0 ? sum / Float(count) : 0.0
            }

            // Phase 1: scan UPWARD until we enter the high-error zone.
            var enteredHighError = false
            var entryY = searchTop
            for y in stride(from: baseline - 1, through: searchTop + blurR, by: -1) {
                if smoothedError(at: y) >= thresh {
                    enteredHighError = true
                    entryY = y
                    break
                }
            }

            guard enteredHighError else { continue }

            // Phase 2: continue upward from entryY to find where error drops
            // back below threshold (= top of the high-error band = mountain peak).
            for y in stride(from: entryY, through: searchTop + blurR, by: -1) {
                if smoothedError(at: y) < thresh {
                    result[x] = y
                    break
                }
            }

            // If we entered the zone but never exited, the error is SUSTAINED
            // all the way to the top of the search range.  This is the
            // signature of a broad sky feature (Milky Way, aurora, airglow,
            // city glow spanning a large area) — not a mountain peak, which
            // produces only a narrow high-error band that exits cleanly into
            // clear sky above.  Leave result[x] as nil so the merged-horizon
            // baseline is used unchanged for this column.
        }
        return result
    }

    // MARK: - Per-column first-dark-pixel scan (Pass 1 helper)

    private func perColumnFirstDark(in mask: PixelatedImage) -> [Int?] {
        let width     = mask.width
        let height    = mask.height
        let rowStride = mask.bytesPerRow
        let bpp       = max(1, mask.bytesPerPixel)
        let buf       = mask.mat.buffer(of: UInt8.self)

        var result = [Int?](repeating: nil, count: width)
        for x in 0..<width {
            for y in 0..<height {
                let offset = y * rowStride + x * bpp
                if buf[offset] < 128 {
                    result[x] = y
                    break
                }
            }
        }
        return result
    }

    // MARK: - Smoothing (sliding-window mean over valid values)

    private func smooth(_ values: [Int?], radius: Int) -> [Int?] {
        guard radius > 0 else { return values }
        let n = values.count
        var result = [Int?](repeating: nil, count: n)
        for i in 0..<n {
            let lo = max(0, i - radius)
            let hi = min(n - 1, i + radius)
            var sum = 0, count = 0
            for j in lo...hi {
                if let v = values[j] { sum += v; count += 1 }
            }
            if count > 0 { result[i] = sum / count }
        }
        return result
    }
}
