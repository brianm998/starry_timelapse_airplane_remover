import Foundation
import CoreGraphics
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

    // the name of the directory to create when writing frame thumbnails (small previews)
    let thumbnail_output_dirname: String

    public var final_processor: FinalProcessor?    

    public init(with config: Config,
                callbacks: Callbacks,
                processExistingFiles: Bool,
                maxResidentImages: Int? = nil) throws
    {
        self.config = config
        self.callbacks = callbacks

        var basename = "\(config.image_sequence_dirname)-ntar-v-\(config.ntar_version)"
        basename = basename.replacingOccurrences(of: ".", with: "_")
        test_paint_output_dirname = "\(config.test_paint_output_path)/\(basename)-test-paint"
        outlier_output_dirname = "\(config.outputPath)/\(basename)-outliers"
        preview_output_dirname = "\(config.outputPath)/\(basename)-previews"
        thumbnail_output_dirname = "\(config.outputPath)/\(basename)-thumbnails"


        try super.init(imageSequenceDirname: "\(config.image_sequence_path)/\(config.image_sequence_dirname)",
                       outputDirname: "\(config.outputPath)/\(basename)",
                       maxConcurrent: config.numConcurrentRenders,
                       supported_image_file_types: config.supported_image_file_types,
                       number_final_processing_neighbors_needed: config.number_final_processing_neighbors_needed,
                       processExistingFiles: processExistingFiles,
                       max_images: maxResidentImages);

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
    override func startup_hook() throws {
        if config.test_paint { try mkdir(test_paint_output_dirname) }
        if config.writeOutlierGroupFiles {
            try mkdir(outlier_output_dirname)
            config.writeJson(to: outlier_output_dirname)
        }
        if config.writeFramePreviewFiles {
            try mkdir(preview_output_dirname) 
        }
        if config.writeFrameThumbnailFiles {
            try mkdir(thumbnail_output_dirname)
        }
    }
    
    // called by the superclass to process each frame
    // called async check access to shared data
    override func processFrame(number index: Int,
                               image: PixelatedImage,
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
                                     test_paint_filename: test_paint_filename)

        return frame_plane_remover
    }

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
    
    // called async, check for access to shared data
    // this method does the first step of processing on each frame.
    // outlier pixel detection, outlier group detection and analysis
    // after running this method, each frame will have a good idea
    // of what outliers is has, and whether or not should paint over them.
    func createFrame(atIndex frame_index: Int,
                     otherFrameIndexes: [Int],
                     output_filename: String, // full path
                     base_name: String,       // just filename
                     test_paint_filename tpfo: String?) async throws -> FrameAirplaneRemover
    {
        var outlier_groups_for_this_frame: OutlierGroups?
        
        if self.config.writeOutlierGroupFiles {
            // look inside outlier_output_dirname for json
            // XXX check for 1_outlier.json file in outliers dir

            let frame_outliers_json_filename = "\(outlier_output_dirname)/\(frame_index)_outliers.json"
            
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
                } catch {
                    Log.e("frame \(frame_index) error decoding file \(frame_outliers_json_filename): \(error)")
                }
            }
        }

        if let _ = outlier_groups_for_this_frame  {
            Log.i("loading frame \(frame_index) with outlier groups from json")
        } else {
            Log.d("loading frame \(frame_index)")
        }
        
        return try await FrameAirplaneRemover(with: config,
                                              callbacks: callbacks,
                                              imageSequence: image_sequence,
                                              atIndex: frame_index,
                                              otherFrameIndexes: otherFrameIndexes,
                                              outputFilename: output_filename,
                                              testPaintFilename: tpfo,
                                              baseName: base_name,
                                              outlierOutputDirname: outlier_output_dirname,
                                              previewOutputDirname: preview_output_dirname,
                                              thumbnailOutputDirname: thumbnail_output_dirname,
                                              outlierGroups: outlier_groups_for_this_frame)
   }        
}
              
              

fileprivate let file_manager = FileManager.default
