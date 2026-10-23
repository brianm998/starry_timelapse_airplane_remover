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
    public static let algorithmVersion = 1

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
        let sources = buffers
        let rowStrides = strides
        withExtendedLifetime(images) {
            output.withUnsafeMutableBufferPointer { out in
                let destination = out.baseAddress!
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    var values = [UInt16](repeating: 0, count: n)
                    for i in 0..<rowLength {
                        for k in 0..<n {
                            values[k] = sources[k][y * rowStrides[k] + i]
                        }
                        destination[y * rowLength + i] = middle(&values)
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
        let mask = try await CombinedHorizonDetector.detect(image: clean)
        let guess = CombinedHorizonDetector.extractHorizonY(from: mask.image)
        guard let logLuminance = logLuminance(of: clean) else {
            throw "TemporalHorizonDetector: clean image is not 16-bit"
        }
        let w = clean.width, h = clean.height
        let line = await NativeWork.run {
            HorizonBoundaryRefiner.refine(logLuminance: logLuminance, width: w, height: h,
                                          guess: guess)
        }
        return scaled(line, fromWidth: w, height: h, toWidth: outputWidth, height: outputHeight)
    }

    // MARK: - Internal pieces

    /// A row of the working image is not split by the horizon at the line the refiner returns:
    /// the first ground row of a working pixel straddling the edge is the one below the edge.
    /// Measured over the nine painted sequences, moving the line up by one working row before
    /// scaling halves the error on six of them and leaves the rest within 0.03%.
    static let rowOffset = -1.0

    /// Natural log of the mean of the channels, scaled to [0, 1], after a light blur that
    /// takes the edge of single-pixel noise; 1e-4 keeps a black-clipped ground finite.
    static func logLuminance(of image: PixelatedImage) -> [Float]? {
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
        let blurred = HorizonBoundaryRefiner.gaussianBlurred(luminance, width: w, height: h, sigma: 0.7)
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
