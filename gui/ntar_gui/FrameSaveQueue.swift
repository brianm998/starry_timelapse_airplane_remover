import Foundation
import SwiftUI
import Cocoa
import NtarCore
import Zoomable

class FrameSaveQueue {

    class Pergatory {
        var timer: Timer
        let frame: FrameAirplaneRemover
        let block: @Sendable (Timer) -> Void
        let wait_time: TimeInterval = 5 // minimum time to wait in purgatory
        
        init(frame: FrameAirplaneRemover, block: @escaping @Sendable (Timer) -> Void) {
            self.frame = frame
            self.timer = Timer.scheduledTimer(withTimeInterval: wait_time,
                                              repeats: false, block: block)
            self.block = block
        }

        func retainLonger() {
            self.timer = Timer.scheduledTimer(withTimeInterval: wait_time,
                                              repeats: false, block: block)
        }
    }

    var pergatory: [Int: Pergatory] = [:] // both indexed by frame_index
    var saving: [Int: FrameAirplaneRemover] = [:]

    let finalProcessor: FinalProcessor
    
    init(_ finalProcessor: FinalProcessor) {
        self.finalProcessor = finalProcessor
    }

    // no purgatory
    func saveNow(frame: FrameAirplaneRemover) {
        Log.w("actually saving frame \(frame.frame_index)")
        self.saving[frame.frame_index] = frame
        Task {
            await self.finalProcessor.final_queue.add(atIndex: frame.frame_index) {
                Log.i("frame \(frame.frame_index) finishing")
                try await frame.loadOutliers()
                try await frame.finish()
                await MainActor.run {
                    self.saving[frame.frame_index] = nil
                }
                Log.i("frame \(frame.frame_index) finished")
            }
        }
    }
    
    func readyToSave(frame: FrameAirplaneRemover) {
        Log.w("frame \(frame.frame_index) entering pergatory")
        if let candidate = pergatory[frame.frame_index] {
            candidate.retainLonger()
        } else {
            let candidate = Pergatory(frame: frame) { timer in
                Log.w("pergatory has ended for frame \(frame.frame_index)")
                self.pergatory[frame.frame_index] = nil
                if let _ = self.saving[frame.frame_index] {
                    // go back to pergatory
                    self.readyToSave(frame: frame)
                } else {
                    self.saveNow(frame: frame)
                }
            }
        }
    }
}

