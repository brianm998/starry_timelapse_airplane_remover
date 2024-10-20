import Foundation
import CoreGraphics
import logging
import Cocoa

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/



// this class handles removing airplanes from an entire sequence,
// delegating each frame to an instance of FrameAirplaneRemover
// and then using a FinalProcessor to finish processing

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

    public func frameCount() -> Int { imageSequence.filenames.count }
    
    var shouldProcess: [Bool] = []       // indexed by frame number
    var existingOutputFiles: [Bool] = [] // indexed by frame number

    var remainingImagesClosure: (@Sendable (Int) -> Void)?

    // if this is true, outliers are detected, inter-frame processing is done
    // if false, frames are handed back without outliers detected
    let fullyProcess: Bool

    let processExistingFiles: Bool
    
    func assembleMethodList() throws -> MethodList<FrameAirplaneRemover> {
        /*
           read all existing output files 
           sort them into frame order
           remove ones within numberFinalProcessingNeighborsNeeded frames of holes
           make sure these re-runs doesn't bork on existing files later
           only process below based upon this info
        */
    
        var _methodList: [Int : @Sendable () async throws -> FrameAirplaneRemover] = [:]
        
        for (index, imageFilename) in imageSequence.filenames.enumerated() {
            let basename = removePath(fromString: imageFilename)
            let outputFilename = "\(outputDirname)/\(basename)"
            if FileManager.default.fileExists(atPath: outputFilename) {
                existingOutputFiles[index] = true
            }                                  
        }
        
        for (index, outputFileAlreadyExists) in existingOutputFiles.enumerated() {
            if !outputFileAlreadyExists {
                var startIdx = index - numberFinalProcessingNeighborsNeeded
                var endIdx = index + numberFinalProcessingNeighborsNeeded
                if startIdx < 0 { startIdx = 0 }
                if endIdx >= existingOutputFiles.count {
                    endIdx = existingOutputFiles.count - 1
                }
                for i in startIdx ... endIdx {
                    shouldProcess[i] = true
                }
            }
        }

        // XX VVV XX appears to be the root of the frameIndex starting at zero 
        for (index, imageFilename) in self.imageSequence.filenames.enumerated() {
            let filename = self.imageSequence.filenames[index]
            let basename = removePath(fromString: filename)
            let outputFilename = "\(outputDirname)/\(basename)"
            if shouldProcess[index] {
                _methodList[index] = {
                    // this method is run async later
                    Log.i("loading \(imageFilename) for frame \(index)")
                    //let image = await self.imageSequence.getImage(withName: imageFilename)
                    return try await self.processFrame(number: index,
                                                       outputFilename: outputFilename,
                                                       baseName: basename) 
                }
            } else {
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



    // ImageSequenceProcessor code

    public var config: Config
    public var callbacks: Callbacks

    public func set(callbacks: Callbacks) {
        self.callbacks = callbacks
    }
    
    public var numberLeft = NumberLeft()

    public func decrementNumberLeft() async {
        await self.numberLeft.decrement()
    }
    
    public var finalProcessor: FinalProcessor?    

    // are we running on the gui?
    public let isGUI: Bool

    public let writeOutputFiles: Bool
    
    public let basename: String
    
    public init(with config: Config,
                callbacks: Callbacks,
                processExistingFiles: Bool,
                maxResidentImages: Int? = nil,
                fullyProcess: Bool = true,
                isGUI: Bool = false,
                writeOutputFiles: Bool = true) async throws
    {
        self.config = config
        self.callbacks = callbacks
        self.isGUI = isGUI     // XXX make this better
        self.writeOutputFiles = writeOutputFiles

        self.basename = config.basename

        self.processExistingFiles = processExistingFiles
        self.imageSequenceDirname = "\(config.imageSequencePath)/\(config.imageSequenceDirname)"
        self.outputDirname = "\(config.outputPath)/\(basename)"
        self.numberFinalProcessingNeighborsNeeded = config.numberFinalProcessingNeighborsNeeded
        self.imageSequence = try ImageSequence(dirname: imageSequenceDirname,
                                               supportedImageFileTypes: config.supportedImageFileTypes,
                                               maxImages: maxResidentImages)
        self.shouldProcess = [Bool](repeating: processExistingFiles, count: imageSequence.filenames.count)
        self.existingOutputFiles = [Bool](repeating: false, count: imageSequence.filenames.count)
        self.fullyProcess = fullyProcess
        self.methodList = try assembleMethodList()

        let imageSequenceSize = /*self.*/imageSequence.filenames.count

        if let imageSequenceSizeClosure = callbacks.imageSequenceSizeClosure {
            imageSequenceSizeClosure(imageSequenceSize)
        }
        
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

        var shouldProcess = [Bool](repeating: false, count: self.existingOutputFiles.count)
        for (index, outputFileExists) in self.existingOutputFiles.enumerated() {
            shouldProcess[index] = !outputFileExists
        }
        
        finalProcessor = await FinalProcessor(with: config,
                                              callbacks: callbacks,
                                              numberOfFrames: imageSequenceSize,
                                              shouldProcess: shouldProcess,
                                              imageSequence: imageSequence,
                                              isGUI: isGUI || processExistingFiles)
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
           imageBytesPerPixel == nil
        {
            Log.d("loading first frame to get sizes")
            do {
                let imageInfo = try await imageSequence.getImageInfo()
                imageWidth = imageInfo.imageWidth
                imageHeight = imageInfo.imageHeight
                imageBytesPerPixel = imageInfo.imageBytesPerPixel

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
                      baseName: String) async throws -> FrameAirplaneRemover
    {
        await numberLeft.increment()
        let frame = try await FrameAirplaneRemover(with: config,
                                                   width: imageWidth!,
                                                   height: imageHeight!,
                                                   bytesPerPixel: imageBytesPerPixel!,
                                                   callbacks: callbacks,
                                                   imageSequence: imageSequence,
                                                   atIndex: index,
                                                   outputFilename: outputFilename,
                                                   baseName: baseName,
                                                   outlierOutputDirname: config.outlierOutputDirname,
                                                   fullyProcess: fullyProcess,
                                                   writeOutputFiles: writeOutputFiles)
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

    func resultHook(with result: FrameAirplaneRemover) async {

        // send this frame to the final processor
        
        await finalProcessor?.add(frame: result)
    }
}
              
              
