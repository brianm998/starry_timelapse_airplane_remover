import Foundation

/// Deterministic generator state (SplitMix64), so a spec + seed always builds the same dataset.
public struct SeededRNG: Sendable {
    var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    public mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * Double(nextUInt64() >> 11) / Double(1 << 53)
    }
    public mutating func pick<T>(_ a: [T]) -> T { a[Int(nextUInt64() % UInt64(a.count))] }
}

public struct InjectionSpec: Codable, Sendable {
    public var seed: UInt64
    /// Peak amplitude of each satellite, in multiples of the local background sigma.
    public var satelliteSNRs: [Double]
    public var satellitesPerSNR: Int
    public var satelliteFWHM: [Double]        // [min, max]
    /// Fraction of satellites that continue collinearly into the next frame after a small gap.
    public var satelliteContinueFraction: Double
    public var airplanes: Int
    public var airplaneSNR: Double
    public var meteors: Int
    public var meteorSNR: Double
    public init(seed: UInt64 = 1, satelliteSNRs: [Double] = [3, 5, 10, 30, 100], satellitesPerSNR: Int = 2,
                satelliteFWHM: [Double] = [1.5, 3], satelliteContinueFraction: Double = 0.4,
                airplanes: Int = 4, airplaneSNR: Double = 40, meteors: Int = 2, meteorSNR: Double = 30) {
        self.seed = seed; self.satelliteSNRs = satelliteSNRs; self.satellitesPerSNR = satellitesPerSNR
        self.satelliteFWHM = satelliteFWHM; self.satelliteContinueFraction = satelliteContinueFraction
        self.airplanes = airplanes; self.airplaneSNR = airplaneSNR; self.meteors = meteors; self.meteorSNR = meteorSNR
    }
}

/// What was drawn, so the labels and the measured contrast come from the same numbers.
public struct InjectedObject: Codable, Sendable {
    public var frame: Int
    public var label: LabelObject
    public var snr: Double
    public init(frame: Int, label: LabelObject, snr: Double) { self.frame = frame; self.label = label; self.snr = snr }
}

public enum TrailInjection {
    static let tints: [[Float]] = [[0.35, 0.35, 1.0], [0.4, 1.0, 0.4], [1, 1, 1]]   // BGR order: red, green, white

    /// Adds `amp * profile(distance)` (per-channel `tint`) along a polyline, clamping at 1.0.
    static func draw(_ r: inout Raster, poly: [Point], sigma: Double, amp: Float, tint: [Float],
                     taper: Bool = false, dots: Double? = nil) {
        let reach = sigma * 4 + 1
        let total = Geometry.length(poly)
        let b = Geometry.bounds(of: poly, margin: reach, width: r.width, height: r.height)
        if b.x1 < b.x0 || b.y1 < b.y0 { return }
        for y in b.y0...b.y1 { for x in b.x0...b.x1 {
            let p = Point(x: Double(x), y: Double(y))
            let d = Geometry.distance(from: p, toPolyline: poly)
            if d > reach { continue }
            var a = Float(exp(-d * d / (2 * sigma * sigma))) * amp
            if taper || dots != nil {
                // arc position of the nearest point, for the meteor taper and the strobe dots
                let s = arcPosition(of: p, on: poly)
                if taper { a *= Float(0.25 + 0.75 * (s / max(total, 1))) }
                if let spacing = dots, Int((s / spacing).rounded(.down)) % 1 == 0 {
                    // strobe: bright blobs every `spacing` px, 3x the line amplitude
                    let phase = s.truncatingRemainder(dividingBy: spacing)
                    let near = min(phase, spacing - phase)
                    if near < sigma * 2 { a += Float(exp(-near * near / (2 * sigma * sigma))) * amp * 2 }
                }
            }
            for c in 0..<r.channels {
                let i = (y * r.width + x) * r.channels + c
                r.data[i] = min(1, r.data[i] + a * tint[min(c, tint.count - 1)])
            }
        } }
    }

    static func arcPosition(of p: Point, on poly: [Point]) -> Double {
        var best = (d: Double.infinity, s: 0.0)
        var acc = 0.0
        for i in 1..<poly.count {
            let a = poly[i - 1], bb = poly[i]
            let dx = bb.x - a.x, dy = bb.y - a.y, len = hypot(dx, dy)
            let t = len == 0 ? 0 : min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (len * len)))
            let d = Geometry.distance(from: p, toSegment: a, bb)
            if d < best.d { best = (d, acc + t * len) }
            acc += len
        }
        return best.s
    }

    /// Plans every object: which frame, where, how bright. Pure and seeded.
    public static func plan(spec: InjectionSpec, frames: Int, width: Int, height: Int,
                            skyTop: Double = 0, skyBottom: Double? = nil) -> [PlannedObject] {
        var rng = SeededRNG(seed: spec.seed)
        let bottom = skyBottom ?? Double(height)
        var out: [PlannedObject] = []
        func randomLine(minLen: Double, maxLen: Double) -> (Point, Point) {
            let len = rng.uniform(minLen, maxLen)
            let ang = rng.uniform(0, .pi)
            let cx = rng.uniform(len / 2 * abs(cos(ang)) , Double(width) - len / 2 * abs(cos(ang)) )
            let cy = rng.uniform(skyTop + len / 2 * abs(sin(ang)), bottom - len / 2 * abs(sin(ang)))
            return (Point(x: cx - cos(ang) * len / 2, y: cy - sin(ang) * len / 2),
                    Point(x: cx + cos(ang) * len / 2, y: cy + sin(ang) * len / 2))
        }
        var n = 0
        for snr in spec.satelliteSNRs {
            for _ in 0..<spec.satellitesPerSNR {
                n += 1
                let f = Int(rng.nextUInt64() % UInt64(max(1, frames - 1)))
                let (a, b) = randomLine(minLen: 300, maxLen: 700)
                let fwhm = rng.uniform(spec.satelliteFWHM[0], spec.satelliteFWHM[1])
                out.append(PlannedObject(id: "sat\(n)", kind: .satellite, frame: f, a: a, b: b, snr: snr, fwhm: fwhm, separation: 0, tint: [1, 1, 1]))
                if rng.uniform(0, 1) < spec.satelliteContinueFraction {
                    // collinear continuation into the next frame: same direction, small gap, same brightness
                    let dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy)
                    let gap = rng.uniform(20, 80)
                    let a2 = Point(x: b.x + dx / len * gap, y: b.y + dy / len * gap)
                    let b2 = Point(x: a2.x + dx, y: a2.y + dy)
                    let inFrame = { (p: Point) in p.x >= 0 && p.y >= 0 && p.x < Double(width) && p.y < Double(height) }
                    if f + 1 < frames, inFrame(a2), inFrame(b2) {
                    out.append(PlannedObject(id: "sat\(n)b", kind: .satellite, frame: f + 1, a: a2, b: b2, snr: snr, fwhm: fwhm, separation: 0, tint: [1, 1, 1]))
                    }
                }
            }
        }
        for k in 0..<spec.airplanes {
            let f = Int(rng.nextUInt64() % UInt64(frames))
            var (a, b) = randomLine(minLen: 350, maxLen: 900)
            if k % 3 == 2 {   // some run off the frame edge
                let dx = b.x - a.x, dy = b.y - a.y
                b = Point(x: b.x + dx * 0.6, y: b.y + dy * 0.6)
            }
            out.append(PlannedObject(id: "air\(k + 1)", kind: .airplane, frame: f, a: a, b: b, snr: spec.airplaneSNR,
                                     fwhm: 2.5, separation: rng.uniform(3, 6), tint: rng.pick(tints)))
        }
        for k in 0..<spec.meteors {
            let f = Int(rng.nextUInt64() % UInt64(frames))
            let (a, b) = randomLine(minLen: 60, maxLen: 200)
            out.append(PlannedObject(id: "met\(k + 1)", kind: .meteor, frame: f, a: a, b: b, snr: spec.meteorSNR,
                                     fwhm: 3, separation: 0, tint: [1, 1, 1]))
        }
        return out
    }

    /// Draws one planned object into a frame and returns its label.
    public static func render(_ o: PlannedObject, into r: inout Raster, sigma bgSigma: Float) -> LabelObject {
        let s = o.fwhm / 2.355
        let amp = Float(o.snr) * bgSigma
        switch o.kind {
        case .satellite:
            draw(&r, poly: [o.a, o.b], sigma: s, amp: amp, tint: o.tint)
            return LabelObject(id: o.id, class: .satellite, points: [[o.a.x, o.a.y], [o.b.x, o.b.y]],
                               width: (o.fwhm * 2).rounded(.up), confirmed: true, note: "synthetic, SNR \(o.snr)")
        case .airplane:
            let dx = o.b.x - o.a.x, dy = o.b.y - o.a.y, len = hypot(dx, dy)
            let nx = -dy / len * o.separation / 2, ny = dx / len * o.separation / 2
            for sign in [-1.0, 1.0] {
                let p = [Point(x: o.a.x + sign * nx, y: o.a.y + sign * ny), Point(x: o.b.x + sign * nx, y: o.b.y + sign * ny)]
                draw(&r, poly: p, sigma: s, amp: amp, tint: o.tint, dots: sign > 0 ? 90 : nil)
            }
            return LabelObject(id: o.id, class: .airplane, points: [[o.a.x, o.a.y], [o.b.x, o.b.y]],
                               width: (o.separation + o.fwhm * 2).rounded(.up), confirmed: true,
                               note: "synthetic, two lines \(String(format: "%.1f", o.separation)) px apart, SNR \(o.snr)")
        case .meteor:
            draw(&r, poly: [o.a, o.b], sigma: s, amp: amp, tint: o.tint, taper: true)
            return LabelObject(id: o.id, class: .meteor, points: [[o.a.x, o.a.y], [o.b.x, o.b.y]],
                               width: (o.fwhm * 2).rounded(.up), confirmed: true, note: "synthetic, tapered, bright head")
        }
    }
}

public struct PlannedObject: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case satellite, airplane, meteor }
    public var id: String
    public var kind: Kind
    public var frame: Int
    public var a: Point
    public var b: Point
    public var snr: Double
    public var fwhm: Double
    public var separation: Double
    public var tint: [Float]
}
