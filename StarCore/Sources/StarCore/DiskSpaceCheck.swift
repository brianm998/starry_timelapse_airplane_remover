import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// Whether there is room for what a run is about to write, checked before it starts.
///
/// Running out of disk halfway through a long sequence is a bad failure even now that it is
/// reported: the frames written before it happened are fine, the ones after are missing, and
/// the user finds out an hour in. The information needed to see it coming is available in
/// advance and costs a `stat` per input file to gather.
///
/// The estimate is deliberately based on the **size of the input files** rather than on pixel
/// arithmetic. star writes its output in the same format as the input — the output filename
/// keeps the input's extension, and `cv::imwrite` picks the encoder from it — so the input
/// size already accounts for bit depth, channel count and whatever compression the format
/// applies. Computing `width × height × bytesPerPixel` instead would be wildly wrong in both
/// directions: 8× too high for JPEG input, and too low for anything that grows.
public enum DiskSpaceCheck {

    /// Peak disk use over a run, as a multiple of the input sequence's size.
    ///
    /// Measured, not guessed: a 19-frame 4240×2832 sequence of 45.4MB produced 51.5MB of
    /// output (1.14×) and 135.7MB of temp working files (2.99×) — 4.13× in total. The temp
    /// directory is the larger half and is dominated by `auto-processed` and `aligned`, each
    /// roughly one full copy of the sequence, plus `keypoints` at about two thirds.
    ///
    /// Peak rather than final: temp is deleted when a run finishes cleanly, but it coexists
    /// with the output while the run is going, so the high-water mark is what has to fit.
    ///
    /// Rounded down to 4.0, because this is a threshold for a warning rather than a
    /// reservation, and the cost of a false alarm is a user being told to free space they did
    /// not strictly need.
    public static let peakToInputRatio: Double = 4.0

    /// The result of comparing an estimate against what is free.
    public struct Estimate: Sendable, Equatable {
        /// Total size of the input sequence's files.
        public let inputBytes: UInt64
        /// `inputBytes × peakToInputRatio` — the high-water mark this run is expected to need.
        public let estimatedPeakBytes: UInt64
        /// What the output volume reports as free.
        public let availableBytes: UInt64

        public var fits: Bool { availableBytes >= estimatedPeakBytes }

        /// How much more would be needed, zero when it fits.
        public var shortfallBytes: UInt64 {
            fits ? 0 : estimatedPeakBytes - availableBytes
        }
    }

    public static func estimate(inputBytes: UInt64, availableBytes: UInt64) -> Estimate {
        Estimate(inputBytes: inputBytes,
                 estimatedPeakBytes: UInt64(Double(inputBytes) * peakToInputRatio),
                 availableBytes: availableBytes)
    }

    // MARK: - Probing

    /// Total size of the given files. Files that cannot be stat'd contribute nothing.
    public static func totalSize(ofFiles paths: [String]) -> UInt64 {
        var total: UInt64 = 0
        for path in paths {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber
            else { continue }
            total += size.uint64Value
        }
        return total
    }

    /// Free space on the volume holding `path`, or nil if it cannot be determined.
    ///
    /// Walks up to the nearest existing ancestor first: the output directory usually does not
    /// exist yet when this runs, and asking about a path that is not there returns nothing.
    ///
    /// Prefers `volumeAvailableCapacityForImportantUsage`, which on Darwin is the honest
    /// number — it accounts for purgeable space the system would reclaim for a real write,
    /// whereas the plain capacity key under-reports. That key is Darwin-only, so the plain
    /// one is the fallback everywhere else.
    public static func availableBytes(forPath path: String) -> UInt64? {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            // deletingLastPathComponent on "/" returns "/", so this would spin forever.
            if parent.path == url.path { break }
            url = parent
        }

        #if canImport(Darwin)
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let important = values.volumeAvailableCapacityForImportantUsage,
           important > 0
        {
            return UInt64(important)
        }
        #endif

        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let available = values.volumeAvailableCapacity,
           available > 0
        {
            return UInt64(available)
        }

        return nil
    }

    // MARK: - The check

    private static func gb(_ bytes: UInt64) -> String { bytes.humanReadableBytes }

    /// Estimate what this run needs against what the output volume has, and warn if it does
    /// not obviously fit.
    ///
    /// A warning and not a refusal. The ratio is an average over one measured sequence, the
    /// input may compress differently, and the user may be about to free space or may simply
    /// know better. Refusing to start on the strength of an estimate would be worse than the
    /// problem — but saying nothing is how a run gets an hour in and then cannot write.
    ///
    /// - Returns: the estimate, or nil when free space could not be determined at all.
    @discardableResult
    public static func check(inputFiles: [String], outputPath: String) async -> Estimate? {
        let inputBytes = totalSize(ofFiles: inputFiles)
        guard inputBytes > 0 else { return nil }

        guard let availableBytes = availableBytes(forPath: outputPath) else {
            Log.d("could not determine free space for \(outputPath), skipping the disk check")
            return nil
        }

        let estimate = estimate(inputBytes: inputBytes, availableBytes: availableBytes)

        Log.i("disk space: input \(gb(inputBytes)), " +
              "estimated peak \(gb(estimate.estimatedPeakBytes)), " +
              "available \(gb(availableBytes))")

        if !estimate.fits {
            await StarWarnings.shared.post(StarWarning(
              kind: .lowDiskSpace,
              severity: .critical,
              message: "This run is estimated to need about " +
                       "\(gb(estimate.estimatedPeakBytes)) of disk space, and only " +
                       "\(gb(availableBytes)) is free. It will probably run out before it " +
                       "finishes.",
              suggestion: "Free about \(gb(estimate.shortfallBytes)) and start again, or send " +
                          "the output somewhere with more room. The estimate covers both the " +
                          "output and the temporary working files, which exist at the same time."
            ))
        }

        return estimate
    }
}
