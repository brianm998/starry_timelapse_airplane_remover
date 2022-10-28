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
    let frame_count: Int
    
    init(numberOfFrames frame_count: Int) {
        frames = [FrameAirplaneRemover?](repeating: nil, count: frame_count)
        self.frame_count = frame_count
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

    func finishAll() {
        for frame in frames {
            if let frame = frame {
                frame.finish()
            }
        }
    }

    let number_neighbors_needed = 1 // in each direction
    
    nonisolated func run() async {
        var done = false
        while(!done) {
            let index_to_process = await current_frame_index

            var images_to_process: [FrameAirplaneRemover] = []
            
            var start_index = index_to_process - number_neighbors_needed
            var end_index = index_to_process + number_neighbors_needed
            if start_index < 0 {
                start_index = 0
            }
            if end_index >= frame_count {
                end_index = frame_count - 1
            }

            Log.i("processing frame index \(index_to_process)")
            var bad = false
            for i in start_index ... end_index {
                if let next_frame = await self.frame(at: i) {
                    images_to_process.append(next_frame)
                } else {
                    bad = true
                    // XXX bad
                }
            }
            if !bad {
                self.handle(frames: images_to_process)
                await self.incrementCurrentFrameIndex()

                if start_index > 0 {
                    if let frame_to_finish = await self.frame(at: start_index - 1) {
                        Log.e("finishing frame")
                        frame_to_finish.finish()
                        await self.clearFrame(at: start_index - 1)
                    }
                }
                done = await current_frame_index >= frames.count 
                if done {
                    Log.e("finishing all remaining frames")
                    await self.finishAll()
                }
            } else {
                sleep(1)        // XXX hardcoded sleep amount
            }
        }
    }

    nonisolated func handle(frames: [FrameAirplaneRemover]) {
        // XXX right now nothing
        Log.e("handle \(frames.count) frames")
        for frame in frames {
            for (group_name, group_line) in frame.group_lines {
                // look for

                let line_theta = group_line.theta
                let line_rho = group_line.rho
                
                for other_frame in frames {
                    if other_frame == frame { continue }

                    for (other_group_name, other_group_line) in other_frame.group_lines {
                        let other_line_theta = other_group_line.theta
                        let other_line_rho = other_group_line.rho

                        let theta_diff = abs(line_theta-other_line_theta)
                        let rho_diff = abs(line_rho-other_line_rho)
                        
                        if theta_diff < 15 && rho_diff < 40 { // XXX hardcoded constants
                            Log.e("theta_diff \(theta_diff) rho_diff \(rho_diff)")
                            // mark as should paint
                            frame.should_paint[group_name] = true
                            other_frame.should_paint[other_group_name] = true
                        }
                    }
                }
            }
        }
    }

}


