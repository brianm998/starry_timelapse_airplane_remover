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

// MARK: - sRGB → CIE LAB conversion (D65)

@inline(__always)
private func srgbToLinear(_ v: Double) -> Double {
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
}

@inline(__always)
private func labF(_ t: Double) -> Double {
    let delta = 6.0 / 29.0
    let delta3 = delta * delta * delta
    return t > delta3 ? Foundation.cbrt(t) : t / (3.0 * delta * delta) + 4.0 / 29.0
}

/// Convert sRGB normalized [0, 1] (R, G, B) to CIE LAB (D65).
/// L ∈ [0, 100], a ≈ [-128, 127], b ≈ [-128, 127].
@inline(__always)
public func sRGBtoLAB(_ r: Double, _ g: Double, _ b: Double) -> (L: Double, a: Double, b: Double) {
    let R = srgbToLinear(r)
    let G = srgbToLinear(g)
    let B = srgbToLinear(b)
    // sRGB → XYZ (D65)
    let X = 0.4124564 * R + 0.3575761 * G + 0.1804375 * B
    let Y = 0.2126729 * R + 0.7151522 * G + 0.0721750 * B
    let Z = 0.0193339 * R + 0.1191920 * G + 0.9503041 * B
    // XYZ → LAB (D65 reference white).
    let fx = labF(X / 0.95047)
    let fy = labF(Y)
    let fz = labF(Z / 1.08883)
    return (L: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
}

// MARK: - 3D Gaussian (mean + precision + log|Σ|)

/// 3D Gaussian distribution of LAB colour samples, with precomputed precision matrix
/// (Σ⁻¹, symmetric upper triangle) and log|Σ| for fast Mahalanobis / log-likelihood
/// evaluation.  A small ridge is added to the covariance diagonal at construction
/// for numerical stability.
public struct GaussianStats3D: Sendable {
    public let mean0: Double, mean1: Double, mean2: Double
    /// Precision (Σ⁻¹) entries, symmetric.
    public let p00: Double, p01: Double, p02: Double
    public let p11: Double, p12: Double
    public let p22: Double
    /// log|Σ|, used in log-likelihood.
    public let logDet: Double

    public init?(samples: [(Double, Double, Double)], ridge: Double = 1e-3) {
        guard samples.count >= 4 else { return nil }
        let n = Double(samples.count)
        var s0 = 0.0, s1 = 0.0, s2 = 0.0
        for s in samples { s0 += s.0; s1 += s.1; s2 += s.2 }
        let m0 = s0 / n, m1 = s1 / n, m2 = s2 / n

        var c00 = 0.0, c01 = 0.0, c02 = 0.0, c11 = 0.0, c12 = 0.0, c22 = 0.0
        for s in samples {
            let d0 = s.0 - m0, d1 = s.1 - m1, d2 = s.2 - m2
            c00 += d0 * d0
            c01 += d0 * d1
            c02 += d0 * d2
            c11 += d1 * d1
            c12 += d1 * d2
            c22 += d2 * d2
        }
        let denom = max(1.0, n - 1.0)
        c00 = c00 / denom + ridge
        c01 = c01 / denom
        c02 = c02 / denom
        c11 = c11 / denom + ridge
        c12 = c12 / denom
        c22 = c22 / denom + ridge

        // det of symmetric 3x3
        let det = c00 * (c11 * c22 - c12 * c12)
                - c01 * (c01 * c22 - c12 * c02)
                + c02 * (c01 * c12 - c11 * c02)
        guard det > 1e-20 else { return nil }
        let inv = 1.0 / det

        self.mean0 = m0
        self.mean1 = m1
        self.mean2 = m2
        self.p00 =  (c11 * c22 - c12 * c12) * inv
        self.p01 = -(c01 * c22 - c12 * c02) * inv
        self.p02 =  (c01 * c12 - c11 * c02) * inv
        self.p11 =  (c00 * c22 - c02 * c02) * inv
        self.p12 = -(c00 * c12 - c01 * c02) * inv
        self.p22 =  (c00 * c11 - c01 * c01) * inv
        self.logDet = Foundation.log(det)
    }

    /// Mahalanobis squared distance from `(v0, v1, v2)` to the mean.
    @inline(__always)
    public func mahalanobisSq(_ v0: Double, _ v1: Double, _ v2: Double) -> Double {
        let d0 = v0 - mean0, d1 = v1 - mean1, d2 = v2 - mean2
        return p00 * d0 * d0 + p11 * d1 * d1 + p22 * d2 * d2
             + 2 * (p01 * d0 * d1 + p02 * d0 * d2 + p12 * d1 * d2)
    }

    /// Log of the 3D Gaussian density up to the constant `-0.5 * 3 * log(2π)`,
    /// which cancels when comparing two Gaussians.
    @inline(__always)
    public func logLikelihood(_ v0: Double, _ v1: Double, _ v2: Double) -> Double {
        return -0.5 * (logDet + mahalanobisSq(v0, v1, v2))
    }
}

// MARK: - ReferenceHorizonFrameStats

/// Per-frame statistics derived from a user-defined reference horizon mask
/// and the corresponding original frame image.  Used to refine pixel-level
/// sky/ground classification on nearby frames in a moving video sequence.
public struct ReferenceHorizonFrameStats: Sendable {
    public let frameIndex: Int
    /// 3D Gaussian fit to LAB samples of sky pixels in the reference frame.
    /// `nil` when the source image is not RGB or there are too few samples to fit.
    public let skyGaussian: GaussianStats3D?
    /// 3D Gaussian fit to LAB samples of ground pixels in the reference frame.
    public let groundGaussian: GaussianStats3D?
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
      numBuckets: Int = 256,
      neighborhoodSize: Int = 1
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
        var skyLab:    [(Double, Double, Double)] = []
        var groundLab: [(Double, Double, Double)] = []
        skyLab.reserveCapacity((width * minHorizonY) / 16)
        groundLab.reserveCapacity(max(1, (width * (height - maxHorizonY)) / 16))
        var skyAvg:    [Double] = []
        var groundAvg: [Double] = []
        skyAvg.reserveCapacity(skyLab.capacity)
        groundAvg.reserveCapacity(groundLab.capacity)

        let sampleStride = 4
        let halfSize = neighborhoodSize / 2
        for y in stride(from: 0, to: height, by: sampleStride) {
            for x in stride(from: 0, to: width, by: sampleStride) {
                let isSky = maskBuf[y * width + x] > 0
                let (r, g, bch) = neighborhoodAveragedRGB(
                  x: x, y: y, halfSize: halfSize, maxVal: maxVal,
                  maskBuf: maskBuf, isSky: isSky
                )
                let lab = sRGBtoLAB(r, g, bch)
                let avg = (r + g + bch) / 3.0
                if isSky {
                    skyLab.append((lab.L, lab.a, lab.b))
                    skyAvg.append(avg)
                } else {
                    groundLab.append((lab.L, lab.a, lab.b))
                    groundAvg.append(avg)
                }
            }
        }

        guard !skyAvg.isEmpty, !groundAvg.isEmpty else {
            Log.w("frame \(frameIndex) computeReferenceHorizonStats: all-sky or all-ground mask")
            return nil
        }

        let skyG    = GaussianStats3D(samples: skyLab)
        let groundG = GaussianStats3D(samples: groundLab)

        let medSky    = sortedMedian(&skyAvg)
        let medGround = sortedMedian(&groundAvg)

        let stats = ReferenceHorizonFrameStats(
            frameIndex: frameIndex,
            skyGaussian: skyG,
            groundGaussian: groundG,
            minHorizonY: minHorizonY,
            maxHorizonY: maxHorizonY,
            horizonYPerColumn: horizonYPerColumn,
            medianSkyBrightness: medSky,
            medianGroundBrightness: medGround
        )
        let skyMeans = skyG.map {
            "(L=\(String(format:"%.1f", $0.mean0)),a=\(String(format:"%.1f", $0.mean1)),b=\(String(format:"%.1f", $0.mean2)))"
        } ?? "nil"
        let groundMeans = groundG.map {
            "(L=\(String(format:"%.1f", $0.mean0)),a=\(String(format:"%.1f", $0.mean1)),b=\(String(format:"%.1f", $0.mean2)))"
        } ?? "nil"
        Log.i("frame \(frameIndex) computeReferenceHorizonStats: " +
              "skyMedian=\(String(format:"%.4f", medSky)) " +
              "groundMedian=\(String(format:"%.4f", medGround)) " +
              "skyLAB=\(skyMeans) " +
              "groundLAB=\(groundMeans) " +
              "horizonY=[\(minHorizonY),\(maxHorizonY)]")
        return stats
    }

    /// Return the neighbourhood-averaged normalised RGB for pixel (x, y) over a
    /// `(2*halfSize+1)²` window.  When `maskBuf` is non-nil only neighbours whose
    /// mask value (`> 0` means sky) matches `isSky` are included; the centre pixel
    /// always qualifies since the caller already confirmed its classification.
    func neighborhoodAveragedRGB(
      x: Int, y: Int, halfSize: Int, maxVal: Double,
      maskBuf: UnsafeBufferPointer<UInt8>? = nil,
      isSky: Bool = false
    ) -> (r: Double, g: Double, b: Double) {
        guard halfSize > 0 else {
            var buf = [Double](repeating: 0, count: max(3, componentsPerPixel))
            fillNormalizedChannelValues(x: x, y: y, maxVal: maxVal, into: &buf)
            let r = buf[0], g = componentsPerPixel >= 3 ? buf[1] : buf[0], b = componentsPerPixel >= 3 ? buf[2] : buf[0]
            return (r, g, b)
        }
        let cpp = componentsPerPixel
        let xMin = max(0, x - halfSize), xMax = min(width - 1, x + halfSize)
        let yMin = max(0, y - halfSize), yMax = min(height - 1, y + halfSize)
        var sumR = 0.0, sumG = 0.0, sumB = 0.0, count = 0.0
        switch imageData {
        case .eightBit(let imgBuf):
            for ny in yMin...yMax {
                for nx in xMin...xMax {
                    if let mb = maskBuf, (mb[ny * width + nx] > 0) != isSky { continue }
                    let base = (ny * width + nx) * cpp
                    if cpp >= 3 {
                        sumR += Double(imgBuf[base]) / maxVal
                        sumG += Double(imgBuf[base + 1]) / maxVal
                        sumB += Double(imgBuf[base + 2]) / maxVal
                    } else {
                        let v = Double(imgBuf[base]) / maxVal
                        sumR += v; sumG += v; sumB += v
                    }
                    count += 1
                }
            }
        case .sixteenBit(let imgBuf):
            for ny in yMin...yMax {
                for nx in xMin...xMax {
                    if let mb = maskBuf, (mb[ny * width + nx] > 0) != isSky { continue }
                    let base = (ny * width + nx) * cpp
                    if cpp >= 3 {
                        sumR += Double(imgBuf[base]) / maxVal
                        sumG += Double(imgBuf[base + 1]) / maxVal
                        sumB += Double(imgBuf[base + 2]) / maxVal
                    } else {
                        let v = Double(imgBuf[base]) / maxVal
                        sumR += v; sumG += v; sumB += v
                    }
                    count += 1
                }
            }
        case .thirtyTwoBit(let imgBuf):
            for ny in yMin...yMax {
                for nx in xMin...xMax {
                    if let mb = maskBuf, (mb[ny * width + nx] > 0) != isSky { continue }
                    let base = (ny * width + nx) * cpp
                    if cpp >= 3 {
                        sumR += Double(max(0, imgBuf[base])) / maxVal
                        sumG += Double(max(0, imgBuf[base + 1])) / maxVal
                        sumB += Double(max(0, imgBuf[base + 2])) / maxVal
                    } else {
                        let v = Double(max(0, imgBuf[base])) / maxVal
                        sumR += v; sumG += v; sumB += v
                    }
                    count += 1
                }
            }
        }
        guard count > 0 else {
            var buf = [Double](repeating: 0, count: max(3, cpp))
            fillNormalizedChannelValues(x: x, y: y, maxVal: maxVal, into: &buf)
            let r = buf[0], g = cpp >= 3 ? buf[1] : buf[0], b = cpp >= 3 ? buf[2] : buf[0]
            return (r, g, b)
        }
        return (sumR / count, sumG / count, sumB / count)
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
