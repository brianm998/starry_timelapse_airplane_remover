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
    let processed_previewOutputDirname: String

    // the name of the directory to create when writing frame thumbnails (small previews)
    let thumbnailOutputDirname: String

    public var final_processor: FinalProcessor?    

    // are we running on the gui?
    public let isGUI: Bool

    public let writeOutputFiles: Bool
    
    public let basename: String
    
    let publisher = PassthroughSubject<FrameAirplaneRemover, Never>()

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

        let _basename = "\(config.imageSequenceDirname)-star-v-\(config.starVersion)"
        self.basename = _basename.replacingOccurrences(of: ".", with: "_")
        outlierOutputDirname = "\(config.outputPath)/\(basename)-outliers"
        previewOutputDirname = "\(config.outputPath)/\(basename)-previews"
        processed_previewOutputDirname = "\(config.outputPath)/\(basename)-processed-previews"
        thumbnailOutputDirname = "\(config.outputPath)/\(basename)-thumbnails"

        try super.init(imageSequenceDirname: "\(config.imageSequencePath)/\(config.imageSequenceDirname)",
                       outputDirname: "\(config.outputPath)/\(basename)",
                       maxConcurrent: config.numConcurrentRenders,
                       supportedImageFileTypes: config.supportedImageFileTypes,
                       numberFinalProcessingNeighborsNeeded: config.numberFinalProcessingNeighborsNeeded,
                       processExistingFiles: processExistingFiles,
                       maxImages: maxResidentImages,
                       fullyProcess: fullyProcess);

        let imageSequence_size = /*self.*/imageSequence.filenames.count

        if let imageSequenceSizeClosure = callbacks.imageSequenceSizeClosure {
            imageSequenceSizeClosure(imageSequence_size)
        }
        
        self.remainingImagesClosure = { number_of_unprocessed in
            if let updatable = callbacks.updatable {
                // log number of unprocessed images here
                Task(priority: .userInitiated) {
                    let progress = Double(number_of_unprocessed)/Double(imageSequence_size)
                    await updatable.log(name: "unprocessed frames",
                                        message: reverse_progress_bar(length: config.progressBarLength, progress: progress) + " \(number_of_unprocessed) frames waiting to process",
                                         value: -1)
                }
            }
        }
        if let remainingImagesClosure = remainingImagesClosure {
            Task(priority: .medium) {
                await self.methodList.set(removeClosure: remainingImagesClosure)
                remainingImagesClosure(await self.methodList.count)
            }
        }

        var shouldProcess = [Bool](repeating: false, count: self.existingOutputFiles.count)
        for (index, output_file_exists) in self.existingOutputFiles.enumerated() {
            shouldProcess[index] = !output_file_exists
        }
        
        final_processor = await FinalProcessor(with: config,
                                           callbacks: callbacks,
                                           publisher: publisher,
                                           numberOfFrames: imageSequence_size,
                                           shouldProcess: shouldProcess,
                                           dispatchGroup: dispatchGroup,
                                           imageSequence: imageSequence,
                                           isGUI: isGUI || processExistingFiles)
    }

    public override func run() async throws {

        guard let final_processor = final_processor
        else {
            Log.e("should have a processor")
            fatalError("no processor")
        }
        // setup the final processor 
        let finalProcessorTask = Task(priority: .high) {
            // XXX really should have the enter before the task
            // run the final processor as a single separate thread
            try await final_processor.run()
        }

        try await super.run()
        _ = try await finalProcessorTask.value
    }

    // called by the superclass at startup
    override func startupHook() async throws {
        Log.d("startup hook starting")
        if imageWidth == nil ||
           imageHeight == nil ||
           image_bytesPerPixel == nil
        {
            Log.d("loading first frame to get sizes")
            do {
                let test_image = try await imageSequence.getImage(withName: imageSequence.filenames[0]).image()
                imageWidth = test_image.width
                imageHeight = test_image.height

                // in OutlierGroup.swift
                IMAGE_WIDTH = Double(test_image.width)
                IMAGE_HEIGHT = Double(test_image.height)

                image_bytesPerPixel = test_image.bytesPerPixel
                Log.d("first frame to get sizes: imageWidth \(String(describing: imageWidth)) imageHeight \(String(describing: imageHeight)) image_bytesPerPixel \(String(describing: image_bytesPerPixel))")
            } catch {
                Log.e("first frame to get size: \(error)")
            }
        }
        if config.writeOutlierGroupFiles {
            // doesn't do mkdir -p, if a base dir is missing it just hangs :(
            try mkdir(outlierOutputDirname) // XXX this can fail silently and pause the whole process :(
        }
        if config.writeFramePreviewFiles {
            try mkdir(previewOutputDirname) 
        }

        if config.writeFrameProcessedPreviewFiles {
            try mkdir(processed_previewOutputDirname)
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
        //Log.e("full_image_path \(full_image_path)")
        // load images outside the main thread

        var otherFrameIndexes: [Int] = []
        
        if index > 0 {
            otherFrameIndexes.append(index-1)
        }
        if index < imageSequence.filenames.count - 1 {
            otherFrameIndexes.append(index+1)
        }
        
        // the other frames that we use to detect outliers and repaint from
        let frame_plane_remover =
          try await self.createFrame(atIndex: index,
                                     otherFrameIndexes: otherFrameIndexes,
                                     outputFilename: "\(self.outputDirname)/\(baseName)",
                                     baseName: baseName,
                                     imageWidth: imageWidth!,
                                     imageHeight: imageHeight!,
                                     image_bytesPerPixel: image_bytesPerPixel!)

        return frame_plane_remover
    }

    public var imageWidth: Int?
    public var imageHeight: Int?
    public var image_bytesPerPixel: Int? // XXX bad name

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
                     image_bytesPerPixel: Int) async throws -> FrameAirplaneRemover
    {
        var outlierGroupsForThisFrame: OutlierGroups?

        let loadOutliersFromFile: () async -> OutlierGroups? = {

            let start_time = Date().timeIntervalSinceReferenceDate
            var end_time_1: Double = 0
            var start_time_1: Double = 0

            let frame_outliers_new_binary_dirname = "\(self.outlierOutputDirname)/\(frameIndex)"
            if file_manager.fileExists(atPath: frame_outliers_new_binary_dirname) {
                do {
                    start_time_1 = Date().timeIntervalSinceReferenceDate
                    outlierGroupsForThisFrame = try await OutlierGroups(at: frameIndex, from: frame_outliers_new_binary_dirname)
                    end_time_1 = Date().timeIntervalSinceReferenceDate
                } catch {
                    Log.e("frame \(frameIndex) error decoding file \(frame_outliers_new_binary_dirname): \(error)")
                }
                Log.i("frame \(frameIndex) loaded from new binary dir")
                
            } 
            let end_time = Date().timeIntervalSinceReferenceDate
            Log.d("took \(end_time - start_time) seconds to load outlier group data for frame \(frameIndex)")
            Log.i("TIMES \(start_time_1 - start_time) - \(end_time_1 - start_time_1) - \(end_time - end_time_1) reading outlier group data for frame \(frameIndex)")
            
            
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
                                          bytesPerPixel: image_bytesPerPixel,
                                          callbacks: callbacks,
                                          imageSequence: imageSequence,
                                          atIndex: frameIndex,
                                          otherFrameIndexes: otherFrameIndexes,
                                          outputFilename: outputFilename,
                                          baseName: baseName,
                                          outlierOutputDirname: outlierOutputDirname,
                                          previewOutputDirname: previewOutputDirname,
                                          processedPreviewOutputDirname: processed_previewOutputDirname,
                                          thumbnailOutputDirname: thumbnailOutputDirname,
                                          outlierGroupLoader: loadOutliersFromFile,
                                          fullyProcess: fullyProcess,
                                          writeOutputFiles: writeOutputFiles)
   }        
}
              
              

fileprivate let file_manager = FileManager.default
