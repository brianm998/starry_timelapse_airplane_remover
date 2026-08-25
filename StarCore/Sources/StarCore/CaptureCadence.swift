import Foundation
import StarCppBridge
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// How far apart, in time, consecutive frames of a static sequence really were —
/// measured from the sky itself, in units of the sequence's nominal frame step.
///
/// `validateStaticStarAlignment` stamps one median homography set onto every frame,
/// on the reasoning that a fixed camera sees the same star motion all night.  That is
/// true per unit *time*, not per frame: a sequence whose capture interval hiccups —
/// a ramped exposure settling at dusk, a stalled buffer, a battery swap — has gaps
/// that are a fraction or a multiple of the nominal step, and for every pair spanning
/// such a gap the stamped warp lands neighbour content in the wrong place.  Measured
/// on a real 42MP sequence: one gap of 0.19 steps and one of 1.54 steps put doubled
/// stars and torn ground into exactly the twelve frames whose neighbour windows span
/// them, while every other frame came out clean.
///
/// The per-frame *measured* homographies cannot repair this: descriptor matching on a
/// star field aliases badly (a star grid matched one star over produces a plausible
/// consensus), which is the reason the median stamp exists at all.  So the gap
/// durations are measured directly instead, two ways:
///
///  - `matchedStarSpan`: match keypoint *positions* (no descriptors) between the two
///    frames of a gap, project each candidate motion onto the median model's local
///    drift direction, and take the histogram peak over the whole frame.  Cheap —
///    the keypoint files are already on disk — and decisive wherever stars dominate.
///
///  - `PixelatedImageBridge.skyShift`: phase correlation of a sky crop of the two
///    originals, high-passed so stars outvote clouds and twilight gradients.  Used
///    for the gaps keypoints cannot decide: at dusk the strongest SIFT points sit on
///    fixed-pattern content (hot pixels, dust) and on clouds, so the position match
///    reads "nothing moved" — and a genuinely short gap moves the stars less than a
///    pixel, which is indistinguishable from that.  The image itself still knows.
///
/// A gap that measures nominal keeps today's stamped entries bit-for-bit; only pairs
/// spanning an anomalous gap get a synthesized fraction of the median warp.
public enum CaptureCadence {

    /// One consecutive gap as measured by keypoint-position matching.
    public struct GapMeasurement: Sendable {
        /// The gap's duration in nominal steps.
        public let span: Double
        /// Matches inside the winning histogram peak.
        public let matches: Int
        /// All candidate matches that voted.
        public let candidates: Int
        /// Peak mass over all votes: how unanimous the sky was.
        public let confidence: Double
        /// Fraction of candidate pairs that did not move at all — fixed-pattern
        /// sensor content.  High values mean the frame has little usable sky signal.
        public let stationaryFraction: Double
    }

    /// The gates a `GapMeasurement` must pass before its span is believed.
    ///
    /// The span floor is load-bearing: star motion under a third of a step is under
    /// a pixel or two, which position matching cannot tell apart from the
    /// fixed-pattern points it excludes — so a very short real gap must come back
    /// `nil` here and be measured from the images instead.
    public static func trustedSpan(_ measurement: GapMeasurement?) -> Double? {
        guard let measurement,
              measurement.matches >= 60,
              measurement.confidence >= 0.3,
              measurement.span >= 0.3
        else { return nil }
        return measurement.span
    }

    /// A gap is anomalous when it differs from the nominal step by more than this.
    /// Nominal gaps measure within ±0.03 of 1.0 on real sequences; the anomalies
    /// seen so far are 0.19 and 1.54, so the threshold is not a knife edge.
    public static let anomalyTolerance = 0.2

    // MARK: - Tier 1: keypoint-position matching

    /// Measure one gap's duration from the two frames' keypoint positions.
    ///
    /// For every keypoint `a` of the earlier frame, every keypoint of the later
    /// frame within reach is a candidate for "where `a`'s star went".  Each
    /// candidate's motion is projected onto the model's local per-step drift
    /// direction at `a`, yielding a span in step units; candidates moving off that
    /// direction by more than a couple of pixels are discarded (clouds), as are
    /// pairs that did not move (hot pixels, dust — and, indistinguishably, real
    /// motion under a step's fraction, which is why `trustedSpan` floors the span).
    /// Star matches all vote the same span; the histogram peak is the answer.
    ///
    /// - Parameters:
    ///   - earlier: keypoint positions of the gap's first frame, full-res coords.
    ///   - later: keypoint positions of the gap's second frame.
    ///   - oneStep: the median homography mapping a one-step-later neighbour onto
    ///     its base frame — the model of one nominal step.
    ///   - maxSpan: how many nominal steps of motion to search for.
    public static func matchedStarSpan(
      from earlier: [(x: Double, y: Double)],
      to later: [(x: Double, y: Double)],
      oneStep: [Double],
      maxSpan: Double = 3.5
    ) -> GapMeasurement? {
        guard earlier.count >= 30, later.count >= 30,
              let inverse = invert3x3(oneStep)
        else { return nil }

        // Bucket the later frame's points so each earlier point only looks nearby.
        let cell = 64.0
        var grid: [Int64: [Int]] = [:]
        func key(_ cx: Int, _ cy: Int) -> Int64 { Int64(cx) << 32 | Int64(UInt32(bitPattern: Int32(cy)))
        }
        for (index, p) in later.enumerated() {
            grid[key(Int(p.x / cell), Int(p.y / cell)), default: []].append(index)
        }

        let binWidth = 0.05
        let binCount = Int((maxSpan / binWidth).rounded(.up)) + 1
        var histogram = [Int](repeating: 0, count: binCount)
        var spanSums = [Double](repeating: 0, count: binCount)
        var candidates = 0
        var stationary = 0

        for a in earlier {
            // this point's one-step drift under the model: where a later frame's
            // copy of it sits, relative to it
            guard let q = apply(inverse, to: a) else { continue }
            let drift = (x: q.x - a.x, y: q.y - a.y)
            let magnitude = (drift.x * drift.x + drift.y * drift.y).squareRoot()
            if magnitude < 0.5 { continue }   // too slow here to measure a span
            let direction = (x: drift.x / magnitude, y: drift.y / magnitude)

            let reach = magnitude * maxSpan + 4
            let cx = Int(a.x / cell), cy = Int(a.y / cell)
            let cellReach = Int(reach / cell) + 1
            for gx in (cx - cellReach)...(cx + cellReach) {
                for gy in (cy - cellReach)...(cy + cellReach) {
                    for index in grid[key(gx, gy)] ?? [] {
                        let b = later[index]
                        let v = (x: b.x - a.x, y: b.y - a.y)
                        if abs(v.x) > reach || abs(v.y) > reach { continue }
                        let distance = (v.x * v.x + v.y * v.y).squareRoot()
                        if distance < 0.75 {
                            // no motion: fixed-pattern content, not sky
                            stationary += 1
                            continue
                        }
                        let along = v.x * direction.x + v.y * direction.y
                        let span = along / magnitude
                        if span < 0.05 || span > maxSpan { continue }
                        let perpX = v.x - along * direction.x
                        let perpY = v.y - along * direction.y
                        if (perpX * perpX + perpY * perpY).squareRoot() > 2.0 {
                            continue   // moving, but not the way the sky moves here
                        }
                        candidates += 1
                        let bin = min(binCount - 1, Int(span / binWidth))
                        histogram[bin] += 1
                        spanSums[bin] += span
                    }
                }
            }
        }

        guard candidates >= 30 else { return nil }
        var peak = 0
        for bin in 1..<binCount where histogram[bin] > histogram[peak] { peak = bin }
        let low = max(0, peak - 1)
        let high = min(binCount - 1, peak + 1)
        var matches = 0
        var spanSum = 0.0
        for bin in low...high {
            matches += histogram[bin]
            spanSum += spanSums[bin]
        }
        guard matches >= 30 else { return nil }
        return GapMeasurement(
          span: spanSum / Double(matches),
          matches: matches,
          candidates: candidates,
          confidence: Double(matches) / Double(candidates),
          stationaryFraction: Double(stationary) / Double(stationary + candidates)
        )
    }

    // MARK: - Tier 2: the images themselves

    /// Measure one gap's duration from the two original frames at several sky crops,
    /// believed only when the crops agree.
    ///
    /// A single crop is not to be trusted: fixed-pattern sensor content correlates at
    /// exactly zero shift, and in a twilight crop with weak stars it can win the
    /// correlation and read as a short gap that never happened — measured doing
    /// exactly that on a real dusk sequence.  But a fixed-pattern lock reads *zero
    /// pixels* everywhere while a real gap reads the same *span* everywhere, and the
    /// model's per-step drift differs from crop to crop — so spans that agree across
    /// crops were measured from the sky, and spans that do not are discarded, leaving
    /// the gap treated as nominal, which is what would have happened without this
    /// measurement at all.
    public static func consensusSpan(
      from earlier: PixelatedImage,
      to later: PixelatedImage,
      oneStep: [Double],
      crops: [(x: Int, y: Int, size: Int)],
      agreement: Double = 0.2,
      loneResponseFloor: Double = 0.1
    ) -> Double? {
        let measurements = crops.compactMap { crop in
            measuredSpan(from: earlier, to: later, oneStep: oneStep,
                         cropX: crop.x, cropY: crop.y, cropSize: crop.size)
        }
        if measurements.count == 1 {
            // The direction and range gates in measuredSpan discard the crops a
            // cloud decided, so a lone survivor is a measurement the sky made —
            // believed only when its correlation peak is decisive.
            let lone = measurements[0]
            return lone.response >= loneResponseFloor ? lone.span : nil
        }
        guard measurements.count >= 2 else { return nil }
        let sorted = measurements.map(\.span).sorted()
        // the two closest to each other; with three measurements this drops the one
        // outlier a cloud or a weak correlation produced
        var best: (a: Double, b: Double)? = nil
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            if best == nil || b - a < best!.b - best!.a { best = (a, b) }
        }
        guard let best, best.b - best.a <= agreement else { return nil }
        return (best.a + best.b) / 2
    }

    /// Measure one gap's duration from the two original frames, for the gaps
    /// keypoints cannot decide.  `skyShift` phase-correlates a high-passed sky crop;
    /// the shift's projection onto the model's drift at the crop centre, in units of
    /// that drift, is the span.  Nil when the correlation found nothing to trust or
    /// the content moves against the model's direction.
    public static func measuredSpan(
      from earlier: PixelatedImage,
      to later: PixelatedImage,
      oneStep: [Double],
      cropX: Int, cropY: Int, cropSize: Int,
      minResponse: Double = 0.01
    ) -> (span: Double, response: Double)? {
        guard let inverse = invert3x3(oneStep) else { return nil }
        let center = (x: Double(cropX + cropSize / 2), y: Double(cropY + cropSize / 2))
        guard let q = apply(inverse, to: center) else { return nil }
        let drift = (x: q.x - center.x, y: q.y - center.y)
        let magnitude = (drift.x * drift.x + drift.y * drift.y).squareRoot()
        guard magnitude > 0.5 else { return nil }

        guard let shift = PixelatedImageBridge.skyShift(
                from: earlier.mat, to: later.mat,
                cropX: Int32(cropX), cropY: Int32(cropY),
                cropWidth: Int32(cropSize), cropHeight: Int32(cropSize)
              ),
              shift.response >= minResponse
        else { return nil }

        // The shift has to lie along the sky's motion at this crop.  Clouds move
        // their own way: a correlation that locked onto them reads tens of pixels
        // off the sidereal direction, and the perpendicular component is how that
        // shows — measured 40 to 80% of the vector on real dusk crops, against
        // under 5% when the stars decide.
        let parallel = shift.dx * drift.x + shift.dy * drift.y
        let span = parallel / (magnitude * magnitude)
        let perpX = shift.dx - span * drift.x
        let perpY = shift.dy - span * drift.y
        let perpendicular = (perpX * perpX + perpY * perpY).squareRoot()
        guard perpendicular <= max(1.5, 0.35 * abs(span) * magnitude) else { return nil }

        // moving against the sky, or implausibly far: not a measurement
        guard span > -0.05, span < 4.5 else { return nil }
        return (span: max(0.0, span), response: shift.response)
    }

    // MARK: - Synthesis

    /// The median warp for a span of `span` nominal steps, interpolated linearly
    /// between the two nearest measured anchors — the median set's own integer
    /// offsets, with identity at zero.  First-order exact at timelapse angles, the
    /// same approximation `HomographyOffsetModel` documents; using the bracketing
    /// measured matrices rather than one global slope keeps whatever curvature the
    /// measurements carry.
    ///
    /// `span` is signed the way offsets are: positive for a later neighbour.
    public static func fractionalHomography(
      atSpan span: Double,
      anchors: [Int: [Double]]
    ) -> [Double]? {
        let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        var available = anchors.filter { $0.value.count == 9 }
        available[0] = identity
        let keys = available.keys.sorted()
        guard keys.count >= 2 else { return nil }

        // the bracketing pair, or the nearest edge pair for extrapolation
        var lower = keys[0]
        var upper = keys[1]
        for (a, b) in zip(keys, keys.dropFirst()) {
            lower = a
            upper = b
            if Double(b) >= span { break }
        }
        let alpha = (span - Double(lower)) / Double(upper - lower)
        let h0 = available[lower]!
        let h1 = available[upper]!
        return zip(h0, h1).map { (1.0 - alpha) * $0 + alpha * $1 }
    }

    // MARK: - 3x3 helpers

    static func invert3x3(_ m: [Double]) -> [Double]? {
        guard m.count == 9 else { return nil }
        let a = m[0], b = m[1], c = m[2]
        let d = m[3], e = m[4], f = m[5]
        let g = m[6], h = m[7], i = m[8]
        let det = a*(e*i - f*h) - b*(d*i - f*g) + c*(d*h - e*g)
        guard abs(det) > 1e-12 else { return nil }
        return [
          (e*i - f*h)/det, (c*h - b*i)/det, (b*f - c*e)/det,
          (f*g - d*i)/det, (a*i - c*g)/det, (c*d - a*f)/det,
          (d*h - e*g)/det, (b*g - a*h)/det, (a*e - b*d)/det,
        ]
    }

    static func apply(_ h: [Double], to p: (x: Double, y: Double)) -> (x: Double, y: Double)? {
        let w = h[6]*p.x + h[7]*p.y + h[8]
        guard abs(w) > 1e-12 else { return nil }
        return (x: (h[0]*p.x + h[1]*p.y + h[2]) / w,
                y: (h[3]*p.x + h[4]*p.y + h[5]) / w)
    }
}
