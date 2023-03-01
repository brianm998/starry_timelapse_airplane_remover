import Foundation
import CoreGraphics
import BinaryCodable
import Cocoa

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/



// this class handles removing airplanes from an entire sequence,
// delegating each frame to an instance of FrameAirplaneRemover
// and then using a FinalProcessor to finish processing

@available(macOS 10.15, *) 
public class NighttimeAirplaneRemover: ImageSequenceProcessor<FrameAirplaneRemover> {

    public var config: Config
    public var callbacks: Callbacks

    // the name of the directory to create when writing test paint images
    let test_paint_output_dirname: String

    // the name of the directory to create when writing outlier group files
    let outlier_output_dirname: String

    // the name of the directory to create when writing frame previews
    let preview_output_dirname: String

    // the name of the directory to create when writing processed frame previews
    let processed_preview_output_dirname: String

    // the name of the directory to create when writing test paint frame previews
    let test_paint_preview_output_dirname: String

    // the name of the directory to create when writing frame thumbnails (small previews)
    let thumbnail_output_dirname: String

    public var final_processor: FinalProcessor?    

    // are we running on the gui?
    public var is_gui: Bool
    
    public init(with config: Config,
                callbacks: Callbacks,
                processExistingFiles: Bool,
                maxResidentImages: Int? = nil,
                fullyProcess: Bool = true,
                isGUI: Bool = false) throws
    {
        self.config = config
        self.callbacks = callbacks
        self.is_gui = isGUI
        
        var basename = "\(config.image_sequence_dirname)-ntar-v-\(config.ntar_version)"
        basename = basename.replacingOccurrences(of: ".", with: "_")
        test_paint_output_dirname = "\(config.test_paint_output_path)/\(basename)-test-paint"
        outlier_output_dirname = "\(config.outputPath)/\(basename)-outliers"
        preview_output_dirname = "\(config.outputPath)/\(basename)-previews"
        processed_preview_output_dirname = "\(config.outputPath)/\(basename)-processed-previews"
        test_paint_preview_output_dirname = "\(config.outputPath)/\(basename)-test-paint-previews"
        thumbnail_output_dirname = "\(config.outputPath)/\(basename)-thumbnails"

        try super.init(imageSequenceDirname: "\(config.image_sequence_path)/\(config.image_sequence_dirname)",
                       outputDirname: "\(config.outputPath)/\(basename)",
                       maxConcurrent: config.numConcurrentRenders,
                       supported_image_file_types: config.supported_image_file_types,
                       number_final_processing_neighbors_needed: config.number_final_processing_neighbors_needed,
                       processExistingFiles: processExistingFiles,
                       max_images: maxResidentImages,
                       fullyProcess: fullyProcess);

        let image_sequence_size = /*self.*/image_sequence.filenames.count

        if let imageSequenceSizeClosure = callbacks.imageSequenceSizeClosure {
            imageSequenceSizeClosure(image_sequence_size)
        }
        
        self.remaining_images_closure = { number_of_unprocessed in
            if let updatable = callbacks.updatable {
                // log number of unprocessed images here
                Task(priority: .userInitiated) {
                    let progress = Double(number_of_unprocessed)/Double(image_sequence_size)
                    await updatable.log(name: "unprocessed frames",
                                        message: reverse_progress_bar(length: config.progress_bar_length, progress: progress) + " \(number_of_unprocessed) frames waiting to process",
                                         value: -1)
                }
            }
        }
        if let remaining_images_closure = remaining_images_closure {
            Task(priority: .medium) {
                await self.method_list.set(removeClosure: remaining_images_closure)
                remaining_images_closure(await self.method_list.count)
            }
        }
        
        let processor = FinalProcessor(with: config,
                                       callbacks: callbacks,
                                       numberOfFrames: image_sequence_size,
                                       dispatchGroup: dispatchGroup,
                                       imageSequence: image_sequence)


        final_processor = processor
    }

    public override func run() throws {

        if let final_processor = final_processor {
            // setup the final processor and queue
            let final_queue_dispatch_name = "FinalQueue"
            Task(priority: .high) {
                // XXX really should have the enter before the task
                await self.dispatchGroup.enter(final_queue_dispatch_name)
                // the final queue runs a separate task group for processing 
                try await final_processor.final_queue.start()
                await self.dispatchGroup.leave(final_queue_dispatch_name)
            }
            let final_processor_dispatch_name = "FinalProcessor"
            Task(priority: .high) {
                // XXX really should have the enter before the task
                await self.dispatchGroup.enter(final_processor_dispatch_name) 
                // run the final processor as a single separate thread
                var should_process = [Bool](repeating: false, count: self.existing_output_files.count)
                for (index, output_file_exists) in self.existing_output_files.enumerated() {
                    should_process[index] = !output_file_exists
                }
                try await final_processor.run(shouldProcess: should_process)
                await self.dispatchGroup.leave(final_processor_dispatch_name)
            }
        } else {
            Log.e("should have a processor")
            fatalError("no processor")
        }
        try super.run()
    }

    // called by the superclass at startup
    override func startup_hook() async throws {
        Log.d("startup hook starting")
        if image_width == nil ||
           image_height == nil ||
           image_bytesPerPixel == nil
        {
            Log.d("loading first frame to get sizes")
            do {
                let test_image = try await image_sequence.getImage(withName: image_sequence.filenames[0]).image()
                image_width = test_image.width
                image_height = test_image.height

                // in OutlierGroup.swift
                IMAGE_WIDTH = Double(test_image.width)
                IMAGE_HEIGHT = Double(test_image.height)

                image_bytesPerPixel = test_image.bytesPerPixel
                Log.d("first frame to get sizes: image_width \(image_width) image_height \(image_height) image_bytesPerPixel \(image_bytesPerPixel)")
            } catch {
                Log.e("first frame to get size: \(error)")
            }
        }
        Log.d("1")
        if config.test_paint {
            try mkdir(test_paint_output_dirname)
        }
        Log.d("2")
        if config.writeOutlierGroupFiles {
            Log.d("2a \(outlier_output_dirname)")
            // doesn't do mkdir -p, if a base dir is missing it just hangs :(
            try mkdir(outlier_output_dirname) // XXX this can fail silently and pause the whole process :(
            Log.d("2b")
            config.writeJson(to: outlier_output_dirname)
            Log.d("2c")
        }
        Log.d("3")
        if config.writeFramePreviewFiles {
            Log.d("3a")
            try mkdir(preview_output_dirname) 
            Log.d("3b")
        }

        Log.d("4")
        if config.writeFrameProcessedPreviewFiles {
            try mkdir(processed_preview_output_dirname)
        }
        Log.d("5")

        if config.writeFrameTestPaintPreviewFiles {
            try mkdir(test_paint_preview_output_dirname)
        }
        Log.d("6")
        
        if config.writeFrameThumbnailFiles {
            try mkdir(thumbnail_output_dirname)
        }
        Log.d("startup hook done")
    }
    
    // called by the superclass to process each frame
    // called async check access to shared data
    override func processFrame(number index: Int,
                               output_filename: String,
                               base_name: String) async throws -> FrameAirplaneRemover
    {
        //Log.e("full_image_path \(full_image_path)")
        // load images outside the main thread

        var otherFrameIndexes: [Int] = []
        
        if index > 0 {
            otherFrameIndexes.append(index-1)
        }
        if index < image_sequence.filenames.count - 1 {
            otherFrameIndexes.append(index+1)
        }
        
        let test_paint_filename = self.config.test_paint ?
          "\(self.test_paint_output_dirname)/\(base_name)" : nil

        
        // the other frames that we use to detect outliers and repaint from
        let frame_plane_remover =
          try await self.createFrame(atIndex: index,
                                     otherFrameIndexes: otherFrameIndexes,
                                     output_filename: "\(self.output_dirname)/\(base_name)",
                                     base_name: base_name,
                                     test_paint_filename: test_paint_filename,
                                     image_width: image_width!,
                                     image_height: image_height!,
                                     image_bytesPerPixel: image_bytesPerPixel!)

        return frame_plane_remover
    }

    public var image_width: Int?
    public var image_height: Int?
    public var image_bytesPerPixel: Int? // XXX bad name

    override func result_hook(with result: FrameAirplaneRemover) async {

        Log.d("result hook for frame \(result.frame_index)")
        
        // next step is to add this frame_plane_remover to an array of optionals
        // indexed by frame number
        // then create a new class that uses the diapatchGroup to keep the process alive
        // and processes sequentially through them as they are available, doing
        // analysis of the outlier groups between frames and making them look better
        // by doing further analysis and cleanup

        if let final_processor = final_processor {
            await final_processor.add(frame: result)
        } else {
            fatalError("should not happen")
        }
    }

    var last_final_log: TimeInterval = 0
    
    // balance the total number of active processes, and favor the end of the process
    // so that we don't experience backup and overload memory
    override func maxConcurrentRenders() async -> Int {
        var ret = max_concurrent_renders
        if let final_processor = final_processor {
            let final_is_working = await final_processor.isWorking
            let final_frames_unprocessed = await final_processor.framesBetween
            let final_queue_size = await final_processor.final_queue.number_running.currentValue()
            let current_running = await self.number_running.currentValue()
            if final_frames_unprocessed - number_final_processing_neighbors_needed > 0 {
                let signed_ret: Int = (Int(max_concurrent_renders) - Int(final_queue_size))-final_frames_unprocessed
                if signed_ret < 0 {
                    ret = 0
                } else if signed_ret > 0 {
                    ret = signed_ret
                } else {
                    ret = 1
                }
            } else {
                ret = max_concurrent_renders - Int(final_queue_size)
            }
            let num_images = await image_sequence.numberOfResidentImages

            let now = Date().timeIntervalSince1970

            if now - last_final_log > 10 {
                Log.v("final_is_working \(final_is_working) current_running \(current_running) final_queue_size \(final_queue_size) final_frames_unprocessed \(final_frames_unprocessed) max_renders \(ret) images loaded: \(num_images)")
                last_final_log = now
            }
            
        }
        Log.v("max_concurrent_renders \(ret)")
        return ret
    }
    
    // called async, check for access to shared data
    // this method does the first step of processing on each frame.
    // outlier pixel detection, outlier group detection and analysis
    // after running this method, each frame will have a good idea
    // of what outliers is has, and whether or not should paint over them.
    func createFrame(atIndex frame_index: Int,
                     otherFrameIndexes: [Int],
                     output_filename: String, // full path
                     base_name: String,       // just filename
                     test_paint_filename tpfo: String?,
                     image_width: Int,
                     image_height: Int,
                     image_bytesPerPixel: Int) async throws -> FrameAirplaneRemover
    {
        var outlier_groups_for_this_frame: OutlierGroups?

        let loadOutliersFromFile: () async -> OutlierGroups? = {

            let start_time = Date().timeIntervalSinceReferenceDate
            var end_time_1: Double = 0
            var start_time_1: Double = 0

            // look inside outlier_output_dirname for json
            // XXX check for 1_outlier.json file in outliers dir
            
            let frame_outliers_binary_filename = "\(self.outlier_output_dirname)/\(frame_index)_outliers.bin"

            Log.i("frame \(frame_index) looking for binary file \(frame_outliers_binary_filename)")
            
            if file_manager.fileExists(atPath: frame_outliers_binary_filename) {
                Log.i("frame \(frame_index) found binary file \(frame_outliers_binary_filename)")
            
                do {
                    let url = NSURL(fileURLWithPath: frame_outliers_binary_filename, isDirectory: false) as URL
                    let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url))
                    let decoder = BinaryDecoder()
                    
                    start_time_1 = Date().timeIntervalSinceReferenceDate
                    outlier_groups_for_this_frame = try decoder.decode(OutlierGroups.self, from: data)
                    end_time_1 = Date().timeIntervalSinceReferenceDate
                    Log.d("binary decode took \(end_time_1 - start_time_1) seconds to load binary outlier group data for frame \(frame_index)")
                    Log.d("loading frame \(frame_index) with outlier groups from binary file")
                } catch {
                    Log.e("frame \(frame_index) error decoding file \(frame_outliers_binary_filename): \(error)")
                }
            } else {
                Log.i("frame \(frame_index) binary file \(frame_outliers_binary_filename) does not exist")
                // try json
                
                
                let frame_outliers_json_filename = "\(self.outlier_output_dirname)/\(frame_index)_outliers.json"
                
                if file_manager.fileExists(atPath: frame_outliers_json_filename) {
                    do {
                        let url = NSURL(fileURLWithPath: frame_outliers_json_filename, isDirectory: false) as URL
                        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url))
                        let decoder = JSONDecoder()
                        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
                          positiveInfinity: "inf",
                          negativeInfinity: "-inf",
                          nan: "nan")
                        
                        outlier_groups_for_this_frame = try decoder.decode(OutlierGroups.self, from: data)
                        
                        Log.d("loading frame \(frame_index) with outlier groups from json file")
                    } catch {
                        Log.e("frame \(frame_index) error decoding file \(frame_outliers_json_filename): \(error)")
                    }
                }
            }
            let end_time = Date().timeIntervalSinceReferenceDate
            Log.d("took \(end_time - start_time) seconds to load outlier group data for frame \(frame_index)")
            Log.d("TIMES \(start_time_1 - start_time) - \(end_time_1 - start_time_1) - \(end_time - end_time_1) reading outlier group data for frame \(frame_index)")
            
            
            if let _ = outlier_groups_for_this_frame  {
                Log.i("loading frame \(frame_index) with outlier groups from file")
            } else {
                Log.d("loading frame \(frame_index)")
            }
            return outlier_groups_for_this_frame
        }
        
        return try await FrameAirplaneRemover(with: config,
                                              width: image_width,
                                              height: image_height,
                                              bytesPerPixel: image_bytesPerPixel,
                                              callbacks: callbacks,
                                              imageSequence: image_sequence,
                                              atIndex: frame_index,
                                              otherFrameIndexes: otherFrameIndexes,
                                              outputFilename: output_filename,
                                              testPaintFilename: tpfo,
                                              baseName: base_name,
                                              outlierOutputDirname: outlier_output_dirname,
                                              previewOutputDirname: preview_output_dirname,
                                              processedPreviewOutputDirname: processed_preview_output_dirname,
                                              testPaintPreviewOutputDirname: test_paint_preview_output_dirname,
                                              thumbnailOutputDirname: thumbnail_output_dirname,
                                              outlierGroupLoader: loadOutliersFromFile,
                                              fullyProcess: fully_process,
                                              isGUI: is_gui)
   }        
}
              
              

fileprivate let file_manager = FileManager.default
