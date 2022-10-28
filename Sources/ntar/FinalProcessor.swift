import Foundation
import CoreGraphics
import Cocoa

// this class handles the final processing of every frame
// it observes its frames array, and is tasked with finishing
// each frame.  This means adjusting each frame's should_paint map
// to be concurent with those of the adjecent frames.
// at this point each frame has been processed to have a good idea of 
// what outlier groups to paint and not to paint.
// this process puts the final touches on the should_paint map of each
// frame and then calls finish() on it, which paints based upon the
// should_paint map, and then saves the output file(s).

@available(macOS 10.15, *)
actor FinalProcessor {
    var frames: [FrameAirplaneRemover?]
    var current_frame_index = 0

    
    init(numberOfFrames frame_count: Int) {
        frames = [FrameAirplaneRemover?](repeating: nil, count: frame_count)
    }

    func add(frame: FrameAirplaneRemover, at index: Int) {
        Log.i("add frame at index \(index)")
        frames[index] = frame
    }

    func clearFrame(at index: Int) {
        frames[index] = nil
    }
    func incrementCurrentFrameIndex() {
        current_frame_index += 1
    }

    func frame(at index: Int) -> FrameAirplaneRemover? {
        return frames[index]
    }
    
    nonisolated func run() async {
        var done = false
        while(!done) {
            //Log.i("current_frame_index \(current_frame_index)")
            if let current_frame = await self.frame(at: current_frame_index) {
                current_frame.finish()
                await self.clearFrame(at: current_frame_index)
                await self.incrementCurrentFrameIndex()
            } else {
                sleep(1)        // XXX hardcoded sleep amount
            }
            done = await current_frame_index >= frames.count 
        }
    }
}


