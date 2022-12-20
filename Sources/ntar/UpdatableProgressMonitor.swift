import Foundation
import CoreGraphics
import Cocoa

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/


@available(macOS 10.15, *)
var updatableProgressMonitor: UpdatableProgressMonitor?

@available(macOS 10.15, *)
actor UpdatableProgressMonitor {
    let number_of_frames: Int
    let maxConcurrent: Int
    
    var frames: [FrameProcessingState: Set<FrameAirplaneRemover>] = [:]
    init(frameCount: Int, maxConcurrent: Int) {
        self.number_of_frames = frameCount
        self.maxConcurrent = maxConcurrent
    }

    private var last_update_time: TimeInterval?
    
    func stateChange(for frame: FrameAirplaneRemover, to new_state: FrameProcessingState) {
        for state in FrameProcessingState.allCases {
            if state == new_state { continue }
            if var state_items = frames[state] {
                state_items.remove(frame)
                frames[state] = state_items
            }
        }
        if var set = frames[new_state] {
            set.insert(frame)
            frames[new_state] = set
        } else {
            frames[new_state] = [frame]
        }

        var should_update = true
        
        let now = NSDate().timeIntervalSince1970
        if let last_update_time = last_update_time,
           now - last_update_time < Double.pi/10 // XXX hardcoded minimum update time
        {
            should_update = false 
        }
        if should_update {
            last_update_time = now
            redraw()
        }
    }

    func redraw() {

        guard let updatable = updatable else { return }

        var updates: [() async -> Void] = []

        if let loadingImages = frames[.loadingImages] {
            let progress =
              Double(loadingImages.count) /
              Double(self.maxConcurrent)
            updates.append() {
                await updatable.log(name: "loadingImages",
                                     message: progress_bar(length: self.maxConcurrent,
                                                           progress: progress) +
                                       " \(loadingImages.count) frames loading images",
                                     value: 0.9)
            }
        }
        if let detectingOutliers = frames[.detectingOutliers] {
            let progress =
              Double(detectingOutliers.count) /
              Double(self.maxConcurrent)
            updates.append() {
                await updatable.log(name: "detectingOutliers",
                                     message: progress_bar(length: self.maxConcurrent,
                                                           progress: progress) +
                                       " \(detectingOutliers.count) frames detecting outliers",
                                     value: 1)
            }
        }
        if let interFrameProcessing = frames[.interFrameProcessing] {
            let progress =
              Double(interFrameProcessing.count) /
              Double(self.maxConcurrent)
            updates.append() {
                await updatable.log(name: "interFrameProcessing",
                                     message: progress_bar(length: self.maxConcurrent,
                                                           progress: progress) +
                                       " \(interFrameProcessing.count) frames inter frame processing",
                                     value: 3)
            }
            
        }
        if let outlierProcessingComplete = frames[.outlierProcessingComplete] {
            let progress =
              Double(outlierProcessingComplete.count) /
              Double(self.maxConcurrent)       
            updates.append() {
                await updatable.log(name: "outlierProcessingComplete",
                                     message: progress_bar(length: self.maxConcurrent,
                                                           progress: progress) +
                                       " \(outlierProcessingComplete.count) frames ready to paint",
                                     value: 4)
            }
        }
        
        if let reloadingImages = frames[.reloadingImages] {
            let progress =
              Double(reloadingImages.count) /
              Double(self.maxConcurrent)      
            updates.append() {
                await updatable.log(name: "reloadingImages",
                                     message: progress_bar(length: self.maxConcurrent, 
                                                           progress: progress) +
                                       " \(reloadingImages.count) frames reloadingImages",
                                     value: 5)
            }
        }
        if let painting = frames[.painting] {
            let progress =
              Double(painting.count) /
              Double(self.maxConcurrent)      
            updates.append() {
                await updatable.log(name: "painting",
                                     message: progress_bar(length: self.maxConcurrent, 
                                                           progress: progress) +
                                       " \(painting.count) frames painting",
                                     value: 5)
            }
        }
        if let writingOutputFile = frames[.writingOutputFile] {
            let progress =
              Double(writingOutputFile.count) /
              Double(self.maxConcurrent)        
            updates.append() {
                await updatable.log(name: "writingOutputFile",
                                     message: progress_bar(length: self.maxConcurrent,
                                                           progress: progress) +
                                       " \(writingOutputFile.count) frames writing to disk",
                                     value: 6)
            }
        }
        if let complete = frames[.complete] {
            let progress =
              Double(complete.count) /
              Double(self.number_of_frames)
            updates.append() {
                await updatable.log(name: "complete",
                                     message: progress_bar(length: 50, progress: progress) +
                                       " \(complete.count) / \(self.number_of_frames) frames complete",
                                     value: 100)
            }
        } else {
            // log crap here
        }

        let _updates = updates
        
        Task(priority: .userInitiated) { for update in _updates { await update() } }
    }
}

