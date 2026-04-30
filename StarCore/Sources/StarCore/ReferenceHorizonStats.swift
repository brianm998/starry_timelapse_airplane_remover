import Foundation
import logging

/// Per-frame statistics derived from a user-defined reference horizon mask
/// and the corresponding original frame image.  Used to refine pixel-level
/// sky/ground classification on nearby frames in a moving video sequence.
public struct ReferenceHorizonFrameStats: Sendable {
    public let frameIndex: Int
    /// Median normalised [0,1] brightness of sky pixels in the reference frame.
    public let medianSkyBrightness: Double
    /// Median normalised [0,1] brightness of ground pixels in the reference frame.
    public let medianGroundBrightness: Double
    /// Minimum horizon Y across all mask columns (highest position the horizon reaches in the image).
    public let minHorizonY: Int
    /// Maximum horizon Y across all mask columns (lowest position the horizon reaches in the image).
    public let maxHorizonY: Int
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
      mask: HorizonMask
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

        let horizonYs = HorizonScoring.extractHorizonYPerColumn(from: mask.image).compactMap { $0 }
        guard !horizonYs.isEmpty else {
            Log.w("frame \(frameIndex) computeReferenceHorizonStats: no horizon columns in mask")
            return nil
        }
        let minHorizonY = horizonYs.min()!
        let maxHorizonY = horizonYs.max()!

        let maxVal = maxBrightnessValue
        var skyValues:    [Double] = []
        var groundValues: [Double] = []
        skyValues.reserveCapacity((width * minHorizonY) / 16)
        groundValues.reserveCapacity(max(1, (width * (height - maxHorizonY)) / 16))

        let sampleStride = 4
        for y in stride(from: 0, to: height, by: sampleStride) {
            for x in stride(from: 0, to: width, by: sampleStride) {
                let isSky = maskBuf[y * width + x] > 0
                let b = normalizedBrightness(x: x, y: y, maxVal: maxVal)
                if isSky { skyValues.append(b) } else { groundValues.append(b) }
            }
        }

        guard !skyValues.isEmpty, !groundValues.isEmpty else {
            Log.w("frame \(frameIndex) computeReferenceHorizonStats: all-sky or all-ground mask")
            return nil
        }

        let stats = ReferenceHorizonFrameStats(
            frameIndex: frameIndex,
            medianSkyBrightness: sortedMedian(&skyValues),
            medianGroundBrightness: sortedMedian(&groundValues),
            minHorizonY: minHorizonY,
            maxHorizonY: maxHorizonY
        )
        Log.i("frame \(frameIndex) computeReferenceHorizonStats: " +
              "skyMedian=\(String(format:"%.4f", stats.medianSkyBrightness)) " +
              "groundMedian=\(String(format:"%.4f", stats.medianGroundBrightness)) " +
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
