import Foundation
import logging

/// Finishes when one frame of a video that is still being extracted is on disk.
///
/// An op that reads a frame's original depends on this, so it is not started (and holds no concurrency slot or memory reservation)
/// before its frame exists.  The wait is the source's callback, not a thread: nothing is parked.  This is a dependency that
/// finishes, never an `isReady` that changes: a readiness answer that changes with no KVO notification latches the op not-ready
/// for ever (see `KeypointLimiter`).
///
/// Not an `AsyncOperation`: it takes no memory, runs no work, and is on a queue of its own (never the frame queue, where a wait on
/// ffmpeg would hold one of `maxConcurrentOperationCount`'s slots).  It also finishes when the frame can never arrive, so that the
/// ops behind it start and report the missing frame themselves rather than waiting for ever.
final class FrameAvailableOp: Operation, @unchecked Sendable {
    let frameIndex: Int
    private let source: FrameSource
    private let lock = NSLock()
    private var executingFlag = false
    private var finishedFlag = false
    private var token: FrameWaitToken?

    init(frameIndex: Int, source: FrameSource) {
        self.frameIndex = frameIndex
        self.source = source
        super.init()
        name = "frame \(frameIndex) available"
    }

    override var isAsynchronous: Bool { true }
    override var isExecuting: Bool { lock.lock(); defer { lock.unlock() }; return executingFlag }
    override var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finishedFlag }

    override func start() {
        if isCancelled { finishOp(); return }
        setExecuting(true)
        let registered = source.whenAvailable(frameIndex) { [weak self] result in
            if case .failure(let error) = result, !(error is CancellationError) {
                Log.w("frame \(self?.frameIndex ?? -1) will not be extracted: \(error.localizedDescription)")
            }
            self?.finishOp()
        }
        lock.lock()
        token = registered
        let alreadyDone = finishedFlag
        lock.unlock()
        if alreadyDone { registered.cancel() }
    }

    override func cancel() {
        super.cancel()
        lock.lock()
        let held = token
        lock.unlock()
        // One that never started is started by the queue, which sees the cancellation and finishes it.
        held?.cancel()
    }

    private func setExecuting(_ value: Bool) {
        willChangeValue(forKey: "isExecuting")
        lock.lock(); executingFlag = value; lock.unlock()
        didChangeValue(forKey: "isExecuting")
    }

    private func finishOp() {
        lock.lock()
        if finishedFlag { lock.unlock(); return }
        lock.unlock()
        willChangeValue(forKey: "isExecuting")
        willChangeValue(forKey: "isFinished")
        lock.lock()
        executingFlag = false
        finishedFlag = true
        token = nil
        lock.unlock()
        didChangeValue(forKey: "isExecuting")
        didChangeValue(forKey: "isFinished")
    }
}

extension FrameGraphBuilder {

    /// Makes every op that reads a frame's original wait for that frame to be extracted, when the sequence's frames are still
    /// arriving.  For an image sequence, or a video that is fully extracted, this adds nothing: those graphs stay exactly as they
    /// were.
    ///
    /// Which originals an op reads: a horizon detection and a keypoint op, its own frame; the alignment and the final merge, its
    /// own and its neighbours' (a neighbour whose keypoints are cached still has its original read on the fallback path, and the
    /// merge reads every neighbour); the static temporal horizon, the frames it samples.  The rest read only what those wrote.
    ///
    /// - Returns: the availability ops, which the caller enqueues on `frameAvailabilityQueue`.
    func addFrameAvailabilityDependencies(
      to ops: [Operation],
      source: FrameSource,
      neighbours: [Int: [Int]],
      sampledFrames: [Int],
      sampledBy staticSampler: Operation?
    ) -> [FrameAvailableOp] {
        if source.progress.isComplete { return [] }
        var made: [Int: FrameAvailableOp] = [:]

        func need(_ indices: [Int], for op: Operation) {
            for index in Set(indices) where index >= 0 && index < source.frameCount && !source.isAvailable(index) {
                let gate: FrameAvailableOp
                if let existing = made[index] {
                    gate = existing
                } else {
                    gate = FrameAvailableOp(frameIndex: index, source: source)
                    made[index] = gate
                }
                op.addDependency(gate)
            }
        }

        for op in ops {
            switch op {
            case let op as HorizonDetectionOp: need([op.frame.frameIndex], for: op)
            case let op as KeypointOp:         need([op.frame.frameIndex], for: op)
            case let op as HomographyOp:
                let index = op.frame.frameIndex
                need([index] + (neighbours[index] ?? []), for: op)
            case let op as OutlierOp:
                let index = op.frame.frameIndex
                need([index] + (neighbours[index] ?? []), for: op)
            case let op as MergeOp:
                let index = op.frame.frameIndex
                need([index] + (neighbours[index] ?? []), for: op)
            default:
                if op === staticSampler { need(sampledFrames, for: op) }
            }
        }
        if !made.isEmpty {
            Log.i("waiting on \(made.count) frame(s) that are still being extracted")
        }
        return Array(made.values)
    }
}
