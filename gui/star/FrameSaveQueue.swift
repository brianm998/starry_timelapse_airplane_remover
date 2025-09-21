import Foundation
import SwiftUI
import Cocoa
import StarCore
import logging

fileprivate let frameSaveMonitor = FileSystemMonitor(max: 16) // guess, make configurable?
// XXX this needs to track numberOfFramesToProcessConcurrently
@MainActor @Observable
class FrameSaveQueue {

    init() { } 

    weak var viewModel: ImageSequenceViewModel?
    
    var savingCount: Int = 0
    var pendingSavingCount: Int = 0
    var purgatoryCount: Int = 0

    func readyToSave(frame: FrameAirplaneRemover,
                     waitTime: TimeInterval = 10,
                     completionClosure: @Sendable @escaping () async -> Void) async
    {
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
    
    func saveNow(frame: FrameAirplaneRemover,
                 completionClosure: @Sendable @escaping () async -> Void) async throws
    {
        Task.detached(priority: .high) {
            Log.d("frame \(frame.frameIndex) saveNow")
            try Task.checkCancellation()
            await frame.set(frameSavingState: .savePending)
            try await frameSaveMonitor.save() {
                await frame.set(frameSavingState: .saving)
                Log.d("frame \(frame.frameIndex) saveNow for real")
                do {
                    // update values that may have been changed by the user in the gui

                    if let viewModel = await self.viewModel {
                        // set pixelThreshold
                        await frame.set(pixelThreshold: viewModel.pixelThreshold)
                        // set number of aligned images
                        await frame.setNumberOfAlignmentImages(viewModel.numberOfNeighborFrames)
                    }
                    
                    try await frame.loadOutliers()
                    try await frame.finish()
                    await frame.changesHandled()
                } catch {
                    Log.e("frame \(frame.frameIndex) frame save error: \(error)")
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

