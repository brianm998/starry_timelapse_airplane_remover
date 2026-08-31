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

    /// True while `finalize` is running.
    ///
    /// `finalize` hands its two heavy passes to `NativeWork`, so it suspends
    /// between reading `accum` and writing the result back.  Actors are
    /// reentrant, so without this a mask arriving in that window would be folded
    /// into a value that is about to be overwritten, and would vanish silently.
    /// Rejecting it says so in the log instead — and by the time the merge is
    /// being finalised, a mask this late was not going to be included anyway.
    private var isFinalizing = false

    init(frameCount: Int) {
        self.frameCount = frameCount
        self.accumulated = [Bool](repeating: false, count: frameCount)
    }

    /// Add an in-memory horizon mask for the given frame to the running total.
    /// Safe to call multiple times for the same frame — subsequent calls are ignored.
    func accumulate(image: PixelatedImage, frameIndex: Int) {
        guard !isFinalizing else {
            Log.w("HorizonAccumulator: frame \(frameIndex) mask arrived during finalize, not accumulated")
            return
        }
        guard frameIndex >= 0, frameIndex < frameCount, !accumulated[frameIndex] else { return }
        accum = ImageAligner.accumulateOneHorizonMask(accum, mask: image.mat)
        accumulated[frameIndex] = true
    }

    /// Finalize the accumulation and return the binary majority-vote horizon mask.
    ///
    /// Any frames not yet accumulated are loaded from disk via `loadFilename`, which
    /// maps a frame index to the on-disk path for that frame's first-round horizon mask.
    /// Returns nil if no masks are available at all.
    func finalize(loadFilename: (Int) -> String?) async -> PixelatedImage? {
        // `loadFilename` is called here, before any suspension: it is a plain
        // index-to-path mapping and is not Sendable.
        let missingFilenames = (0..<frameCount)
            .filter { !accumulated[$0] }
            .compactMap { loadFilename($0) }

        isFinalizing = true
        defer { isFinalizing = false }

        if !missingFilenames.isEmpty {
            Log.i("HorizonAccumulator: loading \(missingFilenames.count) missing horizon masks from disk")
            // Reads every missing mask off disk and folds them in — off the
            // cooperative pool, like the rest of the native work.
            let running = accum
            accum = await NativeWork.run {
                ImageAligner.accumulateFromFiles(running, filenames: missingFilenames)
            }
        }

        guard let accum else {
            Log.w("HorizonAccumulator: no masks accumulated, cannot finalize")
            return nil
        }
        let total = frameCount
        guard let result = await NativeWork.run({
                  ImageAligner.finalizeHorizonAccumulation(accum, totalCount: total)
              })
        else {
            Log.w("HorizonAccumulator: finalization returned nil")
            return nil
        }
        return PixelatedImage(mat: result)
    }
}
