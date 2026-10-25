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

    // how many masks are actually in `accum`. The majority vote is against THIS, not against
    // `frameCount`: a partial run (`star -L 9`) or a sequence with masks missing folds in fewer
    // masks than there are frames, and voting against the frame count put the threshold above
    // anything the folded masks could reach, so every pixel came out as ground.
    private var foldedCount = 0

    /// True while `finalize` is running.
    ///
    /// `finalize` hands its two heavy passes to `NativeWork`, so it suspends
    /// between reading `accum` and writing the result back.  Actors are
    /// reentrant, so without this a mask arriving in that window would be folded
    /// into a value that is about to be overwritten, and would vanish silently.
    /// Rejecting it says so in the log instead — and by the time the merge is
    /// being finalised, a mask this late was not going to be included anyway.
    private var isFinalizing = false

    /// Serialises everything that touches `accum`. The in-place accumulate and the finalize both
    /// hand `accum` to native threads while the actor is free to run other calls, so two of them
    /// at once would add into the same buffer concurrently. FIFO, so a finalize runs only after
    /// every accumulate that was accepted before it.
    private var busy = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireGate() async {
        if busy {
            await withCheckedContinuation { gateWaiters.append($0) }
        } else {
            busy = true
        }
    }

    private func releaseGate() {
        if gateWaiters.isEmpty {
            busy = false
        } else {
            gateWaiters.removeFirst().resume()  // ownership passes straight to the next waiter
        }
    }

    init(frameCount: Int) {
        self.frameCount = frameCount
        self.accumulated = [Bool](repeating: false, count: frameCount)
    }

    /// Add an in-memory horizon mask for the given frame to the running total.
    /// Safe to call multiple times for the same frame — subsequent calls are ignored.
    func accumulate(image: PixelatedImage, frameIndex: Int) async {
        guard !isFinalizing else {
            Log.w("HorizonAccumulator: frame \(frameIndex) mask arrived during finalize, not accumulated")
            return
        }
        guard frameIndex >= 0, frameIndex < frameCount, !accumulated[frameIndex] else { return }
        // Claimed before the first suspension so a second call for this frame is ignored.
        accumulated[frameIndex] = true

        await acquireGate()
        defer { releaseGate() }

        // Off the cooperative pool: the add touches the whole full-resolution total.
        let running = accum
        let mat = image.mat
        let updated = await NativeWork.run {
            ImageAligner.accumulateOneHorizonMask(running, mask: mat)
        }
        if let updated {
            accum = updated
            foldedCount += 1
        } else {
            // Keep the running total rather than replacing it with nothing, and let finalize
            // load this frame from disk instead.
            accumulated[frameIndex] = false
            Log.w("HorizonAccumulator: frame \(frameIndex) could not be accumulated, leaving it for finalize")
        }
    }

    /// Finalize the accumulation and return the binary majority-vote horizon mask.
    ///
    /// Any frames not yet accumulated are loaded from disk via `loadFilename`, which
    /// maps a frame index to the on-disk path for that frame's first-round horizon mask.
    /// Returns nil if no masks are available at all.
    func finalize(loadFilename: (Int) -> String?) async -> PixelatedImage? {
        // Behind every accumulate already accepted (they hold or wait on the gate), so the
        // running total is complete before it is read.
        await acquireGate()
        defer { releaseGate() }

        // `loadFilename` is called here, before any further suspension: it is a plain
        // index-to-path mapping and is not Sendable.
        let missing: [(frameIndex: Int, filename: String)] = (0..<frameCount)
            .filter { !accumulated[$0] }
            .compactMap { index in loadFilename(index).map { (index, $0) } }
        let missingFilenames = missing.map { $0.filename }

        isFinalizing = true
        defer { isFinalizing = false }

        if !missingFilenames.isEmpty {
            Log.i("HorizonAccumulator: loading \(missingFilenames.count) missing horizon masks from disk")
            // Reads every missing mask off disk and folds them in — off the
            // cooperative pool, like the rest of the native work.
            let running = accum
            let outcome = await NativeWork.run {
                ImageAligner.accumulateFromFiles(running, filenames: missingFilenames)
            }
            // A failed call keeps the previous total instead of replacing it with nothing.
            if let total = outcome.total {
                accum = total
                for (position, wasLoaded) in outcome.loaded.enumerated() where wasLoaded {
                    accumulated[missing[position].frameIndex] = true
                    foldedCount += 1
                }
                let skipped = outcome.loaded.filter { !$0 }.count
                if skipped > 0 {
                    Log.w("HorizonAccumulator: \(skipped) horizon masks were not on disk and are not in the vote")
                }
            } else {
                Log.w("HorizonAccumulator: loading the missing masks failed; voting without them")
            }
        }

        guard let accum else {
            Log.w("HorizonAccumulator: no masks accumulated, cannot finalize")
            return nil
        }
        guard foldedCount > 0 else {
            Log.w("HorizonAccumulator: no masks were folded in, cannot finalize")
            return nil
        }
        let total = foldedCount
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
