import Foundation

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// Moves a rough horizon onto the real one, column by column, in a *clean* image of the scene:
/// one where a per-pixel median over time has already removed the stars, the clouds and the
/// noise, and left the terrain sharp.
///
/// ## Why a refinement and not a detector
///
/// `CombinedHorizonDetector` run on such an image is a good first guess — its error on the
/// painted sequences is a few pixels — but it cannot follow fine detail.  Its base methods
/// median-filter their curves over ±40 working columns (±470 px at full resolution) and its
/// Random Walker only searches a band around that smoothed line, so a row of conifers comes
/// back as a line through their trunks, and a hazy mountain range that is darker than the sky
/// by a few percent is cut off at its foot, where the lake below it makes a stronger edge.
/// This finds the line that best separates "sky above" from "ground below" in each column, in
/// a corridor around the guess, without smoothing anything away.
///
/// ## The model
///
/// Sky and ground are told apart by brightness *relative to the same column's own sky and
/// ground*, measured just above and just below the guess, not by any absolute level: one
/// sequence's ground is black-clipped to zero and another's is a sunlit desert brighter than
/// the next sequence's night sky, and every absolute threshold measured here failed on one of
/// them.  A pixel's sky probability is a logistic in its distance from the midpoint between
/// the two levels.
///
/// The cost of putting the horizon at row `y` of a column is then
///
/// - every *ground-like* pixel above `y`, inside the corridor (weighted `aboveWeight`), plus
/// - every *sky-like* pixel in the `groundBand` rows below `y`, minus
/// - a reward for a sharp step from bright to dark at `y`,
///
/// and a dynamic programme picks the cheapest row per column subject to a smoothness cost that
/// is capped (`jumpCost`), so a cliff or a tree can still be followed in one column.
///
/// Three properties of that cost are each load-bearing, and were each found by watching the
/// simpler version fail:
///
/// - **Only violations cost.**  Pixels that agree with a candidate line cost nothing rather
///   than earning a reward.  A reward lets a large sky-like area *below* the real horizon pull
///   the line down into it — a lake reflecting the sky did exactly that, by 11% of the frame.
///   And a small per-pixel cost on agreeing pixels is a bias towards higher lines that grows
///   with the corridor: raising `aboveWeight` with it put every line on the corridor's top.
/// - **"Everything above is sky" is enforced over the whole corridor, "ground below" only over
///   a short band.**  That asymmetry is what makes the line take the *topmost* sky-to-ground
///   transition, which is the horizon even when water or snow further down looks like sky.
///   Ground above the line is also weighted more than sky below it, because the two mistakes
///   are not equal: a tree tip called sky is smeared by the star alignment, a gap between
///   branches called ground just keeps its stars out of the merge.
/// - **The corridor.**  Without it, any patch misread as ground anywhere above the horizon — a
///   vignetted corner, a dark cloud — drags the line all the way up to it in that column.
///
/// Finally the line is raised to the top of the ground-like region connected to what is
/// already below it, which is what takes it up through a tree's crown to the tip when the
/// crown is lacy enough that its individual rows read as half sky.
///
/// Rows are *first ground row* throughout, as in `binaryHorizonMask`: rows above are sky,
/// `height` means the column has no ground at all.
enum HorizonBoundaryRefiner {

    struct Params: Sendable {
        /// How far the answer may move from the guess, as a fraction of image height.  The
        /// guess is off by up to 11% under the tallest trees measured.
        var corridorFraction: Double = 0.12

        /// The bands either side of the guess that each column's sky and ground brightness
        /// are measured over, as a fraction of image height, and the rows right next to the
        /// guess that are left out of them because the guess may be a little wrong.
        var referenceFraction: Double = 0.10
        var referenceMargin: Int = 4

        /// Columns the per-column sky and ground levels are median-filtered over, so one
        /// column whose guess was wrong borrows its levels from its neighbours.
        var referenceColumnWindow: Int = 101

        /// The logistic's width is the sky-to-ground difference divided by this, with a floor
        /// in log-luminance units for columns where the two are nearly equal.
        var scaleDivisor: Double = 4
        var minimumScale: Double = 0.05

        /// Rows below the line that are expected to be ground.
        var groundBand: Int = 20

        /// Weight of ground-like pixels above the line relative to sky-like pixels below it.
        var aboveWeight: Double = 3

        /// Reward, at full strength, for sitting on a bright-to-dark step, and the blur the
        /// step is measured through.
        var edgeWeight: Double = 20
        var edgeSigma: Double = 1.0

        /// Cost per row of column-to-column change, and the cap on it.
        var smoothness: Double = 2
        var jumpCost: Double = 60

        /// Probabilities are clipped to `[floor, 1 - floor]` so no single pixel decides.
        var probabilityFloor: Double = 0.02

        /// Pixels with a sky probability below this count as ground when raising the line
        /// through a tree's crown.
        var crownThreshold: Double = 0.5
    }

    /// The refined first ground row of every column.
    ///
    /// - Parameters:
    ///   - logLuminance: row-major log luminance, `width * height`.
    ///   - guess: the rough first ground row per column; nil where there is none.
    static func refine(
        logLuminance lm: [Float],
        width w: Int,
        height h: Int,
        guess rawGuess: [Int?],
        params: Params = Params()
    ) -> [Int] {
        precondition(lm.count == w * h && rawGuess.count == w)
        guard w > 0, h > 1 else { return [Int](repeating: h, count: w) }
        let guess = filledGuess(rawGuess, height: h)

        let (skyLevel, groundLevel) = columnLevels(lm, width: w, height: h, guess: guess, params: params)
        var sign = [Double](repeating: 1, count: w)
        var scale = [Double](repeating: params.minimumScale, count: w)
        var midpoint = [Double](repeating: 0, count: w)
        for x in 0..<w {
            let difference = skyLevel[x] - groundLevel[x]
            sign[x] = difference < 0 ? -1 : 1
            scale[x] = max(abs(difference) / params.scaleDivisor, params.minimumScale)
            midpoint[x] = (skyLevel[x] + groundLevel[x]) / 2
        }

        // Sky probability, clipped.
        let floor = params.probabilityFloor
        var probability = [Double](repeating: 0.5, count: w * h)
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                let z = sign[x] * (Double(lm[row + x]) - midpoint[x]) / scale[x]
                let p = 1 / (1 + exp(-max(-30, min(30, z))))
                probability[row + x] = max(floor, min(1 - floor, p))
            }
        }

        let radius = params.corridorFraction * Double(h)
        let edge = edgeReward(lm, width: w, height: h, sign: sign, sigma: params.edgeSigma)

        // Per column: the cost of every candidate row, then the DP across columns.
        let rows = h + 1
        var cost = [Double](repeating: 0, count: w * rows)
        var above = [Double](repeating: 0, count: rows)
        var below = [Double](repeating: 0, count: rows)
        let forbidden = 1e9
        for x in 0..<w {
            let top = max(0, min(h, Int((Double(guess[x]) - radius).rounded())))
            above[0] = 0
            below[0] = 0
            for y in 0..<h {
                let p = probability[y * w + x]
                let groundLike = y >= top ? params.aboveWeight * max(0, log(0.5 / p)) : 0
                above[y + 1] = above[y] + groundLike
                below[y + 1] = below[y] + max(0, log(0.5 / (1 - p)))
            }
            for y in 0...h {
                let index = x * rows + y
                if Double(y) < Double(guess[x]) - radius || Double(y) > Double(guess[x]) + radius {
                    cost[index] = forbidden
                    continue
                }
                let bandEnd = min(h, y + params.groundBand)
                // Row `h` is "no ground in this column", which has no step to sit on.
                let step = y < h ? Double(edge[y * w + x]) : 0
                cost[index] = above[y] + (below[bandEnd] - below[y]) - params.edgeWeight * step
            }
        }

        var line = cheapestPath(cost: cost, width: w, rows: rows,
                                smoothness: params.smoothness, jumpCost: params.jumpCost)
        line = raisedThroughConnectedGround(line, probability: probability, width: w, height: h,
                                            guess: guess, radius: radius,
                                            threshold: params.crownThreshold)
        return line
    }

    // MARK: - Pieces, internal so the tests can reach them

    /// The guess with its gaps filled from the nearest defined column; all-sky where there is
    /// nothing at all to go on.
    static func filledGuess(_ guess: [Int?], height: Int) -> [Int] {
        let defined = guess.indices.filter { guess[$0] != nil }
        guard !defined.isEmpty else { return [Int](repeating: height, count: guess.count) }
        var result = [Int](repeating: height, count: guess.count)
        var next = 0
        for x in guess.indices {
            while next + 1 < defined.count && abs(defined[next + 1] - x) <= abs(defined[next] - x) {
                next += 1
            }
            result[x] = max(0, min(height, guess[defined[next]]!))
        }
        return result
    }

    /// Each column's sky and ground brightness: medians over the bands above and below its
    /// guess, then median-filtered across columns.
    static func columnLevels(
        _ lm: [Float], width w: Int, height h: Int, guess: [Int], params: Params
    ) -> (sky: [Double], ground: [Double]) {
        let reach = params.referenceFraction * Double(h)
        var sky = [Double?](repeating: nil, count: w)
        var ground = [Double?](repeating: nil, count: w)
        var values: [Float] = []
        values.reserveCapacity(Int(reach) + 1)
        for x in 0..<w {
            let g = Double(guess[x])
            values.removeAll(keepingCapacity: true)
            for y in 0..<h where Double(y) < g - Double(params.referenceMargin) && Double(y) > g - reach {
                values.append(lm[y * w + x])
            }
            sky[x] = median(&values)
            values.removeAll(keepingCapacity: true)
            for y in 0..<h where Double(y) > g + Double(params.referenceMargin) && Double(y) < g + reach {
                values.append(lm[y * w + x])
            }
            ground[x] = median(&values)
        }
        return (medianFiltered(interpolated(sky), window: params.referenceColumnWindow),
                medianFiltered(interpolated(ground), window: params.referenceColumnWindow))
    }

    /// Bright-to-dark step at every row, scaled so the image's 99.5th percentile step is 1.
    /// `edge[y * w + x]` is the step between rows `y - 1` and `y`, oriented by the column's
    /// `sign` so that it is positive going from sky into ground.
    static func edgeReward(
        _ lm: [Float], width w: Int, height h: Int, sign: [Double], sigma: Double
    ) -> [Float] {
        let smooth = gaussianBlurred(lm, width: w, height: h, sigma: sigma)
        var edge = [Float](repeating: 0, count: w * h)
        for y in 1..<h {
            for x in 0..<w {
                let step = Double(smooth[(y - 1) * w + x] - smooth[y * w + x]) * sign[x]
                edge[y * w + x] = Float(max(0, step))
            }
        }
        var sorted = edge
        let k = min(sorted.count - 1, Int(Double(sorted.count) * 0.995))
        let scale = Double(nthElement(&sorted, k)) + 1e-9
        for i in edge.indices {
            edge[i] = Float(min(1, Double(edge[i]) / scale))
        }
        return edge
    }

    /// The minimum-cost row per column under `smoothness * |dy|`, capped at `jumpCost`.
    /// `cost[x * rows + y]`.  O(width * rows): the uncapped part is an L1 distance transform,
    /// done with two running minima instead of a search.
    static func cheapestPath(
        cost: [Double], width w: Int, rows: Int, smoothness: Double, jumpCost: Double
    ) -> [Int] {
        var total = cost
        var forward = [Double](repeating: 0, count: rows)
        var backward = [Double](repeating: 0, count: rows)
        for x in 1..<max(1, w) {
            let previous = (x - 1) * rows
            var best = Double.infinity
            for y in 0..<rows { best = min(best, total[previous + y]) }
            // forward[y] = min over y' <= y of total[y'] + smoothness * (y - y')
            var running = Double.infinity
            for y in 0..<rows {
                running = min(running + smoothness, total[previous + y])
                forward[y] = running
            }
            running = Double.infinity
            for y in stride(from: rows - 1, through: 0, by: -1) {
                running = min(running + smoothness, total[previous + y])
                backward[y] = running
            }
            let current = x * rows
            for y in 0..<rows {
                total[current + y] = cost[current + y] + min(forward[y], backward[y], best + jumpCost)
            }
        }

        var line = [Int](repeating: 0, count: w)
        let last = (w - 1) * rows
        var bestRow = 0
        for y in 0..<rows where total[last + y] < total[last + bestRow] { bestRow = y }
        line[w - 1] = bestRow
        for x in stride(from: w - 1, to: 0, by: -1) {
            let previous = (x - 1) * rows
            var nearRow = 0
            var nearCost = Double.infinity
            var anyRow = 0
            for y in 0..<rows {
                let viaStep = total[previous + y] + smoothness * Double(abs(y - line[x]))
                if viaStep < nearCost { nearCost = viaStep; nearRow = y }
                if total[previous + y] < total[previous + anyRow] { anyRow = y }
            }
            line[x - 1] = nearCost <= total[previous + anyRow] + jumpCost ? nearRow : anyRow
        }
        return line
    }

    /// The line raised, column by column, to the top of the ground-like region (sky
    /// probability below `threshold`) that is 4-connected to the ground already below it,
    /// without leaving the corridor.
    static func raisedThroughConnectedGround(
        _ line: [Int], probability: [Double], width w: Int, height h: Int,
        guess: [Int], radius: Double, threshold: Double
    ) -> [Int] {
        var reached = [Bool](repeating: false, count: w * h)
        var queue: [Int] = []
        func open(_ x: Int, _ y: Int) -> Bool {
            if y >= line[x] { return true }
            return Double(y) >= Double(guess[x]) - radius && probability[y * w + x] < threshold
        }
        // Seed with the first ground row of every column; everything below it is ground by
        // definition, so the search only ever has to climb.
        for x in 0..<w where line[x] < h {
            let index = line[x] * w + x
            reached[index] = true
            queue.append(index)
        }
        var head = 0
        while head < queue.count {
            let index = queue[head]
            head += 1
            let x = index % w, y = index / w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                let next = ny * w + nx
                if reached[next] || !open(nx, ny) { continue }
                reached[next] = true
                queue.append(next)
            }
        }
        var raised = line
        for x in 0..<w {
            var y = 0
            while y < raised[x] && !reached[y * w + x] { y += 1 }
            raised[x] = min(raised[x], y)
        }
        return raised
    }

    // MARK: - Small numeric helpers

    /// Median of `values` (reordered in place), nil when empty.
    static func median(_ values: inout [Float]) -> Double? {
        guard !values.isEmpty else { return nil }
        let n = values.count
        let upper = Double(nthElement(&values, n / 2))
        if n % 2 == 1 { return upper }
        let lower = Double(nthElement(&values, n / 2 - 1))
        return (lower + upper) / 2
    }

    /// The `k`th smallest element, with `values` partially reordered (quickselect).
    static func nthElement(_ values: inout [Float], _ k: Int) -> Float {
        var lo = 0, hi = values.count - 1
        while lo < hi {
            let pivot = values[(lo + hi) / 2]
            var i = lo, j = hi
            while i <= j {
                while values[i] < pivot { i += 1 }
                while values[j] > pivot { j -= 1 }
                if i <= j { values.swapAt(i, j); i += 1; j -= 1 }
            }
            if k <= j { hi = j } else if k >= i { lo = i } else { break }
        }
        return values[k]
    }

    /// Missing entries linearly interpolated from their defined neighbours, held flat past the
    /// ends; all zero when nothing is defined.
    static func interpolated(_ values: [Double?]) -> [Double] {
        let defined = values.indices.filter { values[$0] != nil }
        guard let first = defined.first, let last = defined.last else {
            return [Double](repeating: 0, count: values.count)
        }
        var result = [Double](repeating: 0, count: values.count)
        var segment = 0
        for x in values.indices {
            if x <= first { result[x] = values[first]!; continue }
            if x >= last { result[x] = values[last]!; continue }
            while defined[segment + 1] < x { segment += 1 }
            let a = defined[segment], b = defined[segment + 1]
            let t = Double(x - a) / Double(b - a)
            result[x] = values[a]! * (1 - t) + values[b]! * t
        }
        return result
    }

    /// Running median over `window` entries, the edges repeating the end values.
    static func medianFiltered(_ values: [Double], window: Int) -> [Double] {
        let half = max(0, window / 2)
        guard half > 0, !values.isEmpty else { return values }
        var result = values
        var buffer = [Float](repeating: 0, count: 2 * half + 1)
        for x in values.indices {
            for k in 0...(2 * half) {
                let source = max(0, min(values.count - 1, x - half + k))
                buffer[k] = Float(values[source])
            }
            result[x] = Double(nthElement(&buffer, half))
        }
        return result
    }

    /// Separable Gaussian blur with edge rows and columns repeated.
    static func gaussianBlurred(_ image: [Float], width w: Int, height h: Int, sigma: Double) -> [Float] {
        guard sigma > 0 else { return image }
        let radius = max(1, Int((3 * sigma).rounded(.up)))
        var kernel = (-radius...radius).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let sum = kernel.reduce(0, +)
        kernel = kernel.map { $0 / sum }
        var horizontal = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                var acc: Float = 0
                for k in -radius...radius {
                    acc += kernel[k + radius] * image[row + max(0, min(w - 1, x + k))]
                }
                horizontal[row + x] = acc
            }
        }
        var result = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var acc: Float = 0
                for k in -radius...radius {
                    acc += kernel[k + radius] * horizontal[max(0, min(h - 1, y + k)) * w + x]
                }
                result[y * w + x] = acc
            }
        }
        return result
    }
}
