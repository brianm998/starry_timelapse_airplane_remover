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

public class NighttimeAirplaneRemover: ImageSequenceProcessor<FrameAirplaneRemover> {

    public var config: Config
    public var callbacks: Callbacks

    public var numberLeft = NumberLeft()
    
    // the name of the directory to create when writing outlier group files
    let outlierOutputDirname: String

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

        // XXX duplicated in ImageAccessor :(
        let _basename = "\(config.imageSequenceDirname)-star-v-\(config.starVersion)-\(config.detectionType.rawValue)"
        self.basename = _basename.replacingOccurrences(of: ".", with: "_")
        outlierOutputDirname = "\(config.outputPath)/\(basename)-outliers"

        try super.init(imageSequenceDirname: "\(config.imageSequencePath)/\(config.imageSequenceDirname)",
                       outputDirname: "\(config.outputPath)/\(basename)",
                       supportedImageFileTypes: config.supportedImageFileTypes,
                       numberFinalProcessingNeighborsNeeded: config.numberFinalProcessingNeighborsNeeded,
                       processExistingFiles: processExistingFiles,
                       maxImages: maxResidentImages,
                       fullyProcess: fullyProcess);

        let imageSequenceSize = /*self.*/imageSequence.filenames.count

        if let imageSequenceSizeClosure = callbacks.imageSequenceSizeClosure {
            imageSequenceSizeClosure(imageSequenceSize)
        }
        
        self.remainingImagesClosure = { numberOfUnprocessed in
            if let updatable = callbacks.updatable {
                // log number of unprocessed images here
                TaskWaiter.shared.task(priority: .userInitiated) {
                    let progress = Double(numberOfUnprocessed)/Double(imageSequenceSize)
                    await updatable.log(name: "unprocessed frames",
                                        message: reverseProgressBar(length: config.progressBarLength, progress: progress) + " \(numberOfUnprocessed) frames waiting to process",
                                        value: -1)
                }
            }
        }
        if let remainingImagesClosure {
            TaskWaiter.shared.task(priority: .medium) {
                await self.methodList.set(removeClosure: remainingImagesClosure)
                remainingImagesClosure(await self.methodList.count)
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

    public override func run() async throws {

        guard let finalProcessor = finalProcessor
        else {
            Log.e("should have a processor")
            fatalError("no processor")
        }
        // setup the final processor 
        let finalProcessorTask = Task(priority: .high) {
            // XXX really should have the enter before the task
            // run the final processor as a single separate thread
            try await finalProcessor.run()
        }

        try await super.run()

        while(await numberLeft.hasMore()) {
            // XXX use semaphore
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        
        // XXX add semaphore here to track final progress?

        /*

         app can exit early, if there is nothing in the final queue
         and the input sequence no longer waiting to progress

         */
        
        _ = try await finalProcessorTask.value
    }

    // called by the superclass at startup
    override func startupHook() async throws {
        Log.d("startup hook starting")
        if imageWidth == nil ||
           imageHeight == nil ||
           imageBytesPerPixel == nil
        {
            Log.d("loading first frame to get sizes")
            do {
                let testImage = try await imageSequence.getImage(withName: imageSequence.filenames[0]).image()
                imageWidth = testImage.width
                imageHeight = testImage.height

                // in OutlierGroup.swift
                IMAGE_WIDTH = Double(testImage.width)
                IMAGE_HEIGHT = Double(testImage.height)

                imageBytesPerPixel = testImage.bytesPerPixel
                Log.d("first frame to get sizes: imageWidth \(String(describing: imageWidth)) imageHeight \(String(describing: imageHeight)) imageBytesPerPixel \(String(describing: imageBytesPerPixel))")
            } catch {
                Log.e("first frame to get size: \(error)")
                throw("Could not load first image to get sequence resolution")
                // XXX this should be fatal
            }
        }

        if config.writeOutlierGroupFiles {
            // doesn't do mkdir -p, if a base dir is missing it just hangs :(
            mkdir(outlierOutputDirname) // XXX this can fail silently and pause the whole process :(
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
    override func processFrame(number index: Int,
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
                                                   outlierOutputDirname: outlierOutputDirname,
                                                   fullyProcess: fullyProcess,
                                                   writeOutputFiles: writeOutputFiles)
        {
            // run when frame has completed processing
            await self.numberLeft.decrement()
        }

        // run separately from init for better state logging
        await frame.setupAlignment()
        try await frame.setupOutliers()
        
        return frame
    }

    public var imageWidth: Int?
    public var imageHeight: Int?
    public var imageBytesPerPixel: Int? // XXX bad name

    override func resultHook(with result: FrameAirplaneRemover) async {

        // send this frame to the final processor
        
        await finalProcessor?.add(frame: result)
    }
}
              
              
