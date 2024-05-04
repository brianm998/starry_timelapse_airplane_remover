import Foundation
import CoreGraphics
import Cocoa
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

public class UpdatableLogHandler: LogHandler {
    public func log(message: String,
                    at fileLocation: String,
                    with data: LogData?,
                    at logLevel: Log.Level,
                    logTime: TimeInterval)
    {
        TaskWaiter.shared.task(priority: .userInitiated) {
            var logMessage = ""
            if let data {
                logMessage = "\(logLevel.emo) \(logLevel) | \(fileLocation): \(message) | \(data.description)"
            } else {
                logMessage = "\(logLevel.emo) \(logLevel) | \(fileLocation): \(message)"
            }        

            await self.updatable.log(name: "\(logTime)",
                                     message: logMessage,
                                     value: logTime)
        }
    }
    
    public var level: Log.Level
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
    let padding: String

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
        
        var padding = ""
        if self.numConcurrentRenders < config.progressBarLength {
            padding = String(repeating: " ", count: (config.progressBarLength - self.numConcurrentRenders))
        }
        self.padding = padding
        Task {
            await self.startLoop()
        }
    }

    private func startLoop() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Task {
                await self.redraw()
                await self.startLoop()
            }
        }
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

    func progressLine(for processingState: FrameProcessingState) -> (() async -> Void)?
    {
        if let group = frames[processingState],
           let updatable = callbacks.updatable
        {
            let progress =
              Double(group.count) /
              Double(self.numConcurrentRenders)
            let myValue = self.value
            self.value += 1
            return {
                await updatable.log(name: "processingState \(processingState.rawValue)",
                                    message: self.padding + progressBar(length: self.numConcurrentRenders,
                                                                     progress: progress) +
                                       " \(group.count) frames \(processingState.message)",
                                     value: myValue)
            }
        }
        return nil
    }
    
    var value: Double = 0
    func redraw() {

        guard let updatable = callbacks.updatable else { return }

        var updates: [() async -> Void] = []

        value = 0
        
        if let update = progressLine(for: .starAlignment) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .loadingImages) {
            updates.append(update)
        }

        if let update = progressLine(for: .subtractingNeighbor) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .detectingOutliers2p) {
            updates.append(update)

        }
        if let update = progressLine(for: .detectingOutliers2) {
            updates.append(update)

        }
        if let update = progressLine(for: .detectingOutliers1) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .detectingOutliers1a) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .detectingOutliers2a) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .detectingOutliers2aa) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .detectingOutliers2b) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .detectingOutliers2c) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .detectingOutliers2d) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .detectingOutliers2e) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .detectingOutliers2f) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .detectingOutliers2g) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .detectingOutliers3) {
            updates.append(update)
        }
        
        value = 100             // scoot up a bunch so FinalProcessor can stick a line inbetween easily
        
        if let update = progressLine(for: .interFrameProcessing) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .outlierProcessingComplete) {
            updates.append(update)
        }

        if let update = progressLine(for: .writingBinaryOutliers) {
            updates.append(update)
        }

        if let update = progressLine(for: .writingOutlierValues) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .reloadingImages) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .painting) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .painting2) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .writingOutputFile) {
            updates.append(update)
        }

        if let complete = frames[.complete] {
            let progress =
              Double(complete.count) /
              Double(self.numberOfFrames)
            updates.append() {
                await updatable.log(name: "complete",
                                    message: progressBar(length: self.config.progressBarLength,
                                                         progress: progress) +
                                      " \(complete.count) / \(self.numberOfFrames) frames complete",
                                    value: self.value)
            }
        } else {
            // log crap here
        }
/*
        updates.append() {
            let progress = await processorTracker.percentIdle()
            Log.d("percent idle \(progress)")
            await updatable.log(name: "percent idle",
                                message: progressBar(length: self.config.progressBarLength,
                                                     progress: progress/100) + " cpu usage ",
                                value: self.value)
        }
  */      

        let _updates = updates

        TaskWaiter.shared.task(priority: .userInitiated) {
            for update in _updates { await update() }
        }
    }
}

