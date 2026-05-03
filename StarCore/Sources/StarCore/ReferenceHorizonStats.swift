import Foundation
import logging

// MARK: - IntensityHistogram

/// A normalized intensity histogram over the observed range [minIntensity, maxIntensity].
///
/// Buckets span from `minIntensity` to `maxIntensity` with uniform width.
/// Each bucket value is the fraction of pixels in that bucket (sum ≈ 1.0).
/// Lookups outside the observed range return 0.
public struct IntensityHistogram: Sendable {
    public let buckets: [Double]
    public let minIntensity: Double
    public let maxIntensity: Double

    public init(values: [Double], numBuckets: Int) {
        guard !values.isEmpty, numBuckets > 0 else {
            self.buckets = []
            self.minIntensity = 0
            self.maxIntensity = 0
            return
        }
        let minV = values.min()!
        let maxV = values.max()!
        self.minIntensity = minV
        self.maxIntensity = maxV

        var counts = [Int](repeating: 0, count: numBuckets)
        if maxV > minV {
            for v in values {
                let t = (v - minV) / (maxV - minV)
                let idx = min(numBuckets - 1, Int(t * Double(numBuckets)))
                counts[idx] += 1
            }
        } else {
            counts[0] = values.count
        }

        let total = Double(values.count)
        self.buckets = counts.map { Double($0) / total }
    }

    /// Returns the normalized bucket value (fraction of region pixels) for `intensity`.
    /// Returns 0 if `intensity` is outside [minIntensity, maxIntensity] or the histogram is empty.
    public subscript(intensity: Double) -> Double {
        guard !buckets.isEmpty else { return 0 }
        guard maxIntensity > minIntensity else {
            return abs(intensity - minIntensity) < 1e-9 ? 1.0 : 0.0
        }
        let t = (intensity - minIntensity) / (maxIntensity - minIntensity)
        guard t >= 0.0, t <= 1.0 else { return 0 }
        let idx = min(buckets.count - 1, Int(t * Double(buckets.count)))
        return buckets[idx]
    }
}

// MARK: - ReferenceHorizonFrameStats

/// Per-frame statistics derived from a user-defined reference horizon mask
/// and the corresponding original frame image.  Used to refine pixel-level
/// sky/ground classification on nearby frames in a moving video sequence.
public struct ReferenceHorizonFrameStats: Sendable {
    public let frameIndex: Int
    /// Per-channel normalized intensity histograms of sky pixels in the reference frame.
    /// Length equals the source image's `componentsPerPixel` (1 for grayscale, 3 for RGB).
    public let skyHistograms: [IntensityHistogram]
    /// Per-channel normalized intensity histograms of ground pixels in the reference frame.
    public let groundHistograms: [IntensityHistogram]
    /// Minimum horizon Y across all mask columns (highest position the horizon reaches in the image).
    public let minHorizonY: Int
    /// Maximum horizon Y across all mask columns (lowest position the horizon reaches in the image).
    public let maxHorizonY: Int
    /// Per-column horizon Y for the reference mask (nil where the column has no defined horizon).
    /// Used for per-column linear interpolation between bracketing reference frames.
    public let horizonYPerColumn: [Int?]
    /// Median normalised [0,1] brightness of sky pixels (kept for logging).
    public let medianSkyBrightness: Double
    /// Median normalised [0,1] brightness of ground pixels (kept for logging).
    public let medianGroundBrightness: Double
}

/// Module-level shared cache so stats for each reference frame are computed at most once.
public let referenceHorizonStatsCache = ReferenceHorizonStatsCache()

public actor ReferenceHorizonStatsCache {
    private var cache: [Int: ReferenceHorizonFrameStats] = [:]

    public func stats(for frameIndex: Int) -> ReferenceHorizonFrameStats? { cache[frameIndex] }
    public func set(_ stats: ReferenceHorizonFrameStats) { cache[stats.frameIndex] = stats }

    /// Up to `maxCount` cached entries nearest by frame distance to `target`.
    public func clearStats(for frameIndex: Int) { cache.removeValue(forKey: frameIndex) }

    /// Up to `maxCount` cached entries nearest by frame distance to `target`.
    public func nearestStats(to target: Int, maxCount: Int = 2) -> [ReferenceHorizonFrameStats] {
        Array(
            cache.values
                .sorted { abs($0.frameIndex - target) < abs($1.frameIndex - target) }
                .prefix(maxCount)
        )
    }
}

// MARK: - Stats computation

extension PixelatedImage {
    /// Compute sky/ground brightness statistics from `self` (the original source image)
    /// classified by `mask` (white=sky, black=ground, 8-bit grayscale).
    ///
    /// Samples every 4th pixel in both dimensions (1/16 density) for speed.
    /// Results are cached externally; this function just performs the computation.
    func computeReferenceHorizonStats(
      frameIndex: Int,
      mask: HorizonMask,
      numBuckets: Int = 256
    ) -> ReferenceHorizonFrameStats? {
        guard width == mask.image.width, height == mask.image.height else {
            Log.w("frame \(frameIndex) computeReferenceHorizonStats: size mismatch " +
                  "\(width)×\(height) vs mask \(mask.image.width)×\(mask.image.height)")
            return nil
        }
        guard case .eightBit(let maskBuf) = mask.image.imageData else {
            Log.w("frame \(frameIndex) computeReferenceHorizonStats: mask is not 8-bit")
            return nil
        }

        let horizonYPerColumn = HorizonScoring.extractHorizonYPerColumn(from: mask.image)
        let horizonYs = horizonYPerColumn.compactMap { $0 }
        guard !horizonYs.isEmpty else {
            Log.w("frame \(frameIndex) computeReferenceHorizonStats: no horizon columns in mask")
            return nil
        }
        let minHorizonY = horizonYs.min()!
        let maxHorizonY = horizonYs.max()!

        let maxVal = maxBrightnessValue
        let cpp = componentsPerPixel
        var skyByChannel:    [[Double]] = (0..<cpp).map { _ in [] }
        var groundByChannel: [[Double]] = (0..<cpp).map { _ in [] }
        for c in 0..<cpp {
            skyByChannel[c].reserveCapacity((width * minHorizonY) / 16)
            groundByChannel[c].reserveCapacity(max(1, (width * (height - maxHorizonY)) / 16))
        }
        var skyAvg:    [Double] = []
        var groundAvg: [Double] = []
        skyAvg.reserveCapacity((width * minHorizonY) / 16)
        groundAvg.reserveCapacity(max(1, (width * (height - maxHorizonY)) / 16))

        let sampleStride = 4
        var channelBuf = [Double](repeating: 0, count: cpp)
        for y in stride(from: 0, to: height, by: sampleStride) {
            for x in stride(from: 0, to: width, by: sampleStride) {
                let isSky = maskBuf[y * width + x] > 0
                fillNormalizedChannelValues(x: x, y: y, maxVal: maxVal, into: &channelBuf)
                var sum = 0.0
                if isSky {
                    for c in 0..<cpp { skyByChannel[c].append(channelBuf[c]); sum += channelBuf[c] }
                    skyAvg.append(sum / Double(cpp))
                } else {
                    for c in 0..<cpp { groundByChannel[c].append(channelBuf[c]); sum += channelBuf[c] }
                    groundAvg.append(sum / Double(cpp))
                }
            }
        }

        guard !skyAvg.isEmpty, !groundAvg.isEmpty else {
            Log.w("frame \(frameIndex) computeReferenceHorizonStats: all-sky or all-ground mask")
            return nil
        }

        let skyHistograms    = skyByChannel.map    { IntensityHistogram(values: $0, numBuckets: numBuckets) }
        let groundHistograms = groundByChannel.map { IntensityHistogram(values: $0, numBuckets: numBuckets) }

        let medSky    = sortedMedian(&skyAvg)
        let medGround = sortedMedian(&groundAvg)

        let stats = ReferenceHorizonFrameStats(
            frameIndex: frameIndex,
            skyHistograms: skyHistograms,
            groundHistograms: groundHistograms,
            minHorizonY: minHorizonY,
            maxHorizonY: maxHorizonY,
            horizonYPerColumn: horizonYPerColumn,
            medianSkyBrightness: medSky,
            medianGroundBrightness: medGround
        )
        let skyRanges    = skyHistograms.map    { "[\(String(format:"%.3f", $0.minIntensity)),\(String(format:"%.3f", $0.maxIntensity))]" }.joined(separator: ",")
        let groundRanges = groundHistograms.map { "[\(String(format:"%.3f", $0.minIntensity)),\(String(format:"%.3f", $0.maxIntensity))]" }.joined(separator: ",")
        Log.i("frame \(frameIndex) computeReferenceHorizonStats: channels=\(cpp) " +
              "skyMedian=\(String(format:"%.4f", medSky)) " +
              "groundMedian=\(String(format:"%.4f", medGround)) " +
              "skyChRanges=\(skyRanges) " +
              "groundChRanges=\(groundRanges) " +
              "horizonY=[\(minHorizonY),\(maxHorizonY)]")
        return stats
    }

    /// Average normalised [0,1] brightness of pixel (x, y) across all channels.
    func normalizedBrightness(x: Int, y: Int, maxVal: Double) -> Double {
        let base = (y * width + x) * componentsPerPixel
        var sum = 0.0
        switch imageData {
        case .eightBit(let buf):
            for c in 0..<componentsPerPixel { sum += Double(buf[base + c]) }
        case .sixteenBit(let buf):
            for c in 0..<componentsPerPixel { sum += Double(buf[base + c]) }
        case .thirtyTwoBit(let buf):
            for c in 0..<componentsPerPixel { sum += Double(max(0, buf[base + c])) }
        }
        return (sum / Double(componentsPerPixel)) / maxVal
    }

    /// Fill `out` with normalised [0,1] per-channel values for pixel (x, y).
    /// `out` must have length >= `componentsPerPixel`.
    func fillNormalizedChannelValues(x: Int, y: Int, maxVal: Double, into out: inout [Double]) {
        let base = (y * width + x) * componentsPerPixel
        switch imageData {
        case .eightBit(let buf):
            for c in 0..<componentsPerPixel { out[c] = Double(buf[base + c]) / maxVal }
        case .sixteenBit(let buf):
            for c in 0..<componentsPerPixel { out[c] = Double(buf[base + c]) / maxVal }
        case .thirtyTwoBit(let buf):
            for c in 0..<componentsPerPixel { out[c] = Double(max(0, buf[base + c])) / maxVal }
        }
    }

    /// The maximum pixel-component value for normalisation to [0, 1].
    var maxBrightnessValue: Double {
        switch imageData {
        case .eightBit:     return 255.0
        case .sixteenBit:   return 65535.0
        case .thirtyTwoBit: return Double(Int32.max)
        }
    }
}

// MARK: - Median helper

/// Sorts `values` in place and returns the median.
private func sortedMedian(_ values: inout [Double]) -> Double {
    values.sort()
    let n = values.count
    return n % 2 == 0
        ? (values[n / 2 - 1] + values[n / 2]) / 2.0
        : values[n / 2]
}
