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

    init(imageSequenceDirname image_sequence_dirname: String,
         maxConcurrent max_concurrent: UInt = 5,
         maxPixelDistance max_pixel_percent: Double,
         minGroupSize: Int,
         assumeAirplaneSize: Int,
         testPaint: Bool = false,
         writeOutlierGroupFiles: Bool = false,
         givenFilenames given_filenames: [String]? = nil) throws
    {
        
        self.max_pixel_distance = UInt16(max_pixel_percent/100*0xFFFF)
        self.test_paint = testPaint
        self.should_write_outlier_group_files = writeOutlierGroupFiles
        self.min_group_size = minGroupSize
        self.assume_airplane_size = assumeAirplaneSize

        let formatted_pixel_distance = String(format: "%0.1f", max_pixel_percent)        
        
        var basename = "\(image_sequence_dirname)-ntar-v-\(ntar_version)-\(formatted_pixel_distance)-\(minGroupSize)-\(assumeAirplaneSize)"
        basename = basename.replacingOccurrences(of: ".", with: "_")
        test_paint_output_dirname = "\(basename)-test-paint"
        outlier_output_dirname = "\(basename)-outliers"
        let output_dirname = basename
        try super.init(imageSequenceDirname: image_sequence_dirname,
                       outputDirname: output_dirname,
                       maxConcurrent: max_concurrent,
                       givenFilenames: given_filenames)

        let processor = FinalProcessor(numberOfFrames: self.image_sequence.filenames.count,
                                       maxConcurrent: max_concurrent_renders,
                                       dispatchGroup: dispatchGroup)
        
        final_processor = processor
    }

    override func run() throws {

        Task {
            let dispatch_name = "FinalProcessorTaskGroup"
            await self.dispatchGroup.enter(dispatch_name) // XXX shouldn't really be here ...
            try await withThrowingTaskGroup(of: Void.self) { group in

                // XXX setup a task group for the final queue and final processor
                var should_process = [Bool](repeating: false, count: self.existing_output_files.count)
                for (index, output_file_exists) in self.existing_output_files.enumerated() {
                    should_process[index] = !output_file_exists
                }
                let immutable_should_process = should_process
                if let final_processor = final_processor {
                    group.addTask {
                        // the final queue runs in a separate task group
                        try await final_processor.final_queue.start()
                    }
                    group.addTask {              // XXX span this from the task group?
                        // run the final processor as a single separate thread
                        await final_processor.run(shouldProcess: immutable_should_process)
                    }
                } else {
                    Log.e("should have a processor")
                    fatalError("no processor")
                }
                try await group.waitForAll()
                await self.dispatchGroup.enter(dispatch_name)
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

        var otherFrames: [PixelatedImage] = []
        
        if index > 0,
           let image = try await image_sequence.getImage(withName: image_sequence.filenames[index-1])
        {
            otherFrames.append(image)
        }
        if index < image_sequence.filenames.count - 1,
           let image = try await image_sequence.getImage(withName: image_sequence.filenames[index+1])
        {
            otherFrames.append(image)
        }
        
        let test_paint_filename = self.test_paint ?
                                  "\(self.test_paint_output_dirname)/\(base_name)" : nil
        
        // the other frames that we use to detect outliers and repaint from
        let frame_plane_remover =
            await self.createFrame(fromImage: image,
                                   atIndex: index,
                                   otherFrames: otherFrames,
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
            Log.d("final_is_working \(final_is_working) current_running \(current_running) final_queue_size \(final_queue_size) final_frames_unprocessed \(final_frames_unprocessed) max_renders \(ret)")
        }
        //Log.d("max_concurrent_renders \(ret)")
        return ret
    }
    
    // called async, check for access to shared data
    // this method does the first step of processing on each frame.
    // outlier pixel detection, outlier group detection and analysis
    // after running this method, each frame will have a good idea
    // of what outliers is has, and whether or not should paint over them.
    func createFrame(fromImage image: PixelatedImage,
                     atIndex frame_index: Int,
                     otherFrames: [PixelatedImage],
                     output_filename: String,
                     test_paint_filename tpfo: String?) async -> FrameAirplaneRemover
    {
        let frame = await FrameAirplaneRemover(fromImage: image,
                                               atIndex: frame_index,
                                               otherFrames: otherFrames,
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
              
              
