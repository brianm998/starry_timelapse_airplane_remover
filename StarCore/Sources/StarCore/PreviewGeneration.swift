import Foundation
import logging

/// One preview or thumbnail to make, run on the frame graph's preview queue like any other operation: it reserves memory for the full-size
/// frame it has to load to scale down (`OperationType.preview`'s multiplier on the working frame), so a burst of them cannot take more of the
/// machine than the budget allows, and it waits its turn behind the three the queue runs at once.
///
/// What the macOS app's `PreviewOp` does, without the view model it reloads: the client that wants a preview, and what it does when it is
/// there, is the caller's.  `completion` is told whether the image is on disk afterwards, exactly once, however the op ends (cancelled
/// before it ran, or having run).
public final class PreviewGenerationOp: AsyncOperation, @unchecked Sendable {
    private let imageAccessor: ImageAccessor
    private let frameIndex: Int
    private let mode: FrameViewMode
    private let size: ImageDisplaySize

    private let lock = NSLock()
    private var completion: (@Sendable (Bool) -> Void)?

    /// - Parameter workingFrameBytes: `Config.workingFrameBytes`.  Without it the op reserves nothing, and the memory gate has nothing
    ///   to multiply.
    public init(
      imageAccessor: ImageAccessor,
      frameIndex: Int,
      mode: FrameViewMode,
      size: ImageDisplaySize,
      workingFrameBytes: UInt64,
      completion: @escaping @Sendable (Bool) -> Void
    ) {
        self.imageAccessor = imageAccessor
        self.frameIndex = frameIndex
        self.mode = mode
        self.size = size
        self.completion = completion
        super.init(for: .preview, rawImageBytes: workingFrameBytes)
    }

    override public func asyncExecute() async {
        do {
            _ = try await imageAccessor.makeMissingImage(frameIndex: frameIndex, ofType: mode, andSize: size)
        } catch {
            Log.e("frame \(frameIndex) unable to make its \(mode) \(size) image: \(error)")
        }
    }

    /// Both ways an op ends — after `asyncExecute()`, or cancelled before it started — come through here.
    override public func finish() {
        lock.lock()
        let done = completion
        completion = nil
        lock.unlock()
        done?(imageAccessor.urlForImage(frameIndex: frameIndex, ofType: mode, atSize: size) != nil)
        super.finish()
    }
}

/// Makes previews and thumbnails through the frame graph's preview queue, once however many callers ask for the same image.
///
/// A client scrolling a grid asks for many at once, and the one it is looking at is the one that matters: a request that finds the image
/// already being made joins it (and raises it to the front if it is more urgent than the one that started it), and an image nobody is
/// waiting for any more — the callers were cancelled — is not made if it has not started.
public actor PreviewGeneration {
    public static let shared = PreviewGeneration()

    public enum Urgency: Sendable {
        /// Someone is looking at it.
        case now
        /// A pre-warm: behind everything else the queue has.
        case background

        var priority: Operation.QueuePriority { self == .now ? .veryHigh : .veryLow }
    }

    private final class Entry: @unchecked Sendable {
        let op: PreviewGenerationOp
        let path: String
        var waiters = 0
        private let lock = NSLock()
        private var result: Bool?
        private var continuations: [CheckedContinuation<Bool, Never>] = []

        init(op: PreviewGenerationOp, path: String) {
            self.op = op
            self.path = path
        }

        func complete(_ ok: Bool) {
            lock.lock()
            result = ok
            let waiting = continuations
            continuations = []
            lock.unlock()
            for c in waiting { c.resume(returning: ok) }
        }

        func wait() async -> Bool {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    continuations.append(continuation)
                    lock.unlock()
                }
            }
        }
    }

    private var inFlight: [String: Entry] = [:]

    /// Make `mode` of `frameIndex` at `size` if it is not already being made, and say whether it is on disk once that is done.
    ///
    /// Regenerates whatever is there: the callers decide whether what is on disk is stale.  `false` for a size there is no name for, and
    /// for an image that could not be made (its source is missing, or the op was cancelled before it ran).
    public func make(
      imageAccessor: ImageAccessor,
      frameIndex: Int,
      mode: FrameViewMode,
      size: ImageDisplaySize,
      workingFrameBytes: UInt64,
      urgency: Urgency
    ) async -> Bool {
        guard let path = imageAccessor.nameForImage(frameIndex: frameIndex, ofType: mode, atSize: size) else { return false }

        let entry: Entry
        if let running = inFlight[path] {
            entry = running
            if urgency == .now { running.op.queuePriority = .veryHigh }
        } else {
            let box = EntryBox()
            let op = PreviewGenerationOp(imageAccessor: imageAccessor, frameIndex: frameIndex, mode: mode, size: size,
                                         workingFrameBytes: workingFrameBytes) { ok in box.entry?.complete(ok) }
            op.queuePriority = urgency.priority
            entry = Entry(op: op, path: path)
            box.entry = entry
            inFlight[path] = entry
            await frameGraphBuilder.add(operation: op)
        }

        entry.waiters += 1
        let made = await withTaskCancellationHandler {
            await entry.wait()
        } onCancel: {
            Task { await self.waiterGaveUp(entry) }
        }
        entry.waiters -= 1
        if inFlight[path] === entry, entry.waiters <= 0 { inFlight[path] = nil }
        return made
    }

    /// A caller was cancelled: the op is not wanted if nobody else is waiting for it.  A cancelled op that has not started finishes without
    /// reserving anything or loading the frame; one that has started runs to its end, which is a moment's work.
    private func waiterGaveUp(_ entry: Entry) {
        guard entry.waiters <= 1 else { return }
        entry.op.cancel()
        // No longer there to join: a request that arrived now would be handed an op that is about to report failure.
        if inFlight[entry.path] === entry { inFlight[entry.path] = nil }
    }

    /// Lets the op's completion, which exists before its entry does, reach the entry.
    private final class EntryBox: @unchecked Sendable {
        var entry: Entry?
    }
}
