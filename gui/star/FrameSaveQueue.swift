import Foundation
import SwiftUI
import Cocoa
import StarCore
import Zoomable
import logging

@MainActor
class FrameSaveQueue {

    class Purgatory {
        var timerTask: Task<Void,Never>
        let frame: FrameAirplaneRemover
        let block: @Sendable () async -> Void
        let wait_time: TimeInterval // minimum time to wait in purgatory
        
        init(frame: FrameAirplaneRemover,
             waitTime: TimeInterval = 5,
             block: @escaping @Sendable () async -> Void)
        {
            self.frame = frame
            self.wait_time = waitTime
            self.timerTask = Task<Void,Never> {
                try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
                do {
                    try Task.checkCancellation()
                    await block()
                } catch { }
            }
            self.block = block
        }
    }

    var purgatory: [Int: Purgatory] = [:] // both indexed by frameIndex

    // 
    var saving: [Int: FrameAirplaneRemover] = [:]

    
    var sizeUpdatedCompletion: ((Int) async -> Void)? 
    
    func sizeUpdated(_ completion: @escaping (Int) async -> Void) {
        sizeUpdatedCompletion = completion
    }
    
    init() { }

    func frameIsInPurgatory(_ frameIndex: Int) -> Bool {
        return purgatory.keys.contains(frameIndex)
    }
    
    func doneSaving(frame frameIndex: Int) async {
        self.saving[frameIndex] = nil
        if let sizeUpdatedCompletion {
            await sizeUpdatedCompletion(self.saving.count)
        }
    }
    
    // no purgatory
    func saveNow(frame: FrameAirplaneRemover,
                 completionClosure: @Sendable @escaping () async -> Void) async
    {
        Log.i("saveNow for frame \(frame.frameIndex)")
        // check to see if it's not already being saved
        if self.saving[frame.frameIndex] != nil {
            // another save is in progress
            Log.i("setting frame \(frame.frameIndex) to readyToSave because already saving frame \(frame.frameIndex)")
            //self.readyToSave(frame: frame, waitTime: 5, completionClosure: completionClosure)
        } else {
            Log.i("actually saving frame \(frame.frameIndex)")
            self.saving[frame.frameIndex] = frame
            if let sizeUpdatedCompletion {
                await sizeUpdatedCompletion(self.saving.count)
            }
            do {
                try await frame.loadOutliers()
                try await frame.finish()
                await frame.changesHandled()

                // XXX this VVV doesn't always update in the UI without user action
                await self.doneSaving(frame: frame.frameIndex)
                await completionClosure()
                
            } catch {
                Log.e("error \(error)")
            }
        }
    }

    func endPurgatory(for frameIndex: Int) {
        Log.i("ending purgatory for frame \(frameIndex)")
        self.purgatory[frameIndex] = nil
    }
    
    func readyToSave(frame: FrameAirplaneRemover,
                     waitTime: TimeInterval = 12,
                     completionClosure: @Sendable @escaping () async -> Void) async {

        if let _ = purgatory[frame.frameIndex] {
            Log.i("frame \(frame.frameIndex) is already in purgatory")
        } else {
            Log.i("frame \(frame.frameIndex) entering purgatory")
            let candidate = Purgatory(frame: frame, waitTime: waitTime) { 
                Log.i("purgatory has ended for frame \(frame.frameIndex)")
              await self.endPurgatory(for: frame.frameIndex)
              await self.saveNow(frame: frame, completionClosure: completionClosure)
            }
            Log.i("starting purgatory for frame \(frame.frameIndex)")
            purgatory[frame.frameIndex] = candidate
        }
    }
}


