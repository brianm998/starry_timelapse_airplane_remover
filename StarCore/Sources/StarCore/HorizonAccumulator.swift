import Foundation
import logging
import StarCppBridge

/// Incrementally accumulates per-frame horizon masks for static timelapse sequences.
///
/// As each frame completes first-round horizon detection, its mask is folded into a
/// running CV_32S pixel-count matrix so that the final merge step does not need to
/// reload all masks from disk.  Any frames whose detection failed (or whose masks
/// were never registered) are loaded from disk at finalize time.
actor HorizonAccumulator {

    private let frameCount: Int

    // true for each frameIndex whose mask has been accumulated into `accum`
    private var accumulated: [Bool]

    // running per-pixel sum (CV_32S); nil until the first mask is added
    private var accum: MatWrapper?

    init(frameCount: Int) {
        self.frameCount = frameCount
        self.accumulated = [Bool](repeating: false, count: frameCount)
    }

    /// Add an in-memory horizon mask for the given frame to the running total.
    /// Safe to call multiple times for the same frame — subsequent calls are ignored.
    func accumulate(image: PixelatedImage, frameIndex: Int) {
        guard frameIndex >= 0, frameIndex < frameCount, !accumulated[frameIndex] else { return }
        accum = ImageAligner.accumulateOneHorizonMask(accum, mask: image.mat)
        accumulated[frameIndex] = true
    }

    /// Finalize the accumulation and return the binary majority-vote horizon mask.
    ///
    /// Any frames not yet accumulated are loaded from disk via `loadFilename`, which
    /// maps a frame index to the on-disk path for that frame's first-round horizon mask.
    /// Returns nil if no masks are available at all.
    func finalize(loadFilename: (Int) -> String?) -> PixelatedImage? {
        let missingFilenames = (0..<frameCount)
            .filter { !accumulated[$0] }
            .compactMap { loadFilename($0) }

        if !missingFilenames.isEmpty {
            Log.i("HorizonAccumulator: loading \(missingFilenames.count) missing horizon masks from disk")
            accum = ImageAligner.accumulateFromFiles(accum, filenames: missingFilenames)
        }

        guard let accum else {
            Log.w("HorizonAccumulator: no masks accumulated, cannot finalize")
            return nil
        }
        guard let result = ImageAligner.finalizeHorizonAccumulation(accum, totalCount: frameCount) else {
            Log.w("HorizonAccumulator: finalization returned nil")
            return nil
        }
        return PixelatedImage(mat: result)
    }
}
