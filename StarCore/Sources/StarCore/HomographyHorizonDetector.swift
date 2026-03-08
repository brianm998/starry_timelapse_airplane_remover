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
///
/// ## Two-stage API
///
/// For parameter tuning the work is split into two stages so that the
/// expensive I/O (loading and warping images) is not repeated for each
/// candidate parameter set:
///
/// 1. `prepare(...)` — loads and warps all images, precomputes the
///    horizontally-blurred error arrays.  Returns a `PreparedData` value.
/// 2. `detectFromPrepared(_:)` — runs the fast per-column boundary scan
///    using the *current* parameter values stored in the detector.  Can be
///    called repeatedly with different parameter configurations.
///
/// `detect(...)` is a convenience wrapper that calls both stages.
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
    ///
    /// This value is captured at `prepare()` time and is not changed during
    /// coordinate-descent tuning.
    public var errorSampleHalfWidth: Int = 50

    public init() {}

    // MARK: - Apply persisted parameters

    /// Copy all algorithm parameters from a `HorizonTunedParameters` value.
    public mutating func apply(_ params: HorizonTunedParameters) {
        smoothingRadius       = params.smoothingRadius
        errorSearchRange      = params.errorSearchRange
        errorBlurRadius       = params.errorBlurRadius
        errorThresholdFactor  = params.errorThresholdFactor
        errorSampleHalfWidth  = params.errorSampleHalfWidth
    }

    // MARK: - Prepared data (result of expensive I/O pass)

    /// Cached result of `prepare(...)`.
    ///
    /// Stores everything that does not depend on the tunable parameters so
    /// that `detectFromPrepared(_:)` can be called repeatedly with different
    /// configurations without re-loading or re-warping any images.
    public struct PreparedData: Sendable {
        /// Width of the current frame in pixels.
        public let currentWidth: Int
        /// Height of the current frame in pixels.
        public let currentHeight: Int
        /// Per-column minimum horizon Y from Pass 1 **before** smoothing.
        /// Smoothing radius is applied inside `detectFromPrepared`, so the
        /// raw values are stored here to allow different radii to be tested.
        public let pass1RawY: [Int?]
        /// Per-neighbour horizontally-blurred error arrays for Pass 2.
        ///
        /// `neighborHBlurred[i]` is a `[Float]` of length
        /// `currentHeight * currentWidth`, where
        /// `hBlurred[y * currentWidth + x]` is the mean error in row y over
        /// the column window `[x-sampleHalfWidth .. x+sampleHalfWidth]`.
        ///
        /// Computed with `sampleHalfWidth` that was passed to `prepare()`.
        public let neighborHBlurred: [[Float]]
        /// The `errorSampleHalfWidth` used to build `neighborHBlurred`.
        public let sampleHalfWidth: Int
    }

    // MARK: - Public entry points

    /// Convenience: calls `prepare` then `detectFromPrepared`.
    ///
    /// Use this when you only need a single result.  When tuning, call the
    /// two stages separately.
    public func detect(
      currentWidth: Int,
      currentHeight: Int,
      neighborHorizonFilenames: [String],
      neighborOriginalFilenames: [String],
      neighborHomographies: [[Double]],
      currentImage: PixelatedImage? = nil
    ) -> HorizonMask? {
        let data = prepare(
          currentWidth:              currentWidth,
          currentHeight:             currentHeight,
          neighborHorizonFilenames:  neighborHorizonFilenames,
          neighborOriginalFilenames: neighborOriginalFilenames,
          neighborHomographies:      neighborHomographies,
          currentImage:              currentImage
        )
        return detectFromPrepared(data)
    }

    /// **Stage 1** — load and warp all images; precompute blurred error arrays.
    ///
    /// This is the expensive step (disk I/O + homography warps + diff).
    /// The returned `PreparedData` is parameter-independent and can be reused.
    public func prepare(
      currentWidth: Int,
      currentHeight: Int,
      neighborHorizonFilenames: [String],
      neighborOriginalFilenames: [String],
      neighborHomographies: [[Double]],
      currentImage: PixelatedImage? = nil
    ) -> PreparedData {

        // ------------------------------------------------------------------
        // Pass 1: warp each neighbour's horizon mask, collect per-column Y.
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

        // Per-column minimum (topmost horizon) across all warped masks.
        let pass1RawY: [Int?]
        if perMaskColumnY.isEmpty {
            Log.w("HomographyHorizonDetector: no valid warped masks for Pass 1")
            pass1RawY = [Int?](repeating: nil, count: currentWidth)
        } else {
            Log.d("HomographyHorizonDetector: Pass 1 – \(perMaskColumnY.count) warped masks, MIN aggregation")
            pass1RawY = (0..<currentWidth).map { x in
                let ys = perMaskColumnY.compactMap { col -> Int? in
                    guard x < col.count else { return nil }
                    return col[x]
                }.sorted()
                guard !ys.isEmpty else { return nil }
                return ys[0]    // minimum = topmost horizon = most conservative
            }
        }

        // ------------------------------------------------------------------
        // Pass 2: warp neighbour originals, diff, precompute hBlurred.
        // ------------------------------------------------------------------
        var neighborHBlurred: [[Float]] = []

        if let currentImage = currentImage, !neighborOriginalFilenames.isEmpty {
            Log.d("HomographyHorizonDetector: Pass 2 – preparing \(neighborOriginalFilenames.count) neighbours")
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
                let hBlurred = computeHBlurred(diff: diff, sampleHalfWidth: errorSampleHalfWidth)
                neighborHBlurred.append(hBlurred)
            }
        }

        return PreparedData(
          currentWidth:     currentWidth,
          currentHeight:    currentHeight,
          pass1RawY:        pass1RawY,
          neighborHBlurred: neighborHBlurred,
          sampleHalfWidth:  errorSampleHalfWidth
        )
    }

    /// **Stage 2** — run the fast per-column boundary scan using the current
    /// parameter values stored in the detector.
    ///
    /// This is the cheap step: no disk I/O, only in-memory array operations.
    /// Call it repeatedly with different `apply(_:)` configurations to tune.
    public func detectFromPrepared(_ data: PreparedData) -> HorizonMask? {
        let currentWidth  = data.currentWidth
        let currentHeight = data.currentHeight

        // ------------------------------------------------------------------
        // Pass 1: apply smoothing radius to the stored raw per-column min.
        // ------------------------------------------------------------------
        let maskY: [Int?]
        if data.pass1RawY.allSatisfy({ $0 == nil }) {
            Log.w("HomographyHorizonDetector: Pass 1 produced all-nil — no warped mask data")
            maskY = [Int?](repeating: nil, count: currentWidth)
        } else {
            maskY = smooth(data.pass1RawY, radius: smoothingRadius)
        }

        // ------------------------------------------------------------------
        // Pass 2: run boundary detection on each pre-blurred error array.
        // ------------------------------------------------------------------
        var errorY: [Int?]
        if !data.neighborHBlurred.isEmpty {
            var perNeighborBoundaryY: [[Int?]] = []
            for hBlurred in data.neighborHBlurred {
                let boundaryY = errorBoundaryPerColumnFromHBlurred(
                  hBlurred:  hBlurred,
                  height:    currentHeight,
                  width:     currentWidth,
                  baselineY: maskY
                )
                perNeighborBoundaryY.append(boundaryY)
            }
            // Per-column minimum: topmost boundary across all neighbours.
            let rawY: [Int?] = (0..<currentWidth).map { x in
                let ys = perNeighborBoundaryY.compactMap { col -> Int? in
                    guard x < col.count else { return nil }
                    return col[x]
                }.sorted()
                guard !ys.isEmpty else { return nil }
                return ys[0]
            }
            errorY = smooth(rawY, radius: smoothingRadius)
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

    // MARK: - Static scoring helpers

    /// Extract the per-column horizon Y from a binary horizon mask image.
    ///
    /// Returns the Y coordinate of the first dark (ground) pixel in each
    /// column, scanning from the top.  `nil` for columns that are all-sky.
    public static func horizonYPerColumn(in mask: HorizonMask) -> [Int?] {
        HorizonScoring.extractHorizonYPerColumn(from: mask.image)
    }

    /// Compute the mean absolute Y error between an algorithm result and a
    /// reference mask.  Only columns where *both* arrays have a non-nil value
    /// contribute to the mean.
    ///
    /// Returns `Double.infinity` if no columns can be compared.
    public static func score(algorithmY: [Int?], referenceY: [Int?]) -> Double {
        let n = min(algorithmY.count, referenceY.count)
        var totalError: Double = 0.0
        var count = 0
        for x in 0..<n {
            guard let a = algorithmY[x], let r = referenceY[x] else { continue }
            totalError += Double(abs(a - r))
            count += 1
        }
        guard count > 0 else { return Double.infinity }
        return totalError / Double(count)
    }

    // MARK: - Private helpers

    /// Build the horizontally-blurred error array for a diff image using
    /// per-row prefix sums.
    ///
    /// `result[y * width + x]` = mean of `diff[y][x-hw .. x+hw]`, O(1) per
    /// cell after a single O(W·H) prefix-sum pass.
    private func computeHBlurred(diff: PixelatedImage, sampleHalfWidth: Int) -> [Float] {
        let width     = diff.width
        let height    = diff.height
        let rowStride = diff.bytesPerRow
        let bpp       = max(1, diff.bytesPerPixel)
        let buf       = diff.mat.buffer(of: UInt8.self)

        var hBlurred = [Float](repeating: 0.0, count: height * width)
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
        return hBlurred
    }

    /// For each column, run the two-phase upward scan against a pre-blurred
    /// error array to find the sky/ground boundary.
    ///
    /// See the type-level documentation for the two-phase algorithm.
    private func errorBoundaryPerColumnFromHBlurred(
      hBlurred: [Float],
      height: Int,
      width: Int,
      baselineY: [Int?]
    ) -> [Int?] {
        let blurR = errorBlurRadius
        var result = [Int?](repeating: nil, count: width)

        for x in 0..<width {
            let baseline   = baselineY[x] ?? height
            let searchTop  = max(blurR, baseline - errorSearchRange)
            guard searchTop + blurR < baseline else { continue }

            // Sky-baseline: mean of hBlurred values in the 40-row reference
            // band at the top of the search range (definite sky).
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

            // If we entered the zone but never exited, leave result[x] = nil
            // (Milky Way / aurora / airglow fallback — not a mountain peak).
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
