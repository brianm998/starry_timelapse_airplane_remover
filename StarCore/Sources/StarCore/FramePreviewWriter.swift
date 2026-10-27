import Foundation
import logging

/// Writes each frame's preview and thumbnail as the frame is extracted, so a filmstrip fills in while a video is still arriving.
///
/// What `ImageAccessor.writeMissingImages(_:)` does for a whole sequence once, frame by frame as they land, on a low priority and
/// a couple at a time.  The whole-sequence sweep skips frames that are not there yet, so the two never wait on each other.
public final class FramePreviewWriter: @unchecked Sendable {
    private let source: FrameSource
    private let imageAccessor: ImageAccessor
    private let onFrame: @Sendable (Int) async -> Void
    private let concurrency: Int
    private var task: Task<Void, Never>?
    private let lock = NSLock()

    /// - Parameter onFrame: told when a frame's previews are written, for a client to refresh what it shows.
    public init(source: FrameSource,
                imageAccessor: ImageAccessor,
                concurrency: Int = 2,
                onFrame: @escaping @Sendable (Int) async -> Void = { _ in }) {
        self.source = source
        self.imageAccessor = imageAccessor
        self.concurrency = max(1, concurrency)
        self.onFrame = onFrame
    }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        let source = self.source
        let imageAccessor = self.imageAccessor
        let concurrency = self.concurrency
        let onFrame = self.onFrame
        task = Task.detached(priority: .utility) {
            for await event in source.events() {
                let arrived: IndexSet
                switch event {
                case .snapshot(let available, _, _): arrived = available
                case .framesAvailable(let set):      arrived = set
                default: continue
                }
                // Highest first among a batch is no better than lowest first; the sweep fills in order.
                var pending = arrived.makeIterator()
                await withTaskGroup(of: Void.self) { group in
                    func addNext() {
                        guard let index = pending.next() else { return }
                        group.addTask {
                            if Task.isCancelled { return }
                            do {
                                try await imageAccessor.writeMissingImages(forFrame: index)
                                await onFrame(index)
                            } catch {
                                Log.w("could not write the previews of frame \(index): \(error)")
                            }
                        }
                    }
                    for _ in 0..<concurrency { addNext() }
                    while await group.next() != nil { addNext() }
                }
                if Task.isCancelled { return }
            }
        }
    }

    public func stop() {
        lock.lock()
        let running = task
        task = nil
        lock.unlock()
        running?.cancel()
    }

    deinit { task?.cancel() }
}
