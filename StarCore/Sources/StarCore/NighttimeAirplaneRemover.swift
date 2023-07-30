import Foundation
import CoreGraphics
import Cocoa
import Combine

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/



// this class handles removing airplanes from an entire sequence,
// delegating each frame to an instance of FrameAirplaneRemover
// and then using a FinalProcessor to finish processing

public class NighttimeAirplaneRemover: ImageSequenceProcessor<FrameAirplaneRemover> {

    public var config: Config
    public var callbacks: Callbacks

    // the name of the directory to create when writing outlier group files
    let outlierOutputDirname: String

    // the name of the directory to create when writing frame previews
    let previewOutputDirname: String

    // the name of the directory to create when writing processed frame previews
    let processedPreviewOutputDirname: String

    // the name of the directory to create when writing frame thumbnails (small previews)
    let thumbnailOutputDirname: String

    // where the star aligned images live
    let starAlignedSequenceDirname: String
    
    public var finalProcessor: FinalProcessor?    

    // are we running on the gui?
    public let isGUI: Bool

    public let writeOutputFiles: Bool
    
    public let basename: String
    
    let publisher = PassthroughSubject<FrameAirplaneRemover, Never>()

    public init(with config: Config,
                numConcurrentRenders: Int,
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

        let _basename = "\(config.imageSequenceDirname)-star-v-\(config.starVersion)"
        self.basename = _basename.replacingOccurrences(of: ".", with: "_")
        outlierOutputDirname = "\(config.outputPath)/\(basename)-outliers"
        previewOutputDirname = "\(config.outputPath)/\(basename)-previews"
        processedPreviewOutputDirname = "\(config.outputPath)/\(basename)-processed-previews"
        thumbnailOutputDirname = "\(config.outputPath)/\(basename)-thumbnails"
        starAlignedSequenceDirname = "\(config.outputPath)/\(basename)-aligned"
        
        try super.init(imageSequenceDirname: "\(config.imageSequencePath)/\(config.imageSequenceDirname)",
                       outputDirname: "\(config.outputPath)/\(basename)",
                       maxConcurrent: numConcurrentRenders,
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
                TaskWaiter.task(priority: .userInitiated) {
                    let progress = Double(numberOfUnprocessed)/Double(imageSequenceSize)
                    await updatable.log(name: "unprocessed frames",
                                        message: reverseProgressBar(length: config.progressBarLength, progress: progress) + " \(numberOfUnprocessed) frames waiting to process",
                                         value: -1)
                }
            }
        }
        if let remainingImagesClosure = remainingImagesClosure {
            TaskWaiter.task(priority: .medium) {
                await self.methodList.set(removeClosure: remainingImagesClosure)
                remainingImagesClosure(await self.methodList.count)
            }
        }

        var shouldProcess = [Bool](repeating: false, count: self.existingOutputFiles.count)
        for (index, outputFileExists) in self.existingOutputFiles.enumerated() {
            shouldProcess[index] = !outputFileExists
        }
        
        finalProcessor = await FinalProcessor(with: config,
                                              numConcurrentRenders: numConcurrentRenders,
                                              callbacks: callbacks,
                                              publisher: publisher,
                                              numberOfFrames: imageSequenceSize,
                                              shouldProcess: shouldProcess,
                                              dispatchGroup: dispatchGroup,
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
            }
        }
        if config.doStarAlignment {
            // where we keep aligned images
            try mkdir(starAlignedSequenceDirname)
        }
        if config.writeOutlierGroupFiles {
            // doesn't do mkdir -p, if a base dir is missing it just hangs :(
            try mkdir(outlierOutputDirname) // XXX this can fail silently and pause the whole process :(
        }
        if config.writeFramePreviewFiles {
            try mkdir(previewOutputDirname) 
        }

        if config.writeFrameProcessedPreviewFiles {
            try mkdir(processedPreviewOutputDirname)
        }

        if config.writeFrameThumbnailFiles {
            try mkdir(thumbnailOutputDirname)
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
        var otherFrameIndexes: [Int] = []
        
        if index > 0 {
            otherFrameIndexes.append(index-1)
        }
        if index < imageSequence.filenames.count - 1 {
            otherFrameIndexes.append(index+1)
        }

        // the other frames that we use to detect outliers and repaint from
        let framePlaneRemover =
          try await self.createFrame(atIndex: index,
                                     otherFrameIndexes: otherFrameIndexes,
                                     outputFilename: "\(self.outputDirname)/\(baseName)",
                                     baseName: baseName,
                                     imageWidth: imageWidth!,
                                     imageHeight: imageHeight!,
                                     imageBytesPerPixel: imageBytesPerPixel!)

        return framePlaneRemover
    }

    public var imageWidth: Int?
    public var imageHeight: Int?
    public var imageBytesPerPixel: Int? // XXX bad name

    override func resultHook(with result: FrameAirplaneRemover) async {

        // send this frame to the final processor
        
        publisher.send(result)
    }

    // called async, check for access to shared data
    // this method does the first step of processing on each frame.
    // outlier pixel detection, outlier group detection and analysis
    // after running this method, each frame will have a good idea
    // of what outliers is has, and whether or not should paint over them.
    func createFrame(atIndex frameIndex: Int,
                     otherFrameIndexes: [Int],
                     outputFilename: String, // full path
                     baseName: String,       // just filename
                     imageWidth: Int,
                     imageHeight: Int,
                     imageBytesPerPixel: Int) async throws -> FrameAirplaneRemover
    {
        var outlierGroupsForThisFrame: OutlierGroups?

        let loadOutliersFromFile: () async -> OutlierGroups? = {

            let startTime = Date().timeIntervalSinceReferenceDate
            var endTime1: Double = 0
            var startTime1: Double = 0

            let frame_outliers_new_binary_dirname = "\(self.outlierOutputDirname)/\(frameIndex)"
            if FileManager.default.fileExists(atPath: frame_outliers_new_binary_dirname) {
                do {
                    startTime1 = Date().timeIntervalSinceReferenceDate
                    outlierGroupsForThisFrame = try await OutlierGroups(at: frameIndex, from: frame_outliers_new_binary_dirname)
                    endTime1 = Date().timeIntervalSinceReferenceDate
                } catch {
                    Log.e("frame \(frameIndex) error decoding file \(frame_outliers_new_binary_dirname): \(error)")
                }
                Log.i("frame \(frameIndex) loaded from new binary dir")
                
            } 
            let end_time = Date().timeIntervalSinceReferenceDate
            Log.d("took \(end_time - startTime) seconds to load outlier group data for frame \(frameIndex)")
            Log.i("TIMES \(startTime1 - startTime) - \(endTime1 - startTime1) - \(end_time - endTime1) reading outlier group data for frame \(frameIndex)")
            
            if let _ = outlierGroupsForThisFrame  {
                Log.i("loading frame \(frameIndex) with outlier groups from file")
            } else {
                Log.d("loading frame \(frameIndex)")
            }
            return outlierGroupsForThisFrame
        }
        
        return try await FrameAirplaneRemover(with: config,
                                              width: imageWidth,
                                              height: imageHeight,
                                              bytesPerPixel: imageBytesPerPixel,
                                              callbacks: callbacks,
                                              imageSequence: imageSequence,
                                              atIndex: frameIndex,
                                              otherFrameIndexes: otherFrameIndexes,
                                              outputFilename: outputFilename,
                                              baseName: baseName,
                                              outlierOutputDirname: outlierOutputDirname,
                                              previewOutputDirname: previewOutputDirname,
                                              processedPreviewOutputDirname: processedPreviewOutputDirname,
                                              thumbnailOutputDirname: thumbnailOutputDirname,
                                              starAlignedSequenceDirname: starAlignedSequenceDirname,
                                              outlierGroupLoader: loadOutliersFromFile,
                                              fullyProcess: fullyProcess,
                                              writeOutputFiles: writeOutputFiles)
    }        
}
              
              
