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
        Task(priority: .userInitiated) {
            var logMessage = ""
            if let data = data {
                logMessage = "\(logLevel.emo) \(logLevel) | \(fileLocation): \(message) | \(data.description)"
            } else {
                logMessage = "\(logLevel.emo) \(logLevel) | \(fileLocation): \(message)"
            }        

            let now = NSDate().timeIntervalSince1970
            await updatable.log(name: "\(now)",
                                message: logMessage,
                                value: now)
        }
    }
    
    public let dispatchQueue: DispatchQueue
    public var level: Log.Level?
    let updatable: UpdatableLog
    
    public init(_ updatable: UpdatableLog) {
        self.level = .warn
        self.updatable = updatable
        self.dispatchQueue = DispatchQueue(label: "fileLogging")
    }
}

public actor UpdatableProgressMonitor {
    let numberOfFrames: Int
    let config: Config
    let callbacks: Callbacks
    
    public let dispatchGroup = DispatchGroup()
    
    var frames: [FrameProcessingState: Set<FrameAirplaneRemover>] = [:]
    public init(frameCount: Int, config: Config, callbacks: Callbacks) {
        self.numberOfFrames = frameCount
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
        if self.config.numConcurrentRenders < config.progressBarLength {
            padding = String(repeating: " ", count: (config.progressBarLength - self.config.numConcurrentRenders))
        }

        if let loadingImages = frames[.loadingImages] {
            let progress =
              Double(loadingImages.count) /
              Double(self.config.numConcurrentRenders)
            updates.append() {
                await updatable.log(name: "loadingImages",
                                     message: padding + progressBar(length: self.config.numConcurrentRenders,
                                                                     progress: progress) +
                                       " \(loadingImages.count) frames loading images",
                                     value: 0.9)
            }
        }
        if let detectingOutliers = frames[.detectingOutliers] {
            let progress =
              Double(detectingOutliers.count) /
              Double(self.config.numConcurrentRenders)
            updates.append() {
                await updatable.log(name: "detectingOutliers",
                                    message: padding + progressBar(length: self.config.numConcurrentRenders,
                                                                    progress: progress) +
                                      " \(detectingOutliers.count) frames detecting outliers",
                                    value: 1)
            }
        }
        if let interFrameProcessing = frames[.interFrameProcessing] {
            let progress =
              Double(interFrameProcessing.count) /
              Double(self.config.numConcurrentRenders)
            updates.append() {
                await updatable.log(name: "interFrameProcessing",
                                    message: padding + progressBar(length: self.config.numConcurrentRenders,
                                                                    progress: progress) +
                                      " \(interFrameProcessing.count) frames classifing outlier groups",
                                    value: 3)
            }
            
        }
        if let outlierProcessingComplete = frames[.outlierProcessingComplete] {
            let progress =
              Double(outlierProcessingComplete.count) /
              Double(self.config.numConcurrentRenders)       
            updates.append() {
                await updatable.log(name: "outlierProcessingComplete",
                                    message: padding + progressBar(length: self.config.numConcurrentRenders,
                                                                    progress: progress) +
                                      " \(outlierProcessingComplete.count) frames ready to paint",
                                    value: 4)
            }
        }
        
        if let reloadingImages = frames[.reloadingImages] {
            let progress =
              Double(reloadingImages.count) /
              Double(self.config.numConcurrentRenders)      
            updates.append() {
                await updatable.log(name: "reloadingImages",
                                    message: padding + progressBar(length: self.config.numConcurrentRenders, 
                                                                    progress: progress) +
                                      " \(reloadingImages.count) frames reloadingImages",
                                    value: 5)
            }
        }
        if let painting = frames[.painting] {
            let progress =
              Double(painting.count) /
              Double(self.config.numConcurrentRenders)      
            updates.append() {
                await updatable.log(name: "painting",
                                    message: padding + progressBar(length: self.config.numConcurrentRenders, 
                                                                    progress: progress) +
                                      " \(painting.count) frames painting",
                                    value: 5)
            }
        }
        if let writingOutputFile = frames[.writingOutputFile] {
            let progress =
              Double(writingOutputFile.count) /
              Double(self.config.numConcurrentRenders)        
            updates.append() {
                await updatable.log(name: "writingOutputFile",
                                    message: padding + progressBar(length: self.config.numConcurrentRenders,
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

        dispatchGroup.enter()
        Task(priority: .userInitiated) {
            for update in _updates { await update() }
            dispatchGroup.leave()
        }
    }
}

