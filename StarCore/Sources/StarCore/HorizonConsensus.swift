import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// A moving sequence's horizon, frame by frame, from the horizons *detected* in the frames
/// around each one, carried into it along the ground.
///
/// ## Why
///
/// A per-frame detector fails in ways that come and go: a dark cloud bank sitting on the
/// ridge reads as ground, and so does an aurora-lit haze, for as long as it lasts.  The
/// terrain itself does not move on the ground, so once the earth alignment has measured how
/// the camera moved, every other frame's detection says where *this* frame's horizon is —
/// and the frames whose detection is wrong disagree with each other (clouds drift and
/// change), while the ones that are right agree.
///
/// What did not work, so this is not tried again: medians of the ground-aligned *pixels* of
/// the neighbours (±4 to ±120 frames), and change, variance or edge-persistence measures
/// over them.  A pan aligns a distant cloud bank just as well as the distant terrain under
/// it, and the bank changes only about twice as much as the ground does, so on the cloud
/// frames those stayed at ~2% of the height while making moonlit snow worse.  Combining the
/// *lines* is what works.
///
/// ## How
///
/// 1. Each frame's detection is kept as `gridWidth` rows.
/// 2. Each stored earth homography is re-expressed as a pure camera rotation `K R K⁻¹` with
///    one focal length for the whole sequence, and chains are composed from those.  The
///    ground used to be fitted as a 4-DOF similarity, which cannot represent the perspective
///    of a pan: on a wide-angle pan a single ±4-frame entry left a U-shaped horizontal error
///    of ~10 px across the ground just below the skyline, and composed over a chain that grew
///    into a roll — a painted horizon carried 101-200 frames came out 1.10% of the height
///    wrong; as rotations, 0.35%.  `estimateAlignment` (ImageAligner.cpp) now fits the ground
///    as a rotation itself, with each frame's own focal length, and where the ground has
///    detail its chains drift less again (lines carried 128 frames: a9-2 0.27% → 0.08% of the
///    height off, a9-1 10_17 0.18% → 0.04%; a7iv's black ground, no change); the
///    re-expression reproduces those entries, and keeps temp directories aligned before the
///    change working.  The focal length `K` needs is not in the exported frames, so it is
///    found from the sequence itself (`calibrateFocalLength`), and entries no rotation
///    explains — a broken ground fit — are left out of the chains.
/// 3. Every `neighbourStride`th frame within `longSpan` carries its detection into the frame.
///    Per column, the densest window `bandFraction` of the height tall wins, and the answer
///    is the median of its `nearest` members closest in time — once over `shortSpan` and
///    once over `longSpan`.
/// 4. The short-span answer is used, except where the long one differs from it by more than
///    `overrideFraction` of the height.  A cloud bank lasts long enough that the frames
///    around a cloudy frame share its mistake, so only the long span sees past it; but
///    over a long span the chains are less exact, so where nothing that large is wrong the
///    short span is the more precise answer.  The corrections that mattered were 8-9% of
///    the height, the disagreements that chain error causes about 1%.
/// 5. Where the user has painted horizons, each frame's line is corrected by the painted
///    frames either side of it, by as much as the consensus is wrong at them, fading with
///    the distance to the nearest (`referenceCorrectionDistance`); a painted frame's line is
///    its painting.  So the user can paint where the consensus goes wrong and keep it
///    everywhere else.
/// 6. Each line is replaced by the mean of its neighbours' within `temporalSmoothingRadius`,
///    carried into it, so it does not flicker as the voters change.
///
/// ## Measured
///
/// Mean / worst error per frame against the user's painted horizons, % of the height:
///
///                                              per-frame    consensus
///     a7iv 04_18, cloud bank on the ridge (6)   1.94 / 2.51   0.10 / 0.13
///     a9-2 03_16, moonlit snow (2)              0.50 / 0.55   0.42 / 0.45
///     a9-1 10_17, clean (12)                    0.10 / 0.18   0.05 / 0.07
///     a9-1 01_18, broken ground alignment (6)   0.59 / 1.68   0.38 / 1.69
///
/// Through the CLI on the a7iv frames, against the merged masks the composite used before:
/// 2.29 / 4.06 → 0.10 / 0.13, for 25 s over 371 frames — the same with the ground fitted as a
/// rotation (a9-2 0.41 / 0.46, a7iv 0.10 / 0.13, and a9-1 10_17's first 400 frames 0.05 / 0.07
/// against 0.15 / 0.18 for the merged masks).  The snow is not a mistake that comes
/// and goes, so there is little for the other frames to outvote; the broken alignment has a
/// third of its ground fits left out, and so little to carry lines with.
///
/// Every constant here was chosen on those same 26 frames: treat them as tuned, not proven.
public enum HorizonConsensus {

    /// Recorded with the consensus lines (`ArtifactInputs`), so bumping it rebuilds them, and
    /// the outliers and output frames composited with them.  Bump it for a change that moves
    /// the lines, not for one to cost or logging.
    ///
    /// - 1: rotation-model chains, self-calibrated focal length, ±64 / ±400 densest-window
    ///      consensus, long-span override past 2% of the height.
    /// - 2: painted references anchor it (`referenceCorrectionDistance`) instead of switching
    ///      it off.
    /// - 3: each line is the mean of its neighbours' within `temporalSmoothingRadius`, carried
    ///      into it.
    public static let algorithmVersion = 3

    public struct Parameters: Sendable, Equatable {
        /// Columns a line is kept at, spread evenly across the frame.  The detections this
        /// combines were made 1600 px wide (`FrameHorizonProcessor`'s working-size
        /// detection), so nothing finer exists to keep.
        public var gridWidth = 1600

        /// Every how many frames a neighbour votes.  Adjacent frames' detections are nearly
        /// the same evidence; one in four measured the same as every frame.
        public var neighbourStride = 4

        /// Frames either side for the precise answer, and for the one that sees past a
        /// long-lived mistake.  The cloud episode this was built on lasted ~220 frames.
        public var shortSpan = 64
        public var longSpan = 400

        /// Height of the densest window, as a fraction of the frame height.  0.1-0.5% all
        /// measured the same; 1% let cloud tops into the window.
        public var bandFraction = 0.0025

        /// How many of the winning window's members are averaged, nearest in time first.
        public var nearest = 8

        /// How far the long-span answer must be from the short one to replace it, as a
        /// fraction of the frame height.
        public var overrideFraction = 0.02

        /// The largest RMS distance, in pixels per 6000 px of width, between a stored ground
        /// fit and the camera rotation that best matches it for an entry to stay in a chain.
        /// The clean sequences' entries all sat within 5-7 (0.4% of one sequence's beyond 6);
        /// one with a broken ground alignment had a third of its entries beyond 6, up to 150.
        public var maxRotationResidual = 6.0

        /// The focal length is chosen by how well lines carried this many frames agree with
        /// the detections they land on.
        public var calibrationDistance = 128

        /// One calibration target in this many frames — fewer frames apart in a sequence too
        /// short for sixteen of them at this spacing.
        public var calibrationTargetStride = 16

        /// Fewer measured pairs than this and the focal length is not trusted.
        public var minimumCalibrationPairs = 8

        /// How far, in frames, a painted reference's correction reaches: it fades as
        /// `exp(-distance / referenceCorrectionDistance)` from the nearest painted frame.
        ///
        /// Near a painted frame the reference carried along the ground is the better answer
        /// (a7iv, 4 frames away: 0.12% → 0.04% of the height); far from one it is the worse,
        /// because the chain it is carried by drifts (a9-1 10_17, 175 frames away: 0.05% for
        /// the consensus, 0.18% for the carried reference).  The correction is that
        /// reference's disagreement with the consensus at the painted frame, carried the same
        /// way, so chain error largely cancels out of it; fading it measured never worse than
        /// the consensus alone over leave-one-out tests on four sequences (16 to 128 frames
        /// all close; 128 helped most where the consensus was biased — a9-2's snow, 0.41% →
        /// 0.34%), and applying it undiminished hurt next to frames painted because the
        /// consensus was locally wrong there.
        public var referenceCorrectionDistance = 128.0

        /// Frames either side whose lines, carried into a frame, are averaged into its own.
        ///
        /// The vote changes its members every `neighbourStride` frames, and a column whose
        /// densest window sits between two clusters (a ridge's trees against the slope behind
        /// them) flips between them as it does: narrow spikes a few columns wide, 16-64 px on a
        /// 4000 px frame, most gone again within four frames, which play as lines dancing along
        /// the horizon.  The mean over ±16 removed them — frames with a jump past 16 px went
        /// 65% → 11% (a9-1 01_18), 72% → 0% (a7iv), 32% → 0% (a9-1 10_17), 100% → 0% (a9-2) —
        /// and moved accuracy against the painted horizons by no more than 0.006% of the
        /// height, all of it better.  ±8 left more of them; a median or a trimmed mean left
        /// more still, since which member is in the middle is exactly what changes.  The
        /// ground does not move, so averaging the carried lines blurs nothing real.  0 turns
        /// it off.
        public var temporalSmoothingRadius = 16

        /// Focal lengths tried, as multiples of the frame width: 14 mm to 100 mm on a
        /// full-frame sensor.  The best one is then refined 6% either way.
        public var focalLengthCandidates: [Double] = [
            0.40, 0.46, 0.53, 0.61, 0.70, 0.81, 0.93, 1.07, 1.23, 1.41, 1.62, 1.87, 2.15, 2.47, 2.84,
        ]

        public init() {}
    }

    /// The focal length the chains were built with, and how it was chosen.
    public struct Calibration: Codable, Sendable, Equatable {
        public struct Candidate: Codable, Sendable, Equatable {
            /// Pixels.
            public let focalLength: Double
            /// 25th percentile, over the calibration targets, of the median distance between a
            /// carried line and the target's own detection, as a fraction of the height.
            public let drift: Double
            public let pairs: Int
        }
        public let focalLength: Double
        public let drift: Double
        /// How many frames the lines were carried to measure the drift.  `calibrationDistance`,
        /// or less in a sequence too short for it.
        public let distance: Int
        public let candidates: [Candidate]
        /// The stored ground fits left out of the chains, and how many there were.
        public let rejectedEntries: Int
        public let entries: Int
    }

    /// What `run` produced.
    public struct Outcome: Sendable {
        /// Target frame index → consensus line, at `Parameters.gridWidth` columns, in
        /// full-resolution rows; `height` or more means no ground in that column.
        public let lines: [Int: [Float]]
        public let calibration: Calibration
        /// Columns, over every target, where the long-span answer replaced the short one.
        public let overriddenColumns: Int
        public let columns: Int
        /// Targets whose line a painted reference corrected, and targets that were painted.
        public var correctedTargets = 0
        public var paintedTargets = 0
    }

    // MARK: - Lines

    /// Full-resolution x of grid column `i`: the centre of the i-th of `gridWidth` equal
    /// slices of the frame, in pixel-centre coordinates.
    static func gridX(_ i: Int, width: Int, gridWidth: Int) -> Double {
        (Double(i) + 0.5) * Double(width) / Double(gridWidth) - 0.5
    }

    /// `horizonY` — the first ground row of every full-resolution column, nil where a column
    /// has none — at `gridWidth` columns.  A column with no ground reads as `height`.
    public static func gridLine(fromColumns horizonY: [Int?], height: Int, gridWidth: Int) -> [Float] {
        let width = horizonY.count
        guard width > 0, gridWidth > 0 else { return [] }
        return (0..<gridWidth).map { i in
            let x = min(width - 1, max(0, Int(gridX(i, width: width, gridWidth: gridWidth).rounded())))
            return Float(horizonY[x] ?? height)
        }
    }

    /// `line` at full width, for a mask: each column reads the two grid columns either side
    /// of it, linearly.  Clamped to `0...height`, where `height` means no ground.
    public static func columnRows(_ line: [Float], width: Int, height: Int) -> [Int] {
        let gridWidth = line.count
        guard gridWidth > 0, width > 0 else { return [] }
        let h = Float(height)
        return (0..<width).map { x in
            let g = (Double(x) + 0.5) * Double(gridWidth) / Double(width) - 0.5
            let left = max(0, min(gridWidth - 1, Int(g.rounded(.down))))
            let right = min(gridWidth - 1, left + 1)
            let t = Float(max(0, min(1, g - Double(left))))
            let a = line[left], b = line[right]
            // A column with no ground either side stays without ground rather than gaining
            // a sliver of it from the interpolation.
            if a >= h && b >= h { return height }
            let row = a * (1 - t) + b * t
            return max(0, min(height, Int(row.rounded())))
        }
    }

    // MARK: - Camera rotations

    static let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]

    /// `K R K⁻¹` for focal length `f`, principal point `(cx, cy)`, and the rotation
    /// `Rz(roll) · Rx(tilt) · Ry(pan)`.
    static func rotationHomography(f: Double, cx: Double, cy: Double,
                                   pan: Double, tilt: Double, roll: Double) -> [Double] {
        rotationMatrix(f: f, cx: cx, cy: cy, pan: pan, tilt: tilt, roll: roll).array
    }

    /// A row-major 3x3 in nine stored values rather than an array, for the rotation fit's
    /// inner loop, which builds one per residual.
    struct Matrix3 {
        var m00, m01, m02, m10, m11, m12, m20, m21, m22: Double

        func apply(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
            let w = m20 * x + m21 * y + m22
            return ((m00 * x + m01 * y + m02) / w, (m10 * x + m11 * y + m12) / w)
        }

        var array: [Double] { [m00, m01, m02, m10, m11, m12, m20, m21, m22] }
    }

    static func rotationMatrix(f: Double, cx: Double, cy: Double,
                               pan: Double, tilt: Double, roll: Double) -> Matrix3 {
        let (sy, cyw) = (sin(pan), cos(pan))
        let (sx, cxw) = (sin(tilt), cos(tilt))
        let (sz, czw) = (sin(roll), cos(roll))
        // R = Rz · Rx · Ry, written out
        let r00 = czw * cyw - sz * sx * sy, r01 = -sz * cxw, r02 = czw * sy + sz * sx * cyw
        let r10 = sz * cyw + czw * sx * sy, r11 = czw * cxw, r12 = sz * sy - czw * sx * cyw
        let r20 = -cxw * sy, r21 = sx, r22 = cxw * cyw
        // R · K⁻¹, then K · that
        let a02 = r02 - (cx * r00 + cy * r01) / f
        let a12 = r12 - (cx * r10 + cy * r11) / f
        let a22 = r22 - (cx * r20 + cy * r21) / f
        let (a00, a01) = (r00 / f, r01 / f)
        let (a10, a11) = (r10 / f, r11 / f)
        let (a20, a21) = (r20 / f, r21 / f)
        return Matrix3(m00: f * a00 + cx * a20, m01: f * a01 + cx * a21, m02: f * a02 + cx * a22,
                       m10: f * a10 + cy * a20, m11: f * a11 + cy * a21, m12: f * a12 + cy * a22,
                       m20: a20, m21: a21, m22: a22)
    }

    /// The camera rotation, for focal length `focalLength` with the principal point at the
    /// centre, that moves the ground band most nearly as `similarity` does — and how far apart
    /// the two are over that band, as an RMS over the x and y of a 9 × 4 grid of points from
    /// `bandTop` to near the bottom of the frame.
    ///
    /// The stored fit was made to keypoints in that band, so the band is where it is right;
    /// the rotation reproduces it there and is right everywhere else too, which is what a
    /// chain of them needs.
    ///
    /// Fitted to the stored similarity directly, which is not quite the rotation that
    /// produced it: on a synthetic 24 mm pan the pan comes out ~2% short, 0.17 px over a
    /// 4-frame hop.  The alternative — the rotation whose own best similarity over the band
    /// *is* the stored one — removes that on synthetic data and measured worse on the real
    /// sequences (a9-1 10_17's worst frame 0.07% → 0.27%), whose fits were made to wherever
    /// the keypoints happened to be rather than to an even band.  The bias is uniform, and
    /// the self-calibrated focal length absorbs it.
    public static func rotationHomography(
      matching similarity: [Double],
      width: Int,
      height: Int,
      focalLength f: Double,
      bandTop: Double
    ) -> (homography: [Double], rms: Double) {
        let cx = Double(width) / 2, cy = Double(height) / 2
        let bottom = 0.97 * Double(height)
        let top = min(bandTop, bottom - 1)
        var points: [(x: Double, y: Double)] = []
        for i in 0..<9 {
            for j in 0..<4 {
                points.append((Double(width) * (0.05 + 0.9 * Double(i) / 8),
                               top + (bottom - top) * Double(j) / 3))
            }
        }
        let targets = points.map { apply(similarity, $0.x, $0.y) }
        let n = points.count * 2

        func residuals(_ p: (Double, Double, Double), into r: inout [Double]) {
            let h = rotationMatrix(f: f, cx: cx, cy: cy, pan: p.0, tilt: p.1, roll: p.2)
            for (k, point) in points.enumerated() {
                let moved = h.apply(point.x, point.y)
                r[2 * k] = moved.x - targets[k].x
                r[2 * k + 1] = moved.y - targets[k].y
            }
        }
        func cost(_ r: [Double]) -> Double { r.reduce(0) { $0 + $1 * $1 } }

        // Start from the band centre's motion: a pan moves it sideways, a tilt up or down.
        let centre = (x: cx, y: (top + bottom) / 2)
        let movedCentre = apply(similarity, centre.x, centre.y)
        var p = (atan2(movedCentre.x - centre.x, f),
                 -atan2(movedCentre.y - centre.y, f),
                 atan2(similarity[3], similarity[0]))

        var r = [Double](repeating: 0, count: n)
        var trial = [Double](repeating: 0, count: n)
        var columns = [[Double]](repeating: [Double](repeating: 0, count: n), count: 3)
        residuals(p, into: &r)
        var current = cost(r)
        var lambda = 1e-3
        let step = 1e-7
        for _ in 0..<50 {
            // Forward-difference Jacobian, a column per parameter.
            for c in 0..<3 {
                var q = p
                switch c {
                case 0: q.0 += step
                case 1: q.1 += step
                default: q.2 += step
                }
                residuals(q, into: &trial)
                for k in 0..<n { columns[c][k] = (trial[k] - r[k]) / step }
            }
            var a = [Double](repeating: 0, count: 9)
            var g = [Double](repeating: 0, count: 3)
            for i in 0..<3 {
                for j in 0..<3 {
                    var sum = 0.0
                    for k in 0..<n { sum += columns[i][k] * columns[j][k] }
                    a[i * 3 + j] = sum
                }
                var sum = 0.0
                for k in 0..<n { sum += columns[i][k] * r[k] }
                g[i] = sum
            }
            var improved = false
            for _ in 0..<8 {
                var damped = a
                for i in 0..<3 { damped[i * 4] += lambda * max(a[i * 4], 1e-12) }
                guard let delta = solve3(damped, [-g[0], -g[1], -g[2]]) else { lambda *= 10; continue }
                let candidate = (p.0 + delta[0], p.1 + delta[1], p.2 + delta[2])
                residuals(candidate, into: &trial)
                let candidateCost = cost(trial)
                if candidateCost < current {
                    let moved = abs(delta[0]) + abs(delta[1]) + abs(delta[2])
                    p = candidate
                    swap(&r, &trial)
                    current = candidateCost
                    lambda = max(lambda / 10, 1e-12)
                    improved = moved > 1e-13
                    break
                }
                lambda *= 10
            }
            if !improved { break }
        }
        let homography = rotationHomography(f: f, cx: cx, cy: cy, pan: p.0, tilt: p.1, roll: p.2)
        return (homography, (current / Double(n)).squareRoot())
    }

    /// Every stored ground fit in `records` (frame index → neighbour index → the 3x3 carrying
    /// that neighbour into the frame) re-expressed as a camera rotation, less the ones no
    /// rotation explains.  Also returns how many were left out.
    public static func rotationRecords(
      _ records: [Int: [Int: [Double]]],
      width: Int,
      height: Int,
      focalLength: Double,
      bandTop: Double,
      maxResidual: Double
    ) -> (records: [Int: [Int: [Double]]], rejected: Int) {
        let frames = Array(records.keys)
        let converted = Results<(row: [Int: [Double]], rejected: Int)>(([:], 0), count: frames.count)
        let limit = maxResidual * Double(width) / 6000
        DispatchQueue.concurrentPerform(iterations: frames.count) { index in
            var row: [Int: [Double]] = [:]
            var rejected = 0
            for (neighbour, similarity) in records[frames[index]] ?? [:] {
                let fit = rotationHomography(matching: similarity, width: width,
                                             height: height, focalLength: focalLength,
                                             bandTop: bandTop)
                if fit.rms <= limit {
                    row[neighbour] = fit.homography
                } else {
                    rejected += 1
                }
            }
            converted.set(index, (row, rejected))
        }
        var result: [Int: [Int: [Double]]] = [:]
        var rejected = 0
        let entries = converted.all
        for (index, frame) in frames.enumerated() {
            let entry = entries[index]
            result[frame] = entry.row
            rejected += entry.rejected
        }
        return (result, rejected)
    }

    // MARK: - Chains

    /// For every frame within `span` of `target`, the homography carrying that frame's
    /// coordinates into `target`'s, by the widest hops the records allow; frames the records
    /// do not connect are absent.
    ///
    /// Widest hop first for the reason `EarthHomographyChain` gives: every hop multiplies in
    /// another fit's error, and the wider entries were each fitted directly.
    static func chains(
      into target: Int,
      span: Int,
      records: [Int: [Int: [Double]]],
      maxHop: Int
    ) -> [Int: [Double]] {
        var result: [Int: [Double]] = [target: identity]
        guard span > 0, maxHop > 0 else { return result }
        for side in [1, -1] {
            for distance in 1...span {
                let source = target + side * distance
                for jump in stride(from: min(maxHop, distance), through: 1, by: -1) {
                    // a frame nearer the target whose record holds an entry for `source`
                    let via = source - side * jump
                    guard let rest = result[via], let entry = records[via]?[source] else { continue }
                    result[source] = multiply(rest, entry)
                    break
                }
            }
        }
        return result
    }

    static func maxHop(of records: [Int: [Int: [Double]]]) -> Int {
        var reach = 0
        for (frame, row) in records {
            for neighbour in row.keys { reach = max(reach, abs(neighbour - frame)) }
        }
        return reach
    }

    // MARK: - Carrying a line

    /// `line`, one frame's grid line, moved by `homography` into another frame's grid
    /// columns.  NaN where it does not reach.
    ///
    /// The line is carried as points, one per grid column, at the boundary between the last
    /// sky row and the first ground row; the result is resampled back onto the grid.
    static func carry(_ line: [Float], by homography: [Double],
                      width: Int, height: Int, into out: inout [Float]) {
        let gridWidth = line.count
        var xs: [Double] = []
        var ys: [Double] = []
        xs.reserveCapacity(gridWidth)
        ys.reserveCapacity(gridWidth)
        for i in 0..<gridWidth where !line[i].isNaN {
            let x = gridX(i, width: width, gridWidth: gridWidth)
            let y = Double(line[i]) - 0.5
            let w = homography[6] * x + homography[7] * y + homography[8]
            guard abs(w) > 1e-12 else { continue }
            xs.append((homography[0] * x + homography[1] * y + homography[2]) / w)
            ys.append((homography[3] * x + homography[4] * y + homography[5]) / w + 0.5)
        }
        for j in 0..<out.count { out[j] = .nan }
        guard xs.count >= 2 else { return }
        var ordered = true
        for k in 1..<xs.count where xs[k] < xs[k - 1] { ordered = false; break }
        if !ordered {
            let order = xs.indices.sorted { xs[$0] < xs[$1] }
            xs = order.map { xs[$0] }
            ys = order.map { ys[$0] }
        }
        var cursor = 0
        for j in 0..<out.count {
            let x = gridX(j, width: width, gridWidth: out.count)
            if x < xs[0] || x > xs[xs.count - 1] { continue }
            while cursor + 1 < xs.count - 1, xs[cursor + 1] < x { cursor += 1 }
            let x0 = xs[cursor], x1 = xs[cursor + 1]
            let span = x1 - x0
            let y = span > 1e-12 ? ys[cursor] + (ys[cursor + 1] - ys[cursor]) * (x - x0) / span
                                 : ys[cursor]
            out[j] = Float(y)
        }
    }

    // MARK: - The vote

    /// Scratch space for `densestWindowRow`, reused across a target's columns.
    struct VoteScratch {
        var rows: [Float] = []
        var order: [Int] = []
        var members: [(distance: Int, offset: Int, row: Float)] = []
        var picked: [Float] = []
    }

    /// One column's answer: among `rows[i]` (NaN for a source that does not reach this
    /// column), the window `band` rows tall holding the most of them — the topmost such
    /// window on a tie — and the median of its `nearest` members closest in time.
    static func densestWindowRow(
      rows: UnsafeBufferPointer<Float>,
      offsets: [Int],
      band: Float,
      nearest: Int,
      scratch: inout VoteScratch
    ) -> Float {
        scratch.order.removeAll(keepingCapacity: true)
        for i in 0..<rows.count where !rows[i].isNaN { scratch.order.append(i) }
        guard !scratch.order.isEmpty else { return .nan }
        scratch.order.sort { rows[$0] < rows[$1] }
        let count = scratch.order.count
        var bestStart = 0, bestEnd = 1, bestCount = 0
        var end = 0
        for start in 0..<count {
            let limit = rows[scratch.order[start]] + band
            if end < start { end = start }
            while end < count, rows[scratch.order[end]] <= limit { end += 1 }
            if end - start > bestCount {
                bestCount = end - start
                bestStart = start
                bestEnd = end
            }
        }
        scratch.members.removeAll(keepingCapacity: true)
        for k in bestStart..<bestEnd {
            let i = scratch.order[k]
            scratch.members.append((abs(offsets[i]), offsets[i], rows[i]))
        }
        scratch.members.sort { ($0.distance, $0.offset) < ($1.distance, $1.offset) }
        scratch.picked.removeAll(keepingCapacity: true)
        for member in scratch.members.prefix(nearest) { scratch.picked.append(member.row) }
        scratch.picked.sort()
        let m = scratch.picked.count
        return m % 2 == 1 ? scratch.picked[m / 2]
                          : (scratch.picked[m / 2 - 1] + scratch.picked[m / 2]) / 2
    }

    /// `target`'s consensus line from `own`, its own detection, and the detections `carried`
    /// into it from the frames at `offsets` (NaN where a carried line does not reach).
    static func consensusLine(
      own: [Float],
      carried: [[Float]],
      offsets: [Int],
      height: Int,
      parameters: Parameters,
      overridden: inout Int
    ) -> [Float] {
        let gridWidth = own.count
        let band = Float(parameters.bandFraction * Double(height))
        let threshold = Float(parameters.overrideFraction * Double(height))
        // The frame's own detection votes in both spans, at offset 0.
        let allOffsets = [0] + offsets
        let shortSources = allOffsets.indices.filter { abs(allOffsets[$0]) <= parameters.shortSpan }
        let shortOffsets = shortSources.map { allOffsets[$0] }
        var column = [Float](repeating: .nan, count: allOffsets.count)
        var shortColumn = [Float](repeating: .nan, count: shortSources.count)
        var scratch = VoteScratch()
        var result = [Float](repeating: 0, count: gridWidth)
        for x in 0..<gridWidth {
            column[0] = own[x]
            for (k, line) in carried.enumerated() { column[k + 1] = line[x] }
            for (k, source) in shortSources.enumerated() { shortColumn[k] = column[source] }
            var short = shortColumn.withUnsafeBufferPointer {
                densestWindowRow(rows: $0, offsets: shortOffsets, band: band,
                                 nearest: parameters.nearest, scratch: &scratch)
            }
            if short.isNaN { short = own[x] }
            var long = column.withUnsafeBufferPointer {
                densestWindowRow(rows: $0, offsets: allOffsets, band: band,
                                 nearest: parameters.nearest, scratch: &scratch)
            }
            if long.isNaN { long = short }
            // with no detection of its own, a column the short span misses takes the long one
            if short.isNaN { short = long }
            if abs(long - short) > threshold {
                result[x] = long
                overridden += 1
            } else {
                result[x] = short
            }
        }
        return result
    }

    // MARK: - Focal length

    /// Where the ground band starts, for the rotation fits: the median detected row, kept
    /// inside the frame.
    static func bandTop(of lines: [Int: [Float]], height: Int) -> Double? {
        var rows: [Float] = []
        let h = Float(height)
        for line in lines.values {
            for (i, row) in line.enumerated() where i % 8 == 0 && row < h { rows.append(row) }
        }
        guard !rows.isEmpty else { return nil }
        rows.sort()
        let median = Double(rows[rows.count / 2])
        return max(0.05 * Double(height), min(0.9 * Double(height), median))
    }

    /// How far lines carried `distance` frames by `records` land from the detections there.
    ///
    /// For one target in every `targetStride` frames, the line of the frame `distance` before
    /// it and of the one after it, each carried in; per pair the median, over the columns
    /// where both have ground, of the distance from the target's own line, as a fraction of
    /// the height; and the 25th percentile of those over the pairs.  A low percentile because
    /// some detections are wrong — clouds, snow — and a pair with a wrong detection in it says
    /// nothing about the chain; the quarter that agree best are the pairs that measure it.
    static func chainDrift(
      lines: [Int: [Float]],
      records: [Int: [Int: [Double]]],
      width: Int,
      height: Int,
      distance: Int,
      targets: [Int],
      maxHop: Int
    ) -> (drift: Double, pairs: Int) {
        let drifts = Results<[Double]>([], count: targets.count)
        let h = Float(height)
        do {
            DispatchQueue.concurrentPerform(iterations: targets.count) { index in
                let target = targets[index]
                guard let own = lines[target] else { return }
                let chain = chains(into: target, span: distance + 2, records: records, maxHop: maxHop)
                var carried = [Float](repeating: .nan, count: own.count)
                var found: [Double] = []
                for side in [-1, 1] {
                    let wanted = target + side * distance
                    guard let source = [wanted, wanted - 1, wanted + 1, wanted - 2, wanted + 2]
                            .first(where: { lines[$0] != nil && chain[$0] != nil }),
                          let line = lines[source], let homography = chain[source]
                    else { continue }
                    carry(line, by: homography, width: width, height: height, into: &carried)
                    var differences: [Float] = []
                    for x in 0..<own.count where !carried[x].isNaN && own[x] < h && carried[x] < h {
                        differences.append(abs(carried[x] - own[x]))
                    }
                    guard Double(differences.count) >= 0.3 * Double(own.count) else { continue }
                    differences.sort()
                    let m = differences.count
                    let median = m % 2 == 1 ? differences[m / 2]
                                            : (differences[m / 2 - 1] + differences[m / 2]) / 2
                    found.append(Double(median) / Double(height))
                }
                drifts.set(index, found)
            }
        }
        let all = drifts.all.flatMap { $0 }.sorted()
        guard !all.isEmpty else { return (.infinity, 0) }
        // numpy's default (linear) percentile, so the numbers match the measurements above
        let position = 0.25 * Double(all.count - 1)
        let low = Int(position.rounded(.down)), high = Int(position.rounded(.up))
        let drift = all[low] + (all[high] - all[low]) * (position - Double(low))
        return (drift, all.count)
    }

    /// The focal length whose camera rotations carry lines most faithfully, tried at
    /// `Parameters.focalLengthCandidates` × width and then 6% either side of the best.
    ///
    /// Measured against the painted horizons, this picks within ~10% of the focal length
    /// that carries painted lines best.  On ground fitted as a rotation that is the lens's:
    /// 3180 px on a9-1 10_17, where plate solving gives 3227.  On ground fitted as a 4-DOF
    /// similarity — a temp directory aligned before the rotation fit — it is an *effective*
    /// one (3660 there), because it also absorbs the small pan bias of fitting rotations to
    /// similarities (see `rotationHomography(matching:)`), and it is the carried lines that
    /// have to be right.
    /// Nil when too few pairs could be measured to trust any of them — a short sequence, or
    /// a ground that was never tracked.
    public static func calibrateFocalLength(
      lines: [Int: [Float]],
      similarityRecords: [Int: [Int: [Double]]],
      width: Int,
      height: Int,
      bandTop: Double,
      voterOrigin: Int? = nil,
      parameters: Parameters
    ) -> Calibration? {
        let frames = lines.keys.sorted()
        guard let firstLine = frames.first, let last = frames.last else { return nil }
        let first = voterOrigin ?? firstLine
        let stride = max(1, parameters.neighbourStride)
        // A whole number of strides, so the frames it lands on are voters with a line.
        let distance = min(parameters.calibrationDistance, (last - firstLine) / 2) / stride * stride
        guard distance >= 16 else { return nil }
        let onGrid = frames.filter { ($0 - first) % stride == 0 }
        // One target in `calibrationTargetStride` frames, or closer where that would leave too
        // few to measure: a short sequence still gets about sixteen.
        let every = max(1, min(parameters.calibrationTargetStride / stride, onGrid.count / 16))
        let targets = onGrid.enumerated().filter { $0.offset % every == 0 }.map(\.element)
        let hop = maxHop(of: similarityRecords)
        guard hop > 0 else { return nil }

        var tried: [Calibration.Candidate] = []
        var rejectedAt: [Double: Int] = [:]
        func measure(_ focalLength: Double) -> Calibration.Candidate {
            let converted = rotationRecords(similarityRecords, width: width, height: height,
                                            focalLength: focalLength, bandTop: bandTop,
                                            maxResidual: parameters.maxRotationResidual)
            rejectedAt[focalLength] = converted.rejected
            let measured = chainDrift(lines: lines, records: converted.records, width: width,
                                      height: height, distance: distance, targets: targets,
                                      maxHop: hop)
            let candidate = Calibration.Candidate(focalLength: focalLength, drift: measured.drift,
                                                  pairs: measured.pairs)
            tried.append(candidate)
            return candidate
        }
        func better(_ a: Calibration.Candidate, than b: Calibration.Candidate) -> Bool {
            let aUsable = a.pairs >= parameters.minimumCalibrationPairs
            let bUsable = b.pairs >= parameters.minimumCalibrationPairs
            if aUsable != bUsable { return aUsable }
            return a.drift < b.drift
        }

        var best: Calibration.Candidate? = nil
        for multiple in parameters.focalLengthCandidates {
            let candidate = measure(multiple * Double(width))
            if best.map({ better(candidate, than: $0) }) ?? true { best = candidate }
        }
        guard var chosen = best, chosen.pairs >= parameters.minimumCalibrationPairs else { return nil }
        for factor in [0.94, 1.06] {
            let candidate = measure(chosen.focalLength * factor)
            if better(candidate, than: chosen) { chosen = candidate }
        }
        let entries = similarityRecords.values.reduce(0) { $0 + $1.count }
        return Calibration(focalLength: chosen.focalLength, drift: chosen.drift,
                           distance: distance,
                           candidates: tried.sorted { $0.focalLength < $1.focalLength },
                           rejectedEntries: rejectedAt[chosen.focalLength] ?? 0,
                           entries: entries)
    }

    // MARK: - Running it

    /// Consensus lines for `targets`, from every frame's detection in `lines` (grid lines,
    /// see `gridLine`) and the stored ground fits in `similarityRecords` (frame index →
    /// neighbour index → the row-major 3x3 carrying that neighbour into the frame).
    ///
    /// The frames that vote are every `Parameters.neighbourStride`th one counted from
    /// `voterOrigin` — the sequence's first frame, so the same frames vote whichever part of
    /// it is being written — or from the first frame in `lines` when it is not given.
    ///
    /// Nil when the focal length cannot be calibrated; a target is absent when it has no
    /// detection of its own.
    public static func run(
      lines: [Int: [Float]],
      similarityRecords: [Int: [Int: [Double]]],
      targets: [Int],
      width: Int,
      height: Int,
      voterOrigin: Int? = nil,
      references: [Int: [Float]] = [:],
      parameters: Parameters = Parameters()
    ) -> Outcome? {
        guard let bandTop = bandTop(of: lines, height: height),
              let calibration = calibrateFocalLength(lines: lines,
                                                     similarityRecords: similarityRecords,
                                                     width: width, height: height,
                                                     bandTop: bandTop, voterOrigin: voterOrigin,
                                                     parameters: parameters)
        else { return nil }
        let records = rotationRecords(similarityRecords, width: width, height: height,
                                      focalLength: calibration.focalLength, bandTop: bandTop,
                                      maxResidual: parameters.maxRotationResidual).records
        let hop = maxHop(of: records)
        let frames = lines.keys.sorted()
        guard let first = voterOrigin ?? frames.first else { return nil }
        let stride = max(1, parameters.neighbourStride)
        let voters = Set(frames.filter { ($0 - first) % stride == 0 })

        // The consensus at the painted frames near a target is what each painting corrects,
        // so those go first.  A painted frame is not detected at all — its painting stands in
        // for the detection — so its consensus is its neighbours' alone.
        let reach = parameters.longSpan
        let wantedReferences = Set(references.keys.filter { painted in
            targets.contains { abs($0 - painted) <= reach }
        }).sorted()
        @Sendable func consensus(of target: Int, chain: [Int: [Double]],
                       withoutOwn: Bool = false) -> (line: [Float], overridden: Int)? {
            // NaN rows do not vote; a column no neighbour reaches stays NaN, and corrects nothing
            let own = withoutOwn ? [Float](repeating: .nan, count: parameters.gridWidth)
                                 : lines[target]
            guard let own else { return nil }
            var offsets: [Int] = []
            var carried: [[Float]] = []
            for source in (target - parameters.longSpan)...(target + parameters.longSpan)
            where source != target && voters.contains(source) {
                guard let line = lines[source], let homography = chain[source] else { continue }
                var moved = [Float](repeating: .nan, count: own.count)
                carry(line, by: homography, width: width, height: height, into: &moved)
                offsets.append(source - target)
                carried.append(moved)
            }
            var overridden = 0
            let line = consensusLine(own: own, carried: carried, offsets: offsets,
                                     height: height, parameters: parameters,
                                     overridden: &overridden)
            return (line, overridden)
        }
        let anchorResults = Results<[Float]?>(nil, count: wantedReferences.count)
        DispatchQueue.concurrentPerform(iterations: wantedReferences.count) { index in
            let painted = wantedReferences[index]
            let chain = chains(into: painted, span: parameters.longSpan,
                               records: records, maxHop: hop)
            anchorResults.set(index, consensus(of: painted, chain: chain,
                                               withoutOwn: lines[painted] == nil)?.line)
        }
        let anchorConsensus: [Int: [Float]] = {
            var found: [Int: [Float]] = [:]
            for (index, line) in anchorResults.all.enumerated() {
                if let line { found[wantedReferences[index]] = line }
            }
            return found
        }()

        // Every frame a target's smoothed line is averaged from, and the targets themselves.
        let radius = max(0, parameters.temporalSmoothingRadius)
        let hasLine = { (frame: Int) in lines[frame] != nil || references[frame] != nil }
        let targetSet = Set(targets.filter(hasLine))
        var neededSet = targetSet
        if radius > 0 {
            for target in targetSet {
                for frame in (target - radius)...(target + radius) where hasLine(frame) {
                    neededSet.insert(frame)
                }
            }
        }
        let needed = neededSet.sorted()
        let results = Results<(line: [Float], overridden: Int, corrected: Bool)?>(nil, count: needed.count)
        DispatchQueue.concurrentPerform(iterations: needed.count) { index in
            let frame = needed[index]
            // A painted frame's horizon is its painting.
            if let painting = references[frame] {
                results.set(index, (painting, 0, false))
                return
            }
            let chain = chains(into: frame, span: parameters.longSpan,
                               records: records, maxHop: hop)
            guard let (line, overridden) = consensus(of: frame, chain: chain) else { return }
            if let corrected = referenceCorrected(line, at: frame, chain: chain,
                                                  references: references,
                                                  anchorConsensus: anchorConsensus,
                                                  width: width, height: height,
                                                  parameters: parameters) {
                results.set(index, (corrected, overridden, true))
            } else {
                results.set(index, (line, overridden, false))
            }
        }
        var unsmoothed: [Int: [Float]] = [:]
        var overridden = 0
        var corrected = 0
        let finished = results.all
        for (index, frame) in needed.enumerated() {
            guard let result = finished[index] else { continue }
            unsmoothed[frame] = result.line
            guard targetSet.contains(frame) else { continue }
            overridden += result.overridden
            if result.corrected { corrected += 1 }
        }

        let wanted = targetSet.sorted().filter { unsmoothed[$0] != nil }
        let smoothed = Results<[Float]?>(nil, count: wanted.count)
        DispatchQueue.concurrentPerform(iterations: wanted.count) { index in
            let target = wanted[index]
            guard let own = unsmoothed[target] else { return }
            // a painting is the truth, and nothing is averaged into it
            if radius == 0 || references[target] != nil {
                smoothed.set(index, own)
                return
            }
            let chain = chains(into: target, span: radius, records: records, maxHop: hop)
            smoothed.set(index, temporalMean(of: unsmoothed, around: target, radius: radius,
                                             chain: chain, width: width, height: height))
        }
        var outcome: [Int: [Float]] = [:]
        for (index, line) in smoothed.all.enumerated() {
            if let line { outcome[wanted[index]] = line }
        }
        var result = Outcome(lines: outcome, calibration: calibration,
                             overriddenColumns: overridden,
                             columns: wanted.count * parameters.gridWidth)
        result.correctedTargets = corrected
        result.paintedTargets = wanted.filter { references[$0] != nil }.count
        return result
    }

    /// `target`'s line as the per-column mean of `lines` within `radius` frames of it, each
    /// carried into `target` by `chain`; a column no neighbour reaches keeps `target`'s own.
    static func temporalMean(
      of lines: [Int: [Float]],
      around target: Int,
      radius: Int,
      chain: [Int: [Double]],
      width: Int,
      height: Int
    ) -> [Float] {
        guard let own = lines[target] else { return [] }
        var sum = [Double](repeating: 0, count: own.count)
        var count = [Int](repeating: 0, count: own.count)
        var moved = [Float](repeating: .nan, count: own.count)
        for frame in (target - radius)...(target + radius) {
            guard let line = lines[frame] else { continue }
            let carried: [Float]
            if frame == target {
                carried = line
            } else {
                guard let homography = chain[frame] else { continue }
                carry(line, by: homography, width: width, height: height, into: &moved)
                carried = moved
            }
            for x in 0..<own.count where !carried[x].isNaN {
                sum[x] += Double(carried[x])
                count[x] += 1
            }
        }
        return (0..<own.count).map { x in
            count[x] > 0 ? Float(sum[x] / Double(count[x])) : own[x]
        }
    }

    /// `line`, `target`'s consensus, corrected by the painted frames either side of it.
    ///
    /// Each painted frame's correction is its painting minus its own consensus line, both
    /// carried into `target` along the same chain — what the consensus gets wrong there, in
    /// `target`'s columns.  Between two painted frames the two are blended by how near each
    /// is; past the last one, the nearest alone.  The whole correction then fades with the
    /// distance to the nearest painted frame (`Parameters.referenceCorrectionDistance`).
    /// Nil when no painted frame within reach can be carried here.
    static func referenceCorrected(
      _ line: [Float],
      at target: Int,
      chain: [Int: [Double]],
      references: [Int: [Float]],
      anchorConsensus: [Int: [Float]],
      width: Int,
      height: Int,
      parameters: Parameters
    ) -> [Float]? {
        let usable = anchorConsensus.keys.filter { chain[$0] != nil && references[$0] != nil }
        let before = usable.filter { $0 < target }.max()
        let after = usable.filter { $0 > target }.min()
        let sides = [before, after].compactMap { $0 }
        guard !sides.isEmpty else { return nil }

        func difference(_ painted: Int) -> [Float] {
            guard let homography = chain[painted], let painting = references[painted],
                  let consensus = anchorConsensus[painted]
            else { return [Float](repeating: .nan, count: line.count) }
            var carriedPainting = [Float](repeating: .nan, count: line.count)
            var carriedConsensus = [Float](repeating: .nan, count: line.count)
            carry(painting, by: homography, width: width, height: height, into: &carriedPainting)
            carry(consensus, by: homography, width: width, height: height, into: &carriedConsensus)
            return zip(carriedPainting, carriedConsensus).map { $0 - $1 }
        }
        let differences = sides.map(difference)
        let weightOfFirst: Float
        if let before, let after {
            weightOfFirst = Float(after - target) / Float(after - before)
        } else {
            weightOfFirst = 1
        }
        let nearest = sides.map { abs($0 - target) }.min() ?? 0
        let fade = Float(exp(-Double(nearest) / max(1, parameters.referenceCorrectionDistance)))

        var result = line
        for x in 0..<line.count {
            let first = differences[0][x]
            let second = differences.count > 1 ? differences[1][x] : Float.nan
            let correction: Float
            switch (first.isNaN, second.isNaN) {
            case (false, false): correction = weightOfFirst * first + (1 - weightOfFirst) * second
            case (false, true):  correction = first
            case (true, false):  correction = second
            case (true, true):   correction = 0
            }
            result[x] = min(Float(height), max(0, line[x] + fade * correction))
        }
        return result
    }

    /// What the iterations of a `concurrentPerform` hand back, one index each.
    private final class Results<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [T]

        init(_ initial: T, count: Int) {
            values = Array(repeating: initial, count: count)
        }

        func set(_ index: Int, _ value: T) {
            lock.lock()
            values[index] = value
            lock.unlock()
        }

        var all: [T] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    // MARK: - Small linear algebra

    /// Row-major 3x3 product `a · b`.
    static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: 9)
        for row in 0..<3 {
            for column in 0..<3 {
                var sum = 0.0
                for k in 0..<3 { sum += a[row * 3 + k] * b[k * 3 + column] }
                out[row * 3 + column] = sum
            }
        }
        return out
    }

    static func apply(_ h: [Double], _ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let w = h[6] * x + h[7] * y + h[8]
        return ((h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w)
    }

    /// `a · x = b` for a row-major 3x3 `a`, by Cramer's rule; nil when `a` is singular.
    static func solve3(_ a: [Double], _ b: [Double]) -> [Double]? {
        func det(_ m: [Double]) -> Double {
            m[0] * (m[4] * m[8] - m[5] * m[7])
              - m[1] * (m[3] * m[8] - m[5] * m[6])
              + m[2] * (m[3] * m[7] - m[4] * m[6])
        }
        let d = det(a)
        guard abs(d) > 1e-300, d.isFinite else { return nil }
        var x = [Double](repeating: 0, count: 3)
        for c in 0..<3 {
            var m = a
            for r in 0..<3 { m[r * 3 + c] = b[r] }
            x[c] = det(m) / d
        }
        return x
    }
}
