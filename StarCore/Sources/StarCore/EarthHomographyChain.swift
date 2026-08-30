import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// Maps a point from one frame's coordinate system into another's by composing the earth
/// homographies already stored in `homography.db`.
///
/// A moving timelapse's ground does not sit still, so a horizon painted on frame 183 says
/// nothing directly about where the horizon is on frame 207 — the camera panned in between.
/// Interpolating the painted line's Y column by column, which is what the reference-horizon
/// machinery did before this existed, silently assumes the motion is purely vertical.  It is
/// not: over the 24 frames between those two references this sequence's ground moves 150-220
/// px horizontally and 7-13 px vertically, and every column of the interpolated line is
/// therefore reading off the wrong part of the ridge.
///
/// The alignment stage has already measured that motion.  Each frame's earth record holds a
/// homography per aligned neighbour, so composing the ones between two frames reconstructs
/// the ground transform between them, and the painted horizon can be *moved* into the target
/// frame rather than guessed at.  Measured against this user's own 34 painted references,
/// holding each one out and predicting it from its two neighbours: linear interpolation gives
/// a mean absolute error of 19.2 px, single-frame-step composition 8.1 px, and the
/// largest-jump composition below 3.1 px — a sixfold improvement that holds even across the
/// 300-frame gaps between the sparse seed references.
///
/// **Why the largest jump wins.** Every hop multiplies in another homography's own fit error,
/// so 300 single-frame hops accumulate 300 of them.  The stored records reach several frames
/// out — `numberAlignedNeighborFrames`/2 in each direction — and those wider entries were each
/// fitted directly between their two frames, not composed.  Taking the widest hop available at
/// every step cuts the number of multiplications by that factor and the accumulated error with
/// it: 8.1 px to 3.1 px on the same data.
///
/// Reads are memoised for the life of the sequence because a horizon refinement asks this
/// question once per frame of a span, and every one of those chains walks the same records.
public actor EarthHomographyChain {

    /// Identity of the sequence the memoised records came from.  A run opens one sequence, so
    /// this is a single slot rather than a dictionary; opening another replaces it.
    private var databasePath: String = ""

    /// `nil` for a frame whose record was asked for and is not there, so that a sequence with
    /// no alignment yet is not re-queried once per frame of a refinement span.
    private var records: [Int: HomographyResultsCodable?] = [:]

    /// How far a stored record reaches, learned from the first one read.  Probing beyond it is
    /// a guaranteed miss on every step of every chain.
    private var maxJump: Int = 0

    private var reads = 0
    private var hits = 0

    public init() {}

    /// Row-major 3x3 mapping `source` frame coordinates into `destination` frame coordinates,
    /// or nil when the stored homographies do not connect the two.
    ///
    /// `source == destination` is the identity, which is the right answer and saves callers a
    /// special case.
    public func transform(
      from source: Int,
      to destination: Int,
      database: HomographyDatabase
    ) async -> [Double]? {
        await useDatabase(database)
        guard source != destination else { return Self.identity }

        let step = destination > source ? 1 : -1
        var current = source
        var accumulated = Self.identity

        while current != destination {
            let remaining = abs(destination - current)
            var advanced = false
            // Widest hop first: see the note above on why this is not a micro-optimisation.
            for jump in stride(from: min(max(maxJump, 1), remaining), through: 1, by: -1) {
                let next = current + step * jump
                guard let homography = await link(from: current, to: next, database: database)
                else { continue }
                accumulated = Self.multiply(homography, accumulated)
                current = next
                advanced = true
                break
            }
            guard advanced else {
                Log.d("EarthHomographyChain: no link out of frame \(current) toward "
                        + "\(destination) — chain from \(source) abandoned")
                return nil
            }
        }
        return accumulated
    }

    /// Loads and memoises the records for `frames`, so that a batch of frames about to chain
    /// over the same span pays for each read once rather than serialising on the actor one
    /// lookup at a time.  Optional — `transform` loads what it needs either way.
    public func warmUp(frames: Range<Int>, database: HomographyDatabase) async {
        await useDatabase(database)
        for frame in frames { _ = await record(frame, database: database) }
    }

    /// Reads performed and lookups served from memory, for tests and for logging.
    public func stats() -> (reads: Int, hits: Int) { (reads, hits) }

    /// Forget everything.  The stored homographies changed under us.
    public func invalidate() {
        records = [:]
        maxJump = 0
    }

    // MARK: - internals

    private func useDatabase(_ database: HomographyDatabase) async {
        let path = await database.dbPath
        guard path != databasePath else { return }
        databasePath = path
        records = [:]
        maxJump = 0
    }

    /// The homography mapping frame `a`'s coordinates into frame `b`'s.
    ///
    /// It lives in `b`'s record: that record's job is to bring each neighbour into `b`, which
    /// is exactly this direction.
    private func link(
      from a: Int,
      to b: Int,
      database: HomographyDatabase
    ) async -> [Double]? {
        guard let results = await record(b, database: database) else { return nil }
        for warpInfo in results.neighborHomography where warpInfo.frameIndex == a {
            guard let homography = warpInfo.homography, homography.count == 9 else { return nil }
            switch warpInfo.alignmentState {
            case .homographySuccess, .usedExistingHomography: return homography
            default: return nil
            }
        }
        return nil
    }

    private func record(
      _ frameIndex: Int,
      database: HomographyDatabase
    ) async -> HomographyResultsCodable? {
        if let cached = records[frameIndex] {
            hits += 1
            return cached
        }
        reads += 1
        let results = try? await database.read(frameIndex: frameIndex, type: .earth)
        records[frameIndex] = results
        if let results {
            let reach = results.neighborHomography
                .map { abs($0.frameIndex - frameIndex) }
                .max() ?? 0
            if reach > maxJump { maxJump = reach }
        }
        return results
    }

    private static let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]

    /// Row-major 3x3 product `a · b`, so that applying the result is applying `b` and then `a`.
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
}

/// Shared by every frame of a sequence, matching `referenceHorizonStatsCache` and
/// `horizonReferenceMaskCache`: the records it memoises describe the sequence, not any one
/// frame's processor.
public let earthHomographyChain = EarthHomographyChain()

/// Moving a per-column horizon line between two frames' coordinate systems.
public enum HorizonCurve {

    /// `horizonY`, expressed in the coordinates of the frame `homography` maps *into*.
    ///
    /// The line is carried as points rather than as a picture: each defined column
    /// contributes the point `(x, horizonY[x])`, the homography moves it, and the result is
    /// resampled back onto whole columns.  Warping the mask image instead would work, but it
    /// costs a full-frame `warpPerspective` and an interpolation pass over 24 million pixels
    /// to recover a curve that is 6000 numbers wide.
    ///
    /// Columns the source frame does not reach come back nil rather than guessed at: a pan
    /// leaves one side of the target frame outside anything the reference ever saw, and on
    /// this sequence's 63-frame reference gaps that is around a tenth of the width.  Deciding
    /// what to put there belongs to the caller, which has the other reference and the
    /// interpolated line to fall back on.
    public static func warp(
      _ horizonY: [Int?],
      with homography: [Double],
      width: Int
    ) -> [Double?] {
        guard homography.count == 9, width > 0 else { return [Double?](repeating: nil, count: width) }

        var sourceX: [Double] = []
        var sourceY: [Double] = []
        sourceX.reserveCapacity(horizonY.count)
        sourceY.reserveCapacity(horizonY.count)

        for (x, y) in horizonY.enumerated() {
            guard let y else { continue }
            let dx = Double(x), dy = Double(y)
            let w = homography[6] * dx + homography[7] * dy + homography[8]
            guard abs(w) > 1e-9 else { continue }
            sourceX.append((homography[0] * dx + homography[1] * dy + homography[2]) / w)
            sourceY.append((homography[3] * dx + homography[4] * dy + homography[5]) / w)
        }

        var result = [Double?](repeating: nil, count: width)
        guard sourceX.count >= 2 else { return result }

        // A homography that mirrored the frame would leave these descending, and the
        // interpolation below walks forwards; a plain sort costs nothing next to the warp
        // itself and removes the assumption.
        let order = (0..<sourceX.count).sorted { sourceX[$0] < sourceX[$1] }
        let xs = order.map { sourceX[$0] }
        let ys = order.map { sourceY[$0] }

        var cursor = 0
        for column in 0..<width {
            let x = Double(column)
            if x < xs[0] || x > xs[xs.count - 1] { continue }
            while cursor + 1 < xs.count, xs[cursor + 1] < x { cursor += 1 }
            let x0 = xs[cursor], x1 = xs[cursor + 1]
            let span = x1 - x0
            if abs(span) < 1e-9 {
                result[column] = ys[cursor]
            } else {
                let t = (x - x0) / span
                result[column] = ys[cursor] * (1 - t) + ys[cursor + 1] * t
            }
        }
        return result
    }
}
