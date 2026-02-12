import Foundation
import CoreGraphics
import StarCore
import logging
import Cocoa

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later v
ersion.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/



// this class handles removing airplanes from an entire sequence,
// delegating each frame to an instance of FrameAirplaneRemover
// and then using a FinalProcessor to finish processing

/*

 XXX rewrite this to not use the FinalProcessor, but instead the FrameGraphBuilder

 1. first assemble an array of FrameAirplaneRemover actors for each frame
 2. call frameGraphBuilder.set(configManager:) with the given config
 3. then run frameGraphBuilder.build() on the frames
 4. make sure screen output still look ok
 5. cli should be working again
 6. get rid of this class, and maybe a number of other classes
 7. do an unused code cleanp?
 
 */
public actor NumberLeft {
    private var numberLeft: Int = 0

    public func increment() { numberLeft += 1 }
    public func decrement() { numberLeft -= 1 }
    public func isDone() -> Bool { numberLeft <= 0 }
    public func hasMore() -> Bool { numberLeft > 0 }
}

public actor NighttimeAirplaneRemover {


    // ImageSequenceProcessor code

    // the name of the directory holding the image sequence being processed
    public let imageSequenceDirname: String

    // the name of the directory to write processed images to
    public let outputDirname: String

    public let numberFinalProcessingNeighborsNeeded: Int
    
    // the following properties get included into the output videoname
    
    // actors
    var methodList = MethodList<FrameAirplaneRemover>()       // a list of methods to process each frame

    public var imageSequence: ImageSequence    // the sequence of images that we're processing

    public func frameCount() async -> Int { await imageSequence.filenames.count }
    
    var shouldProcess: [Bool] = []       // indexed by frame number
    var existingOutputFiles: [Bool] = [] // indexed by frame number

    var remainingImagesClosure: (@Sendable (Int) -> Void)?

    let processExistingFiles: Bool
    
    func assembleMethodList() async throws -> MethodList<FrameAirplaneRemover> {
        /*
           read all existing output files 
           sort them into frame order
           remove ones within numberFinalProcessingNeighborsNeeded frames of holes
           make sure these re-runs doesn't bork on existing files later
           only process below based upon this info
        */
    
        var _methodList: [Int : @Sendable () async throws -> FrameAirplaneRemover] = [:]
        
        var frameIndexToBaseNameMap: [Int: String] = [:]
        
        for (index, imageFilename) in await imageSequence.filenames.enumerated() {

            // grab image accessor data here
            
            let basename = removePath(fromString: imageFilename)
              .sanitized
            
            frameIndexToBaseNameMap[index] = basename
            
            let outputFilename = "\(outputDirname)/\(basename)"
            if FileManager.default.fileExists(atPath: outputFilename) {
                existingOutputFiles[index] = true
            }                                  
        }

        let imageAccessor = ImageAccessor(config: await configManager.config(),
                                          imageSequence: imageSequence,
                                          frameIndexToBaseNameMap: frameIndexToBaseNameMap)    
        
        for (index, outputFileAlreadyExists) in existingOutputFiles.enumerated() {
            if !outputFileAlreadyExists {
                var startIdx = index - numberFinalProcessingNeighborsNeeded
                var endIdx = index + numberFinalProcessingNeighborsNeeded
                if startIdx < 0 { startIdx = 0 }
                if endIdx >= existingOutputFiles.count {
                    endIdx = existingOutputFiles.count - 1
                }
                for i in startIdx ... endIdx {
                    if let lastFrameNumber {
                        shouldProcess[i] = i < lastFrameNumber 
                    } else {
                        shouldProcess[i] = true
                    }
                }
            }
        }

        // XX VVV XX appears to be the root of the frameIndex starting at zero 
        for (index, imageFilename) in await self.imageSequence.filenames.enumerated() {
            let filename = await self.imageSequence.filenames[index]
            let basename = removePath(fromString: filename).sanitized
            let outputFilename = "\(outputDirname)/\(basename)"
            Log.w("shouldProcess[\(index)] = \(shouldProcess[index])")
            if shouldProcess[index] {
                _methodList[index] = {
                    // this method is run async later
                    Log.i("loading \(imageFilename) for frame \(index)")
                    //let image = await self.imageSequence.getImage(withName: imageFilename)
                    return try await self.processFrame(number: index,
                                                       outputFilename: outputFilename,
                                                       baseName: basename,
                                                       imageAccessor: imageAccessor) 
                }
            } else {
                // update progress monitor via this callback
                if let callback = callbacks.exisingFrameStateChangeCallback {
                    callback(index)
                } else {
                    framesAlreadyProcessed += 1
                }
                Log.i("not processing existing file \(filename)")
            }
        }

        return MethodList<FrameAirplaneRemover>(list: _methodList, removeClosure: remainingImagesClosure)
    }

    public func superRun() async throws { // XXX merge this with run below
        Log.d("run")
        let task = Task { try await startupHook() }
        try await task.value

        Log.d("done with startup hook")
        
        mkdir(outputDirname)

        // each of these methods removes the airplanes from a particular frame
        //Log.i("processing a total of \(await methodList.list.count) frames")
        
        try await withLimitedThrowingTaskGroup(of: FrameAirplaneRemover.self, at: .low) { group in
            while(await methodList.list.count > 0) {
                //Log.d("we have \(await methodList.list.count) more frames to process")
                Log.d("processing new frame")
                
                // sort the keys and take the smallest one first
                if let nextMethodKey = await methodList.nextKey,
                   let nextMethod = await methodList.list[nextMethodKey]
                {
                    await methodList.removeValue(forKey: nextMethodKey)
                    try await group.addTask() {
                        // XXX are errors thrown here handled?
                        let ret = try await nextMethod()
                        await self.resultHook(with: ret)
                        return ret
                    }
                } else {
                    Log.e("FUCK") 
                    fatalError("FUCK")
                }
            }
            try await group.waitForAll()
            
            Log.d("finished hook")
        }

        Log.i("done")
    }

    private var framesAlreadyProcessed: Int = 0

    // ImageSequenceProcessor code

    public var configManager: ConfigManager
    public var callbacks: Callbacks

    public func set(callbacks: Callbacks) {
        self.callbacks = callbacks

        // call exisingFrameStateChangeCallback for number of frames not procssed
        if let callback = callbacks.exisingFrameStateChangeCallback {
            for i in 0..<framesAlreadyProcessed {
                callback(i)
            }
        }
    }
    
    public var numberLeft = NumberLeft()

    public func decrementNumberLeft() async {
        await self.numberLeft.decrement()
    }
    
    public var finalProcessor: FinalProcessor?    

    public let writeOutputFiles: Bool
    
    public let basename: String

    public let lastFrameNumber: Int?
    
    public init(with configManager: ConfigManager,
                callbacks: Callbacks,
                processExistingFiles: Bool,
                maxResidentImages: Int? = nil,
                writeOutputFiles: Bool = true,
                lastFrameNumber: Int? = nil) async throws
    {
        self.configManager = configManager
        self.callbacks = callbacks
        self.writeOutputFiles = writeOutputFiles
        self.lastFrameNumber = lastFrameNumber
        
        let config = await configManager.config()
        
        self.basename = config.basename

        self.processExistingFiles = processExistingFiles
        self.imageSequenceDirname = "\(config.imageSequencePath)/\(config.imageSequenceDirname)"
        self.outputDirname = "\(config.outputPath)/\(basename)"
        self.numberFinalProcessingNeighborsNeeded = config.numberFinalProcessingNeighborsNeeded
        self.imageSequence = try ImageSequence(dirname: imageSequenceDirname,
                                               supportedImageFileTypes: config.supportedImageFileTypes,
                                               maxImages: maxResidentImages)
        self.shouldProcess = [Bool](repeating: processExistingFiles, count: await imageSequence.filenames.count)
        self.existingOutputFiles = [Bool](repeating: false, count: await imageSequence.filenames.count)

        // only process the first set of frames
        if let lastFrameNumber,
           lastFrameNumber < self.shouldProcess.count
        {
            for i in lastFrameNumber..<self.shouldProcess.count {
                self.shouldProcess[i] = false
            }
        }

        self.methodList = try await assembleMethodList()

        let imageSequenceSize = /*self.*/await imageSequence.filenames.count

        self.remainingImagesClosure = { numberOfUnprocessed in
            if let updatable = callbacks.updatable {
                // log number of unprocessed images here
                let progressBarLength = config.progressBarLength
                Task {
                    await TaskWaiter.shared.task(priority: .userInitiated) {
                        let progress = Double(numberOfUnprocessed)/Double(imageSequenceSize)
                        await updatable.log(name: "unprocessed frames",
                                            message: reverseProgressBar(length: progressBarLength, progress: progress) + " \(numberOfUnprocessed) frames waiting to process",
                                            value: -1)
                    }
                }
            }
        }
        if let remainingImagesClosure {
            let methodList = self.methodList
            Task {
                await TaskWaiter.shared.task(priority: .medium) {
                    await methodList.set(removeClosure: remainingImagesClosure)
                    remainingImagesClosure(await methodList.count)
                }
            }
        }

        var numberOfFrames = imageSequenceSize
        
        if let lastFrameNumber { numberOfFrames = lastFrameNumber }
        
        finalProcessor = await FinalProcessor(with: config,
                                              callbacks: callbacks,
                                              numberOfFrames: numberOfFrames,
                                              shouldProcess: shouldProcess,
                                              imageSequence: imageSequence,
                                              isGUI: processExistingFiles)
    }

    public func run() async throws {

        guard let finalProcessor = finalProcessor
        else {
            Log.e("should have a processor")
            fatalError("no processor")
        }

        try await superRun()
        
        await finalProcessor.semaphore.wait()
    }

    // called at startup
    func startupHook() async throws {
        Log.d("startup hook starting")
        if imageWidth == nil ||
           imageHeight == nil ||
           imageBytesPerPixel == nil ||
           componentsPerPixel == nil
        {
            Log.d("loading first frame to get sizes")
            do {
                let imageInfo = try await imageSequence.getImageInfo()
                imageWidth = imageInfo.imageWidth
                imageHeight = imageInfo.imageHeight
                imageBytesPerPixel = imageInfo.imageBytesPerPixel
                componentsPerPixel = imageInfo.componentsPerPixel

                // in OutlierGroup.swift
                IMAGE_WIDTH = Double(imageInfo.imageWidth)
                IMAGE_HEIGHT = Double(imageInfo.imageHeight)

                Log.d("first frame to get sizes: imageWidth \(String(describing: imageWidth)) imageHeight \(String(describing: imageHeight)) imageBytesPerPixel \(String(describing: imageBytesPerPixel))")
                
            } catch {
                Log.e("first frame to get size: \(error)")
                throw("Could not load first image to get sequence resolution")
                // XXX this should be fatal
            }
        }

        let config = await configManager.config()
        
        if config.writeOutlierGroupFiles {
            // doesn't do mkdir -p, if a base dir is missing it just hangs :(
            mkdir(config.outlierOutputDirname) // XXX this can fail silently and pause the whole process :(
        }


        if config.writeOutlierGroupFiles          ||
           config.writeFramePreviewFiles          ||
           config.writeFrameProcessedPreviewFiles ||
           config.writeFrameThumbnailFiles
        {
            config.writeJson(named: "\(self.basename)-config.json")
        }
    }
    
    // called by the superclass to process each frame
    // called async check access to shared data
    func processFrame(number index: Int,
                      outputFilename: String,
                      baseName: String,
                      imageAccessor: ImageAccessor) async throws -> FrameAirplaneRemover
    {
//        if let shouldProcess,
//           index >= shouldProcess { continue }

        await numberLeft.increment()
        let frame = try await FrameAirplaneRemover(with: configManager,
                                                   width: imageWidth!,
                                                   height: imageHeight!,
                                                   componentsPerPixel: componentsPerPixel!,
                                                   callbacks: callbacks,
                                                   imageSequence: imageSequence,
                                                   atIndex: index,
                                                   outputFilename: outputFilename,
                                                   baseName: baseName,
                                                   writeOutputFiles: writeOutputFiles,
                                                   imageAccessor: imageAccessor)
        {
            // run when frame has completed processing
            await self.decrementNumberLeft()
        }

        // run separately from init for better state logging
        try await frame.setupOutliers()
        
        return frame
    }

    public var imageWidth: Int?
    public var imageHeight: Int?
    public var imageBytesPerPixel: Int? // XXX bad name
    public var componentsPerPixel: Int?

    func resultHook(with result: FrameAirplaneRemover) async {

        // send this frame to the final processor
        
        await finalProcessor?.add(frame: result)
    }
}
              
              
extension String {
    /// Returns a sanitized version of the string, replacing shell-unsafe characters with `_`.
    var sanitized: String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/")
        let ret = self.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.reduce("") { $0 + String($1) }
//        Log.d("FUCKING santizied \(self) = \(ret)")
        return ret
    }
}
