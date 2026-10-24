import Foundation

public struct StarPeak: Sendable {
    public var x: Int
    public var y: Int
    public var inputFlux: Double
    public var outputFlux: Double
    public var ratio: Double { inputFlux > 0 ? outputFlux / inputFlux : .nan }
}

public struct StarMeasurement: Codable, Sendable {
    public var peaks: Int
    public var medianRatio: Double
    public var p5: Double
    public var p95: Double
    public var fractionBelowHalf: Double
}

public enum StarCheck {
    public static let blockSize = 32
    public static let peakSigma: Float = 10
    public static let apertureRadius = 3        // 7x7
    public static let backgroundRadius = 8      // 17x17

    /// Block-median background, 32 px blocks, held constant within each block.
    public static func blockMedianBackground(_ p: Plane) -> Plane {
        var bg = Plane(width: p.width, height: p.height)
        var by = 0
        while by < p.height {
            var bx = 0
            let h = min(blockSize, p.height - by)
            while bx < p.width {
                let w = min(blockSize, p.width - bx)
                var vals: [Float] = []; vals.reserveCapacity(w * h)
                for y in by..<(by + h) { for x in bx..<(bx + w) { vals.append(p[x, y]) } }
                let m = Stats.median(vals)
                for y in by..<(by + h) { for x in bx..<(bx + w) { bg[x, y] = m } }
                bx += blockSize
            }
            by += blockSize
        }
        return bg
    }

    /// Local maxima more than 10σ above the block-median background, strictly greater than every
    /// other pixel in their 7x7 window (ties go to the first in raster order).
    public static func findPeaks(in p: Plane) -> [(x: Int, y: Int)] {
        let resid = p.minus(blockMedianBackground(p))
        let sigma = Stats.madSigma(resid.data)
        guard sigma > 0, sigma.isFinite else { return [] }
        let thr = peakSigma * sigma
        let r = apertureRadius
        var out: [(Int, Int)] = []
        let m = backgroundRadius + 1
        guard p.width > 2 * m, p.height > 2 * m else { return [] }
        for y in m..<(p.height - m) {
            for x in m..<(p.width - m) {
                let v = resid[x, y]
                if v <= thr { continue }
                var isMax = true
                scan: for dy in -r...r {
                    for dx in -r...r where dx != 0 || dy != 0 {
                        let o = resid[x + dx, y + dy]
                        // earlier in raster order wins ties
                        if o > v || (o == v && (dy < 0 || (dy == 0 && dx < 0))) { isMax = false; break scan }
                    }
                }
                if isMax { out.append((x, y)) }
            }
        }
        return out
    }

    /// 7x7 sum minus 49 × the median of the 17x17 box around it.
    public static func flux(_ p: Plane, x: Int, y: Int) -> Double {
        var sum: Float = 0
        for dy in -apertureRadius...apertureRadius { for dx in -apertureRadius...apertureRadius { sum += p[x + dx, y + dy] } }
        var box: [Float] = []; box.reserveCapacity(17 * 17)
        for dy in -backgroundRadius...backgroundRadius { for dx in -backgroundRadius...backgroundRadius { box.append(p[x + dx, y + dy]) } }
        let n = Float((2 * apertureRadius + 1) * (2 * apertureRadius + 1))
        return Double(sum - n * Stats.median(box))
    }

    /// Peaks are found in the input; `include` filters them (sky polygon, distance from objects).
    public static func measure(input: Plane, output: Plane, include: (Int, Int) -> Bool = { _, _ in true })
        -> (StarMeasurement, [StarPeak])
    {
        var peaks: [StarPeak] = []
        for (x, y) in findPeaks(in: input) where include(x, y) {
            peaks.append(StarPeak(x: x, y: y, inputFlux: flux(input, x: x, y: y), outputFlux: flux(output, x: x, y: y)))
        }
        let ratios = peaks.map(\.ratio).filter { $0.isFinite }.sorted()
        func pct(_ q: Double) -> Double {
            Double(Stats.percentile(ratios.map { Float($0) }, q))
        }
        let below = ratios.isEmpty ? 0 : Double(ratios.filter { $0 < 0.5 }.count) / Double(ratios.count)
        return (StarMeasurement(peaks: peaks.count, medianRatio: pct(0.5), p5: pct(0.05), p95: pct(0.95),
                                fractionBelowHalf: below), peaks)
    }
}
