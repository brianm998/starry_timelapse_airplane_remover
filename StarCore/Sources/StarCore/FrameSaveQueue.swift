import Foundation
import logging

@MainActor
public class FrameSaveQueue {

    public init() { }

    public var savingCount: Int = 0
    public var pendingSavingCount: Int = 0
    public var purgatoryCount: Int = 0

    /// Bounds how many saves run at once.  Built on first use from
    /// `numberOfFramesToProcessConcurrently` rather than the hardcoded 16 this used to
    /// use, so it tracks the same concurrency the frame graph is configured for.
    /// One semaphore for the lifetime of the queue — rebuilding it per save would
    /// bound nothing.
    private var saveMonitor: FileSystemMonitor?

    private func monitor(concurrency: Int) -> FileSystemMonitor {
        if let saveMonitor { return saveMonitor }
        let created = FileSystemMonitor(max: max(1, concurrency))
        Log.i("FrameSaveQueue: bounding saves to \(max(1, concurrency)) at a time")
        saveMonitor = created
        return created
    }

    public func readyToSave(
      frame: FrameAirplaneRemover,
      waitTime: TimeInterval = 10,
      completionClosure: @Sendable @escaping () async -> Void
    ) async {
        Task.detached {
            if await frame.savingState() == .savePending { return }
            
            Log.d("frame \(frame.frameIndex) added to purgatory")
            await frame.set(frameSavingState: .inPurgatory)
            // not in purgatory already
            // previous tasks are canceled inside here VVV
            await frame.startSaveTimerTask(waitTime: waitTime) {
                Log.d("frame \(frame.frameIndex) exiting purgatory")

                // only save if it is still in purgatory
                let savingState = await frame.savingState()
                if savingState == .inPurgatory {
                    try await self.saveNow(frame: frame, completionClosure: completionClosure)
                }
            }
        }
    }
    
    public func saveNow(
      frame: FrameAirplaneRemover,
      completionClosure: @Sendable @escaping () async -> Void
    ) async throws {
        // Read the config here, on the main actor, before detaching.
        let config = frame.configManager.config()
        let saveMonitor = monitor(concurrency: config.numberOfFramesToProcessConcurrently)

        Task.detached(priority: .high) {
            Log.d("frame \(frame.frameIndex) saveNow")
            try Task.checkCancellation()
            await frame.set(frameSavingState: .savePending)
            try await saveMonitor.save() {
                await frame.set(frameSavingState: .saving)
                Log.d("frame \(frame.frameIndex) saveNow for real")

                // update values that may have been changed by the user in the gui

                // set number of aligned images.  Before the reservation is sized, since
                // it reads the count this sets.
                await frame.setNumberOfAlignedFrames()

                // finish() runs the same merge work MergeOp does — including creating
                // the aligned image if it is not on disk yet — but this path lives
                // outside the frame graph's OperationQueue, so nothing was charging it
                // to the MemoryMonitor.  That left up to `concurrency` full merge
                // pipelines running completely unaccounted for, concurrently with the
                // graph's own work.  Charge the same estimate MergeOp would, off this
                // frame's actual neighbour counts.
                let reservation = config.workingFrameBytes *
                  UInt64(config.effectiveMergeMemoryMultiplier(
                           alignedNeighbours: await frame.numberOfAlignedFrames,
                           staticNeighbours: await frame.getStaticNeighborFrames().count))

                if reservation > 0 {
                    await MemoryMonitor.shared.reserve(bytes: reservation)
                }
                do {
                    try await frame.loadOutliers()
                    try await frame.finish()
                    await frame.changesHandled()
                } catch {
                    Log.e("frame \(frame.frameIndex) frame save error: \(error)")
                }
                // Every throwing call above is inside the do/catch, and neither
                // reserve() nor frame.set() throws, so this is always reached.
                if reservation > 0 {
                    await MemoryMonitor.shared.release(bytes: reservation)
                }

                await frame.set(frameSavingState: .notSaving)
                await completionClosure()
            }
        }
    }

    public func frameSavingStateChanged(for frame: FrameAirplaneRemover,
                                        from oldState: FrameSavingState,
                                        to newState: FrameSavingState) 
    {

        switch newState {
        case .notSaving:
            switch oldState {
            case .notSaving:
                break
            case .inPurgatory:
                purgatoryCount -= 1
            case .savePending:
                pendingSavingCount -= 1
            case .saving:
                savingCount -= 1
            }
        case .inPurgatory:
            switch oldState {
            case .notSaving:
                purgatoryCount += 1
            case .inPurgatory:
                break
            case .savePending:
                purgatoryCount += 1
                pendingSavingCount -= 1
            case .saving:
                purgatoryCount += 1
                savingCount -= 1
            }
        case .savePending:
            switch oldState {
            case .notSaving:
                pendingSavingCount += 1
            case .inPurgatory:
                pendingSavingCount += 1
                purgatoryCount -= 1
            case .savePending:
                break
            case .saving:
                pendingSavingCount += 1
                savingCount -= 1
            }
        case .saving:
            switch oldState {
            case .notSaving:
                savingCount += 1
            case .inPurgatory:
                savingCount += 1
                purgatoryCount -= 1
            case .savePending:
                savingCount += 1
                pendingSavingCount -= 1
            case .saving:
                break
            }
        }
        Log.d("saving state changed")
    }
}

