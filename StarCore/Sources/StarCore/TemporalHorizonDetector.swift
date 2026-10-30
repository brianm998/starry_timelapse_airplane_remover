import Foundation
import StarCppBridge
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// Finds the horizon of a fixed camera from many frames at once instead of from each frame on
/// its own.
///
/// ## Why many frames
///
/// Everything that makes a single night frame hard to read moves: the stars, the clouds, the
/// aurora, the noise.  The terrain does not.  A per-pixel median over frames spread across the
/// sequence removes all of the former and keeps the latter, sharp — the result looks like a
/// long exposure of the landscape under a smooth, starless sky.  Detecting on that one image
/// is both more accurate and far cheaper than detecting on every frame and voting:
///
///                                        per-frame vote   this
///     a7riii 08_15 (black ground, Milky Way)    15.6%     0.06%
///     lake, reflections (06_27 fixture)          1.87%    0.11%
///     conifer treeline (08_11 fixture)           1.72%    0.53%
///     open desert, five sequences           0.04-0.11%    0.03-0.15%
///
/// (mean absolute error per column against the user's painted horizon, as a percentage of
/// image height; 48 frames sampled evenly through each sequence, at 1600 px wide).  The
/// a7riii row is the failure that motivated this: on its dark Milky Way frames the shipped
/// detector put the horizon a tenth of the way down from the top, on more than half of them,
/// so the vote across frames inherited it.  The desert rows moved by one to four full-size
/// pixels either way.  The conifers are what is left: a tip one to three working pixels
/// wide reads as half sky at this size, so the line runs a few pixels inside the crowns.
///
/// ## The pipeline
///
/// 1. `workingImage(of:)` — each sampled frame area-averaged down to `workingWidth`.
/// 2. `median(of:)` — the per-pixel, per-channel median of those.
/// 3. `horizon(inClean:)` — `CombinedHorizonDetector` on the median for a first guess, then
///    `HorizonBoundaryRefiner` to follow the detail the detector smooths away.
public enum TemporalHorizonDetector {

    /// Recorded with every static merged mask this makes (`ArtifactInputs`), so bumping it
    /// rebuilds them — and, since keypoints are masked with them, everything after.  Bump
    /// it for a change that moves the masks, not for one to cost or logging.
    ///
    /// - 1: median of evenly spaced frames, `CombinedHorizonDetector` guess,
    ///      `HorizonBoundaryRefiner`.
    /// - 2: the same, then a sequence whose "ground" still holds moving stars is given no
    ///      horizon at all (`groundStarActivity`).
    public static let algorithmVersion = 2

    /// Width every frame is reduced to before the median.  The refiner's parameters are in
    /// rows of an image this wide; at 1600 a working pixel is 2.6-5 full-resolution pixels on
    /// the cameras measured, and the answer lands within about one of them.
    public static let workingWidth = 1600

    /// Full-size decodes the static horizon has in flight at once.  Each is a whole frame of
    /// memory until it is shrunk; reads are paced per volume by `IOWork` regardless.
    public static let concurrentDecodes = 4

    /// Allowance for everything after the shrink — the median, the detector and refiner at
    /// working size, the full-size mask — in megabytes.
    public static let fixedReservationMB = 300

    /// How many frames `sampleIndices` picks by default; see `Config.temporalHorizonSampleCount`.
    public static let defaultSampleCount = 48

    /// `count` frame indices spread evenly from the first frame to the last, or every frame
    /// when there are no more than that.
    public static func sampleIndices(frameCount: Int, count: Int = defaultSampleCount) -> [Int] {
        guard frameCount > 0, count > 0 else { return [] }
        guard frameCount > count else { return Array(0..<frameCount) }
        guard count > 1 else { return [frameCount / 2] }
        var indices: [Int] = []
        for i in 0..<count {
            let index = Int((Double(i) * Double(frameCount - 1) / Double(count - 1)).rounded())
            if indices.last != index { indices.append(index) }
        }
        return indices
    }

    /// `original` area-averaged down to `width` columns, aspect preserved, as 16 bits.
    /// Images already no wider keep their size.
    public static func workingImage(of original: PixelatedImage,
                                    width: Int = workingWidth) -> PixelatedImage? {
        guard original.width > width else { return original.ensure16Bits }
        let height = max(1, Int((Double(original.height) * Double(width)
                                 / Double(original.width)).rounded()))
        return original.downScaleTo(width: UInt(width), height: UInt(height))?.ensure16Bits
    }

    /// The per-pixel, per-channel median of `images`, which must all have the same size and
    /// channel count.  16-bit in, 16-bit out; nil for anything else.
    public static func median(of images: [PixelatedImage]) -> PixelatedImage? {
        guard let first = images.first else { return nil }
        let w = first.width, h = first.height, channels = first.componentsPerPixel
        // Read through the raw pointer and each mat's own row stride: `imageData`'s buffer is
        // sized without row padding, so stride-based offsets into it can run off its end.
        var buffers: [UnsafePointer<UInt16>] = []
        var strides: [Int] = []
        for image in images {
            guard image.width == w, image.height == h, image.componentsPerPixel == channels,
                  case .sixteenBit = image.imageData,
                  let raw = image.mat.dataPtr
            else {
                Log.w("TemporalHorizonDetector.median: images differ in size, channels or depth")
                return nil
            }
            buffers.append(raw.assumingMemoryBound(to: UInt16.self))
            strides.append(image.bytesPerRow / MemoryLayout<UInt16>.stride)
        }
        let n = images.count
        let rowLength = w * channels
        var output = [UInt16](repeating: 0, count: rowLength * h)
        let sources = UncheckedSendable(buffers)
        let rowStrides = strides
        withExtendedLifetime(images) {
            output.withUnsafeMutableBufferPointer { out in
                let destination = UncheckedSendable(out.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    var values = [UInt16](repeating: 0, count: n)
                    for i in 0..<rowLength {
                        for k in 0..<n {
                            values[k] = sources.value[k][y * rowStrides[k] + i]
                        }
                        destination.value[y * rowLength + i] = middle(&values)
                    }
                }
            }
        }
        return output.withUnsafeMutableBytes { bytes -> PixelatedImage? in
            guard let base = bytes.baseAddress else { return nil }
            let mat = MatWrapper(width: w, height: h,
                                 cvType: MatWrapper.cvType(forBitsPerComponent: 16,
                                                           componentsPerPixel: Int32(channels)),
                                 bytesPerRow: rowLength * MemoryLayout<UInt16>.stride,
                                 data: base,
                                 takeOwnership: false)
            return PixelatedImage(mat: mat.clone())
        }
    }

    /// The first ground row of every column of an `outputWidth` x `outputHeight` frame, found
    /// in `clean`: a temporal median of that scene at working size.
    public static func horizon(
        inClean clean: PixelatedImage,
        outputWidth: Int,
        outputHeight: Int
    ) async throws -> [Int] {
        let line = try await workingLine(inClean: clean)
        return scaled(line, fromWidth: clean.width, height: clean.height,
                      toWidth: outputWidth, height: outputHeight)
    }

    /// `horizon(inClean:outputWidth:outputHeight:)`, except that when the frames show the
    /// supposed ground to be full of moving stars it is not a horizon: every column is then
    /// all sky (`outputHeight`) and `noHorizon` is true.  `activity` is what was measured, nil
    /// when it could not be (see `groundStarActivity`).
    public static func horizon(
        inClean clean: PixelatedImage,
        sampled images: [PixelatedImage],
        outputWidth: Int,
        outputHeight: Int
    ) async throws -> (line: [Int], activity: Double?, noHorizon: Bool) {
        let line = try await workingLine(inClean: clean)
        let activity = await NativeWork.run {
            groundStarActivity(frames: images, median: clean, line: line)
        }
        if let activity, activity > maxGroundStarActivity {
            return (Array(repeating: outputHeight, count: outputWidth), activity, true)
        }
        return (scaled(line, fromWidth: clean.width, height: clean.height,
                       toWidth: outputWidth, height: outputHeight), activity, false)
    }

    /// The first ground row of every column of `clean`, at its own size.
    static func workingLine(inClean clean: PixelatedImage) async throws -> [Int] {
        let mask = try await CombinedHorizonDetector.detect(image: clean)
        let guess = CombinedHorizonDetector.extractHorizonY(from: mask.image)
        guard let logLuminance = logLuminance(of: clean) else {
            throw "TemporalHorizonDetector: clean image is not 16-bit"
        }
        let w = clean.width, h = clean.height
        return await NativeWork.run {
            HorizonBoundaryRefiner.refine(logLuminance: logLuminance, width: w, height: h,
                                          guess: guess)
        }
    }

    // MARK: - Is there a ground at all?

    /// Above this `groundStarActivity` the line is not a horizon.  Measured on the painted
    /// sequences, 48 frames at 1600 px, 16-bit, measured 2026-10-26: the conifer treeline
    /// 0.18, the lake with star reflections 0.01, the sky-only crop with a line where the
    /// detector put it (14-49% of the height) 0.68-0.92.  A count of every bright pixel, not
    /// only the positive excess, read the conifer at 0.46-0.51: its dark ground is noisy.
    public static let maxGroundStarActivity = 0.4

    /// Excess of bright over dark pixels in the sky, per frame, before `groundStarActivity`
    /// compares anything with it.
    static let minSkyStarRate = 0.002

    /// How much more often a pixel of the supposed ground holds a moving star than a pixel of
    /// the sky does, from the sampled frames: 0 for a ground that never changes between frames,
    /// 1 for one that is as full of moving stars as the sky above it.
    ///
    /// What a frame has that the median does not, with the slow remainder (cloud, glow)
    /// blurred away, is the residual.  A star is a residual more than four robust sigmas of
    /// the sky's own above zero; the median has no stars in it, so they only ever add light.
    /// Noise is as likely to subtract it, so what is counted is the excess of bright residuals
    /// over dark ones, which a dark ground full of noise does not have however much noise it
    /// has.  The terrain does not move, so below a real horizon that excess is almost nothing;
    /// on a frame that is stars all the way down, the detector still finds an edge in the Milky
    /// Way, and the ground below it has as much of it as the sky above.
    ///
    /// Columns are compared a margin away from the line either side, so the error in the
    /// line does not leak in.  Nil when there is too little ground or sky to compare, or
    /// the sky shows too few stars (`minSkyStarRate`) to measure against.
    static func groundStarActivity(frames: [PixelatedImage], median: PixelatedImage,
                                   line: [Int]) -> Double? {
        guard frames.count >= 3, line.count == median.width,
              let reference = meanLuminance(of: median) else { return nil }
        var lumas: [[Float]] = []
        for frame in frames {
            guard frame.width == median.width, frame.height == median.height,
                  let luma = meanLuminance(of: frame) else { return nil }
            lumas.append(luma)
        }
        return groundStarActivity(lumas: lumas, median: reference,
                                  width: median.width, height: median.height, line: line)
    }

    /// `groundStarActivity` on luminance arrays in [0, 1], row-major.
    static func groundStarActivity(lumas: [[Float]], median: [Float],
                                   width w: Int, height h: Int, line: [Int]) -> Double? {
        guard w > 0, h > 0, line.count == w, median.count == w * h else { return nil }
        let margin = max(4, h / 90)
        // The classes of pixels: sky is above the line by the margin, ground below by it.
        var cls = [Int8](repeating: 0, count: w * h)
        var skyCount = 0, groundCount = 0
        for x in 0..<w {
            let edge = max(0, min(h, line[x]))
            for y in 0..<h {
                if y <= edge - margin { cls[y * w + x] = 1; skyCount += 1 }
                else if y >= edge + margin { cls[y * w + x] = 2; groundCount += 1 }
            }
        }
        // Too little of either to say anything: less than 2% of the frame.
        guard skyCount > w * h / 50, groundCount > w * h / 50 else { return nil }

        // What each frame has that the median does not, minus its slow part.
        var stars: [[Float]] = []
        var skySample: [Float] = []
        for luma in lumas {
            guard luma.count == w * h else { return nil }
            var residual = [Float](repeating: 0, count: w * h)
            for i in 0..<residual.count { residual[i] = luma[i] - median[i] }
            let slow = HorizonBoundaryRefiner.gaussianBlurred(residual, width: w, height: h, sigma: 2)
            for i in 0..<residual.count { residual[i] -= slow[i] }
            var y = 0
            while y < h {
                var x = 0
                while x < w { if cls[y * w + x] == 1 { skySample.append(abs(residual[y * w + x])) }; x += 4 }
                y += 4
            }
            stars.append(residual)
        }
        skySample.sort()
        guard !skySample.isEmpty else { return nil }
        let sigma = 1.4826 * skySample[skySample.count / 2]
        guard sigma > 0 else { return nil }
        let limit = Float(4 * sigma)

        // bright minus dark, per class
        var skyExcess = 0, groundExcess = 0
        for residual in stars {
            for i in 0..<residual.count where cls[i] != 0 {
                let step = residual[i] > limit ? 1 : (residual[i] < -limit ? -1 : 0)
                if step == 0 { continue }
                if cls[i] == 1 { skyExcess += step } else { groundExcess += step }
            }
        }
        let skyRate = Double(skyExcess) / Double(skyCount * lumas.count)
        // Without real stars in the sky there is nothing to compare a ground with.  Symmetric
        // noise has no excess at all; the skies measured had 1.5-3.5%.
        guard skyRate >= minSkyStarRate else { return nil }
        let groundRate = Double(groundExcess) / Double(groundCount * lumas.count)
        return groundRate / skyRate
    }

    // MARK: - Internal pieces

    /// A row of the working image is not split by the horizon at the line the refiner returns:
    /// the first ground row of a working pixel straddling the edge is the one below the edge.
    /// Measured over the nine painted sequences, moving the line up by one working row before
    /// scaling halves the error on six of them and leaves the rest within 0.03%.
    static let rowOffset = -1.0

    /// The mean of the channels, scaled to [0, 1].  Nil unless the image is 16-bit.
    static func meanLuminance(of image: PixelatedImage) -> [Float]? {
        guard case .sixteenBit = image.imageData, let raw = image.mat.dataPtr else { return nil }
        let buffer = raw.assumingMemoryBound(to: UInt16.self)
        let w = image.width, h = image.height, channels = image.componentsPerPixel
        let stride = image.bytesPerRow / MemoryLayout<UInt16>.stride
        var luminance = [Float](repeating: 0, count: w * h)
        let scale = 1 / (65535 * Float(channels))
        withExtendedLifetime(image) {
            for y in 0..<h {
                for x in 0..<w {
                    var sum: Float = 0
                    for c in 0..<channels { sum += Float(buffer[y * stride + x * channels + c]) }
                    luminance[y * w + x] = sum * scale
                }
            }
        }
        return luminance
    }

    /// Natural log of the mean of the channels, scaled to [0, 1], after a light blur that
    /// takes the edge of single-pixel noise; 1e-4 keeps a black-clipped ground finite.
    static func logLuminance(of image: PixelatedImage) -> [Float]? {
        guard let luminance = meanLuminance(of: image) else { return nil }
        let blurred = HorizonBoundaryRefiner.gaussianBlurred(
          luminance, width: image.width, height: image.height, sigma: 0.7)
        return blurred.map { log($0 + 1e-4) }
    }

    /// `line` (first ground rows of a `fromWidth` x `fromHeight` image) at another size: each
    /// output column reads the working columns either side of its centre, linearly.
    static func scaled(_ line: [Int], fromWidth w: Int, height h: Int,
                       toWidth outW: Int, height outH: Int) -> [Int] {
        guard w > 0, h > 0, outW > 0 else { return [] }
        let xScale = Double(w) / Double(outW)
        let yScale = Double(outH) / Double(h)
        return (0..<outW).map { x in
            let source = max(0, min(Double(w - 1), (Double(x) + 0.5) * xScale - 0.5))
            let left = Int(source.rounded(.down)), right = min(w - 1, left + 1)
            let t = source - Double(left)
            let row = Double(line[left]) * (1 - t) + Double(line[right]) * t
            // A column with no ground stays without ground rather than gaining a sliver of it.
            if line[left] >= h && line[right] >= h { return outH }
            return max(0, min(outH, Int(((row + rowOffset) * yScale).rounded())))
        }
    }

    /// Median of a small array, reordered in place; the upper middle for an even count.
    private static func middle(_ values: inout [UInt16]) -> UInt16 {
        let k = values.count / 2
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
}

/// Carries raw pointers into `concurrentPerform`; each iteration reads shared input and writes
/// only its own row of the output, so there is no data race.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
