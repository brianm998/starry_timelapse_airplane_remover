import Foundation
import CoreGraphics
import Cocoa

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

public class UpdatableLogHandler: LogHandler {
    public func log(message: String,
                    at fileLocation: String,
                    on threadName: String,
                    with data: LogData?,
                    at logLevel: Log.Level)
    {
        TaskWaiter.task(priority: .userInitiated) {
            var logMessage = ""
            if let data = data {
                logMessage = "\(logLevel.emo) \(logLevel) | \(fileLocation): \(message) | \(data.description)"
            } else {
                logMessage = "\(logLevel.emo) \(logLevel) | \(fileLocation): \(message)"
            }        

            let now = NSDate().timeIntervalSince1970
            await self.updatable.log(name: "\(now)",
                                     message: logMessage,
                                     value: now)
        }
    }
    
    public var level: Log.Level?
    let updatable: UpdatableLog
    
    public init(_ updatable: UpdatableLog) {
        self.level = .warn
        self.updatable = updatable
    }
}

public actor UpdatableProgressMonitor {
    let numberOfFrames: Int
    let config: Config
    let callbacks: Callbacks
    let numConcurrentRenders: Int
    
    var frames: [FrameProcessingState: Set<FrameAirplaneRemover>] = [:]
    public init(frameCount: Int,
                numConcurrentRenders: Int,
                config: Config,
                callbacks: Callbacks)
    {
        self.numberOfFrames = frameCount
        self.numConcurrentRenders = numConcurrentRenders
        self.config = config
        self.callbacks = callbacks
    }

    private var lastUpdateTime: TimeInterval?
    
    public func stateChange(for frame: FrameAirplaneRemover,
                            to newState: FrameProcessingState)
    {
        for state in FrameProcessingState.allCases {
            if state == newState { continue }
            if var stateItems = frames[state] {
                stateItems.remove(frame)
                frames[state] = stateItems
            }
        }
        if var set = frames[newState] {
            set.insert(frame)
            frames[newState] = set
        } else {
            frames[newState] = [frame]
        }

        redraw()
    }

    func redraw() {

        guard let updatable = callbacks.updatable else { return }

        var updates: [() async -> Void] = []

        var padding = ""
        if self.numConcurrentRenders < config.progressBarLength {
            padding = String(repeating: " ", count: (config.progressBarLength - self.numConcurrentRenders))
        }

        if let loadingImages = frames[.loadingImages] {
            let progress =
              Double(loadingImages.count) /
              Double(self.numConcurrentRenders)
            updates.append() {
                await updatable.log(name: "loadingImages",
                                     message: padding + progressBar(length: self.numConcurrentRenders,
                                                                     progress: progress) +
                                       " \(loadingImages.count) frames loading images",
                                     value: 0.9)
            }
        }
        if let starAlignment = frames[.starAlignment] {
            let progress =
              Double(starAlignment.count) /
              Double(self.numConcurrentRenders)
            updates.append() {
                await updatable.log(name: "starAlignment",
                                     message: padding + progressBar(length: self.numConcurrentRenders,
                                                                     progress: progress) +
                                       " \(starAlignment.count) frames aligning stars",
                                     value: 0.7)
            }
        }
        if let detectingOutliers = frames[.detectingOutliers] {
            let progress =
              Double(detectingOutliers.count) /
              Double(self.numConcurrentRenders)
            updates.append() {
                await updatable.log(name: "detectingOutliers",
                                    message: padding + progressBar(length: self.numConcurrentRenders,
                                                                    progress: progress) +
                                      " \(detectingOutliers.count) frames detecting outlying pixels",
                                    value: 1)
            }
        }
        if let detectingOutliers = frames[.detectingOutliers1] {
            let progress =
              Double(detectingOutliers.count) /
              Double(self.numConcurrentRenders)
            updates.append() {
                await updatable.log(name: "detectingOutliers 1",
                                    message: padding + progressBar(length: self.numConcurrentRenders,
                                                                    progress: progress) +
                                      " \(detectingOutliers.count) frames grouping outlying pixels",
                                    value: 1.1)
            }
        }
        if let detectingOutliers = frames[.detectingOutliers2] {
            let progress =
              Double(detectingOutliers.count) /
              Double(self.numConcurrentRenders)
            updates.append() {
                await updatable.log(name: "detectingOutliers 2",
                                    message: padding + progressBar(length: self.numConcurrentRenders,
                                                                    progress: progress) +
                                      " \(detectingOutliers.count) frames calculating outlier group bounds",
                                    value: 1.2)
            }
        }
        if let detectingOutliers = frames[.detectingOutliers3] {
            let progress =
              Double(detectingOutliers.count) /
              Double(self.numConcurrentRenders)
            updates.append() {
                await updatable.log(name: "detectingOutliers 3",
                                    message: padding + progressBar(length: self.numConcurrentRenders,
                                                                    progress: progress) +
                                      " \(detectingOutliers.count) frames populating outlier groups",
                                    value: 1.3)
            }
        }
        if let interFrameProcessing = frames[.interFrameProcessing] {
            let progress =
              Double(interFrameProcessing.count) /
              Double(self.numConcurrentRenders)
            updates.append() {
                await updatable.log(name: "interFrameProcessing",
                                    message: padding + progressBar(length: self.numConcurrentRenders,
                                                                    progress: progress) +
                                      " \(interFrameProcessing.count) frames classifing outlier groups",
                                    value: 3)
            }
            
        }
        if let outlierProcessingComplete = frames[.outlierProcessingComplete] {
            let progress =
              Double(outlierProcessingComplete.count) /
              Double(self.numConcurrentRenders)       
            updates.append() {
                await updatable.log(name: "outlierProcessingComplete",
                                    message: padding + progressBar(length: self.numConcurrentRenders,
                                                                    progress: progress) +
                                      " \(outlierProcessingComplete.count) frames ready to finish",
                                    value: 4)
            }
        }

        if let writingBinaryOutliers = frames[.writingBinaryOutliers] {
            let progress =
              Double(writingBinaryOutliers.count) /
              Double(self.numConcurrentRenders)      
            updates.append() {
                await updatable.log(name: "writingBinaryOutliers",
                                    message: padding + progressBar(length: self.numConcurrentRenders, 
                                                                    progress: progress) +
                                      " \(writingBinaryOutliers.count) frames writing raw outlier data",
                                    value: 5)
            }
        }

        if let writingOutlierValues = frames[.writingOutlierValues] {
            let progress =
              Double(writingOutlierValues.count) /
              Double(self.numConcurrentRenders)      
            updates.append() {
                await updatable.log(name: "writingOutlierValues",
                                    message: padding + progressBar(length: self.numConcurrentRenders, 
                                                                    progress: progress) +
                                      " \(writingOutlierValues.count) frames writing outlier classification values",
                                    value: 5)
            }
        }

        if let reloadingImages = frames[.reloadingImages] {
            let progress =
              Double(reloadingImages.count) /
              Double(self.numConcurrentRenders)      
            updates.append() {
                await updatable.log(name: "reloadingImages",
                                    message: padding + progressBar(length: self.numConcurrentRenders, 
                                                                    progress: progress) +
                                      " \(reloadingImages.count) frames reloadingImages",
                                    value: 5)
            }
        }
        if let painting = frames[.painting] {
            let progress =
              Double(painting.count) /
              Double(self.numConcurrentRenders)      
            updates.append() {
                await updatable.log(name: "painting",
                                    message: padding + progressBar(length: self.numConcurrentRenders, 
                                                                    progress: progress) +
                                      " \(painting.count) frames painting",
                                    value: 5)
            }
        }
        if let writingOutputFile = frames[.writingOutputFile] {
            let progress =
              Double(writingOutputFile.count) /
              Double(self.numConcurrentRenders)        
            updates.append() {
                await updatable.log(name: "writingOutputFile",
                                    message: padding + progressBar(length: self.numConcurrentRenders,
                                                                    progress: progress) +
                                      " \(writingOutputFile.count) frames writing to disk",
                                    value: 6)
            }
        }
        if let complete = frames[.complete] {
            let progress =
              Double(complete.count) /
              Double(self.numberOfFrames)
            updates.append() {
                await updatable.log(name: "complete",
                                    message: progressBar(length: self.config.progressBarLength, progress: progress) +
                                      " \(complete.count) / \(self.numberOfFrames) frames complete",
                                    value: 100)
            }
        } else {
            // log crap here
        }

        let _updates = updates

        TaskWaiter.task(priority: .userInitiated) {
            for update in _updates { await update() }
        }
    }
}

