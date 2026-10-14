import Foundation
import StarCore
import logging

/// Makes the thumbnails and previews a client is about to ask for, in the background, once a sequence is open (what the macOS app does as
/// it loads: a task at utility priority that queues a very low priority operation for every image that has an original and no preview).
///
/// Thumbnails first, since they are what a grid or filmstrip draws all at once, then the previews, frame by frame.  Everything goes through
/// the same memory-gated preview queue an on-demand request does, behind it: a request for an image the pre-warm has queued but not
/// started takes its place at the front.
enum PreviewPrewarm {

    /// How many are asked for at once.  The queue itself runs three, so one more keeps it fed without piling up requests.
    static let concurrency = 4

    struct Job: Sendable {
        let accessor: ImageAccessor
        let frameIndex: Int
        let mode: FrameViewMode
        let size: ImageDisplaySize
    }

    /// What is worth making for `frames`, in the order to make it: the original's thumbnail for each frame that has none, then every
    /// preview that has an original to be made from and is not there yet.  Only stats the disk.
    static func jobs(for frames: [FrameAirplaneRemover]) -> [Job] {
        var thumbnails: [Job] = []
        var previews: [Job] = []
        for frame in frames {
            let accessor = frame.imageAccessor
            let index = frame.frameIndex
            if accessor.urlForImage(frameIndex: index, ofType: .original, atSize: .original) != nil,
               accessor.urlForImage(frameIndex: index, ofType: .original, atSize: .thumbnail) == nil
            {
                thumbnails.append(Job(accessor: accessor, frameIndex: index, mode: .original, size: .thumbnail))
            }
            for mode in FrameViewMode.allCases
            where accessor.urlForImage(frameIndex: index, ofType: mode, atSize: .original) != nil
                    && accessor.urlForImage(frameIndex: index, ofType: mode, atSize: .preview) == nil
            {
                previews.append(Job(accessor: accessor, frameIndex: index, mode: mode, size: .preview))
            }
        }
        return thumbnails + previews
    }

    /// Run until every job is done or the calling task is cancelled.
    static func run(frames: [FrameAirplaneRemover]) async {
        guard let first = frames.first else { return }
        let jobs = jobs(for: frames)
        guard !jobs.isEmpty else { return }
        let unit = await first.configManager.config().workingFrameBytes
        Log.i("stard: making \(jobs.count) missing previews and thumbnails in the background")

        let cursor = Cursor(count: jobs.count)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrency {
                group.addTask {
                    while !Task.isCancelled, let next = cursor.next() {
                        let job = jobs[next]
                        _ = await PreviewGeneration.shared.make(
                            imageAccessor: job.accessor, frameIndex: job.frameIndex, mode: job.mode, size: job.size,
                            workingFrameBytes: unit, urgency: .background)
                    }
                }
            }
        }
        Log.i(Task.isCancelled ? "stard: background preview generation stopped" : "stard: background preview generation done")
    }

    /// Hands out 0..<count once each, to whichever worker asks.
    private final class Cursor: @unchecked Sendable {
        private let lock = NSLock()
        private var position = 0
        private let count: Int
        init(count: Int) { self.count = count }
        func next() -> Int? {
            lock.lock(); defer { lock.unlock() }
            guard position < count else { return nil }
            defer { position += 1 }
            return position
        }
    }
}
