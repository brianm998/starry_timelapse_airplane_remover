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
class NighttimeAirplaneRemover: ImageSequenceProcessor<FrameAirplaneRemover> {
        
    let test_paint_output_dirname: String

    let outlier_output_dirname: String

    // the following properties get included into the output videoname
    
    // difference between same pixels on different frames to consider an outlier
    let max_pixel_distance: UInt16

    // groups smaller than this are ignored
    let min_group_size: Int

    // groups larger than this are assumed to be airplanes and painted over
    let assume_airplane_size: Int
    
    // write out test paint images
    let test_paint: Bool

    // write out individual outlier group images
    let should_write_outlier_group_files: Bool
    
    var final_processor: FinalProcessor?    

    init(imageSequenceName image_sequence_name: String,
         imageSequencePath image_sequence_path: String,
         outputPath output_path: String,
         maxConcurrent max_concurrent: UInt = 5,
         maxPixelDistance max_pixel_percent: Double,
         minGroupSize: Int,
         assumeAirplaneSize: Int,
         testPaint: Bool = false,
         writeOutlierGroupFiles: Bool = false,
         givenFilenames given_filenames: [String]? = nil) throws
    {
        
        self.max_pixel_distance = UInt16(max_pixel_percent/100*0xFFFF) // XXX 16 bit hardcode
        self.test_paint = testPaint
        self.should_write_outlier_group_files = writeOutlierGroupFiles
        self.min_group_size = minGroupSize
        self.assume_airplane_size = assumeAirplaneSize

        let formatted_pixel_distance = String(format: "%0.1f", max_pixel_percent)        

        var basename = "\(image_sequence_name)-ntar-v-\(ntar_version)-\(formatted_pixel_distance)-\(minGroupSize)-\(assumeAirplaneSize)"
        basename = basename.replacingOccurrences(of: ".", with: "_")
        test_paint_output_dirname = "\(output_path)/\(basename)-test-paint"
        outlier_output_dirname = "\(output_path)/\(basename)-outliers"
        
        try super.init(imageSequenceDirname: "\(image_sequence_path)/\(image_sequence_name)",
                       outputDirname: "\(output_path)/\(basename)",
                       maxConcurrent: max_concurrent,
                       givenFilenames: given_filenames)

        let processor = FinalProcessor(numberOfFrames: self.image_sequence.filenames.count,
                                       maxConcurrent: max_concurrent_renders,
                                       dispatchGroup: dispatchGroup,
                                       imageSequence: image_sequence)
        
        final_processor = processor
    }

    override func run() throws {

        // setup the final processor and queue
        Task {
            let dispatch_name = "FinalProcessorTaskGroup"
            await self.dispatchGroup.enter(dispatch_name) // XXX shouldn't really be here ...
            try await withThrowingTaskGroup(of: Void.self) { group in

                // setup a task group for the final queue and final processor
                if let final_processor = final_processor {
                    group.addTask {
                        // the final queue runs a separate task group for processing 
                        try await final_processor.final_queue.start()
                    }
                    group.addTask { 
                        // run the final processor as a single separate thread
                        var should_process = [Bool](repeating: false, count: self.existing_output_files.count)
                        for (index, output_file_exists) in self.existing_output_files.enumerated() {
                            should_process[index] = !output_file_exists
                        }
                        try await final_processor.run(shouldProcess: should_process)
                    }
                } else {
                    Log.e("should have a processor")
                    fatalError("no processor")
                }
                try await group.waitForAll()
                await self.dispatchGroup.leave(dispatch_name)
            }
        }
      
        try super.run()
    }

    // called by the superclass at startup
    override func startup_hook() throws {
        if test_paint { try mkdir(test_paint_output_dirname) }
        if should_write_outlier_group_files {
            try mkdir(outlier_output_dirname)
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
        
        let test_paint_filename = self.test_paint ?
                                  "\(self.test_paint_output_dirname)/\(base_name)" : nil
        
        // the other frames that we use to detect outliers and repaint from
        let frame_plane_remover =
          try await self.createFrame(atIndex: index,
                                 otherFrameIndexes: otherFrameIndexes,
                                 output_filename: "\(self.output_dirname)/\(base_name)",
                                 test_paint_filename: test_paint_filename)

        return frame_plane_remover
    }

    override func result_hook(with result: FrameAirplaneRemover) async {

        Log.d("result hook with result \(result)")
        
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
    override func maxConcurrentRenders() async -> UInt {
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
                    ret = UInt(signed_ret)
                } else {
                    ret = 1
                }
            } else {
                ret = max_concurrent_renders - final_queue_size
            }
            let num_images = await image_sequence.numberOfResidentImages

            let now = Date().timeIntervalSince1970

            if now - last_final_log > 10 {
                Log.d("final_is_working \(final_is_working) current_running \(current_running) final_queue_size \(final_queue_size) final_frames_unprocessed \(final_frames_unprocessed) max_renders \(ret) images loaded: \(num_images)")
                last_final_log = now
            }
            
        }
        //Log.d("max_concurrent_renders \(ret)")
        return ret
    }
    
    // called async, check for access to shared data
    // this method does the first step of processing on each frame.
    // outlier pixel detection, outlier group detection and analysis
    // after running this method, each frame will have a good idea
    // of what outliers is has, and whether or not should paint over them.
    func createFrame(atIndex frame_index: Int,
                     otherFrameIndexes: [Int],
                     output_filename: String,
                     test_paint_filename tpfo: String?) async throws -> FrameAirplaneRemover
    {
        let frame = try await FrameAirplaneRemover(imageSequence: image_sequence,
                                                   atIndex: frame_index,
                                                   otherFrameIndexes: otherFrameIndexes,
                                                   outputFilename: output_filename,
                                                   testPaintFilename: tpfo,
                                                   outlierOutputDirname: outlier_output_dirname,
                                                   maxPixelDistance: max_pixel_distance,
                                                   minGroupSize: min_group_size)
        
        if should_write_outlier_group_files {
            await frame.writeOutlierGroupFiles()
        }
        
        return frame
   }        

}
              
              
