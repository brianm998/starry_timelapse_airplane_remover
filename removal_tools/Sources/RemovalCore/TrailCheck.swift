import Foundation

public struct StretchResult: Codable, Sendable {
    public var startArc: Double
    public var endArc: Double
    public var inputContrast: Double
    public var outputContrast: Double
    /// output / input contrast; nil when the stretch is unmeasurable.
    public var ratio: Double?
    public var measurable: Bool
}

public struct TrailMeasurement: Codable, Sendable {
    public var stretches: [StretchResult]
    public var length: Double
    public var worstRatio: Double?
    public var bestRatio: Double?
    /// Fraction of the length whose ratio is <= 0.5 (i.e. mostly gone).
    public var fractionRemoved: Double
    public var measurableFraction: Double
}

public enum TrailCheck {
    public static let stretchLength = 50.0
    /// A stretch needs input contrast above this many sigma of its own background to be measurable.
    public static let minSigma: Float = 5
    public static let backgroundGap = 8.0
    public static let backgroundOuter = 26.0

    /// Per-1px-lateral-bin medians of `plane` at distance 0..<ceil(width/2) from `poly`, the median
    /// of the two background bands, and the MAD sigma of that background. Binning by distance (not
    /// one wide median) keeps a thin faint streak from being averaged away by a wide band, and
    /// tolerates a hand-clicked polyline that is a few pixels off the real streak.
    static func lateralProfile(_ plane: Plane, poly: [Point], width: Double)
        -> (bins: [Float], counts: [Int], background: Float, sigma: Float)?
    {
        let half = width / 2
        let outer = half + backgroundOuter
        let b = Geometry.bounds(of: poly, margin: outer, width: plane.width, height: plane.height)
        if b.x1 < b.x0 || b.y1 < b.y0 { return nil }
        let nBins = max(1, Int(half.rounded(.up)))
        var on = [[Float]](repeating: [], count: nBins)
        var bg: [Float] = []
        let bgInner = half + backgroundGap
        for y in b.y0...b.y1 {
            for x in b.x0...b.x1 {
                let d = Geometry.distance(from: Point(x: Double(x), y: Double(y)), toPolyline: poly)
                if d < half { on[min(nBins - 1, Int(d))].append(plane[x, y]) }
                else if d >= bgInner && d <= outer { bg.append(plane[x, y]) }
            }
        }
        if bg.isEmpty || on.contains(where: { $0.isEmpty }) { return nil }
        return (on.map(Stats.median), on.map(\.count), Stats.median(bg), Stats.madSigma(bg))
    }

    /// Measures an object in `input` and `output` (brightness planes of equal size).
    public static func measure(input: Plane, output: Plane, object: LabelObject) -> TrailMeasurement {
        measure(input: input, output: output, poly: object.polyline, width: object.width)
    }

    public static func measure(input: Plane, output: Plane, poly: [Point], width: Double) -> TrailMeasurement {
        let total = Geometry.length(poly)
        var stretches: [StretchResult] = []
        var s0 = 0.0
        while s0 < total {
            let s1 = min(total, s0 + stretchLength)
            // a short tail merges into the previous stretch's neighbour rather than being measured alone
            if total - s1 < stretchLength / 2 && s1 < total { stretches.append(stretch(input, output, poly, width, s0, total)); break }
            stretches.append(stretch(input, output, poly, width, s0, s1))
            s0 = s1
        }
        let measurable = stretches.filter(\.measurable)
        let measurableLen = measurable.reduce(0.0) { $0 + ($1.endArc - $1.startArc) }
        let removedLen = measurable.filter { ($0.ratio ?? 1) <= 0.5 }.reduce(0.0) { $0 + ($1.endArc - $1.startArc) }
        let ratios = measurable.compactMap(\.ratio)
        return TrailMeasurement(
            stretches: stretches, length: total,
            worstRatio: ratios.max(), bestRatio: ratios.min(),
            fractionRemoved: measurableLen > 0 ? removedLen / measurableLen : 0,
            measurableFraction: total > 0 ? measurableLen / total : 0)
    }

    private static func stretch(_ input: Plane, _ output: Plane, _ poly: [Point], _ width: Double,
                                _ s0: Double, _ s1: Double) -> StretchResult {
        let sub = Geometry.subPolyline(poly, from: s0, to: s1)
        guard sub.count >= 2, let i = lateralProfile(input, poly: sub, width: width),
              let o = lateralProfile(output, poly: sub, width: width) else {
            return StretchResult(startArc: s0, endArc: s1, inputContrast: .nan, outputContrast: .nan,
                                 ratio: nil, measurable: false)
        }
        // the streak's bin is chosen on the input and the output is read at the same bin, so the
        // output is not credited with the maximum of its own noise
        let k = i.bins.indices.max { i.bins[$0] < i.bins[$1] }!
        let ic = i.bins[k] - i.background, oc = o.bins[k] - o.background
        // 5 sigma of a median over this bin's pixels, not of a single pixel
        let sigmaBin = 1.2533 * max(i.sigma, 1e-9) / Float(max(1, i.counts[k])).squareRoot()
        let ok = ic > minSigma * sigmaBin
        return StretchResult(startArc: s0, endArc: s1, inputContrast: Double(ic), outputContrast: Double(oc),
                             ratio: ok ? Double(oc / ic) : nil, measurable: ok)
    }
}
