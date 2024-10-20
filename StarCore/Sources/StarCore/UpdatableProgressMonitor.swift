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

public final class UpdatableLogHandler: LogHandler {
    public func log(message: String,
                    at fileLocation: String,
                    with data: LogData?,
                    at logLevel: Log.Level,
                    logTime: TimeInterval)
    {
        Task.detached {
            var logMessage = ""
            if let data {
                logMessage = "\(logLevel.emo) \(logLevel) | \(fileLocation): \(message) | \(data.description)"
            } else {
                logMessage = "\(logLevel.emo) \(logLevel) | \(fileLocation): \(message)"
            }        

            await self.updatable.log(name: "\(logTime)",
                                     message: logMessage,
                                     value: logTime) // XXX fix this
        }
    }
    
    public let level: Log.Level
    let updatable: UpdatableLog
    
    public init(_ updatable: UpdatableLog) {
        //self.level = .warn
        self.level = .error
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
        Task.detached {
            await self.startLoop()
        }
    }

    private func startLoop() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Task.detached {
                await self.redraw()
                await self.startLoop()
            }
        }
    }

    private var lastUpdateTime: TimeInterval?
    
    public func stateChange(for frame: FrameAirplaneRemover,
                            to newState: FrameProcessingState) async 
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

        await redraw()
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
    func redraw() async {

        guard let updatable = callbacks.updatable else { return }

        var updates: [() async -> Void] = []

        value = 0
        
        if let update = progressLine(for: .starAlignment) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .subtractingNeighbor) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .assemblingPixels) {
            updates.append(update)
        }

        if let update = progressLine(for: .detectingBlobs) {
            updates.append(update)
        }

        if let update = progressLine(for: .isolatedBlobRemoval1) {
            updates.append(update)
        }

        if let update = progressLine(for: .isolatedBlobRemoval2) {
            updates.append(update)
        }

        if let update = progressLine(for: .isolatedBlobRemoval3) {
            updates.append(update)
        }

        if let update = progressLine(for: .isolatedBlobRemoval4) {
            updates.append(update)
        }

        if let update = progressLine(for: .smallLinearBlobAbsorbtion) {
            updates.append(update)
        }

        if let update = progressLine(for: .largerLinearBlobAbsorbtion) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .finalCrunch) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .populatingOutlierGroups) {
            updates.append(update)
        }
        
        value = value + 100 // scoot up a bunch so FinalProcessor can stick a line inbetween easily
        
        if let update = progressLine(for: .interFrameProcessing) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .outlierProcessingComplete) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .finishing) {
            updates.append(update)
        }

        if let update = progressLine(for: .writingOutlierValues) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .loadingImages) {
            updates.append(update)
        }
        
        if let update = progressLine(for: .loadingImages1) {
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

        for update in _updates { await update() }
    }
}

