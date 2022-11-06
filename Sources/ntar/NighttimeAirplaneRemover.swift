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
class NighttimeAirplaneRemover : ImageSequenceProcessor {
    
    let test_paint_output_dirname: String

    let outlier_output_dirname: String

    // the following properties get included into the output videoname
    
    // difference between same pixels on different frames to consider an outlier
    let max_pixel_distance: UInt16

    // write out test paint images
    let test_paint: Bool

    // write out individual outlier group images
    let should_write_outlier_group_files: Bool
    
    var final_processor: FinalProcessor?    

    init(imageSequenceDirname image_sequence_dirname: String,
         maxConcurrent max_concurrent: UInt = 5,
         maxPixelDistance max_pixel_distance: UInt16 = 10000,
         testPaint: Bool = false,
         writeOutlierGroupFiles: Bool = false,
         givenFilenames given_filenames: [String]? = nil)
    {
        self.max_pixel_distance = max_pixel_distance
        self.test_paint = testPaint
        self.should_write_outlier_group_files = writeOutlierGroupFiles

        let formatted_theta_diff = String(format: "%0.1f", max_theta_diff)
        let formatted_rho_diff = String(format: "%0.1f", max_rho_diff)
        
        let formatted_final_theta_diff = String(format: "%0.1f", final_theta_diff)
        let formatted_final_rho_diff = String(format: "%0.1f", final_rho_diff)
        
        var basename = "\(image_sequence_dirname)-no-planes-ntar-v-\(ntar_version)"
        basename = basename.replacingOccurrences(of: ".", with: "_")
        test_paint_output_dirname = "\(basename)-test-paint"
        outlier_output_dirname = "\(basename)-outliers"
        let output_dirname = basename
        super.init(imageSequenceDirname: image_sequence_dirname,
                   outputDirname: output_dirname,
                   maxConcurrent: max_concurrent,
                   givenFilenames: given_filenames)

        let processor = FinalProcessor(numberOfFrames: self.image_sequence.filenames.count,
                                       maxConcurrent: max_concurrent_renders,
                                       dispatchGroup: dispatchGroup)
        
        final_processor = processor
    }

    // called by the superclass at startup
    override func startup_hook() {
        if test_paint { mkdir(test_paint_output_dirname) }
        if should_write_outlier_group_files {
            mkdir(outlier_output_dirname)
        }
    }
    
    // called by the superclass to process each frame
    // called async check access to shared data
    override func processFrame(number index: Int,
                               image: PixelatedImage,
                               output_filename: String,
                               base_name: String) async
    {
        //Log.e("full_image_path \(full_image_path)")
        // load images outside the main thread

        var otherFrames: [PixelatedImage] = []
        
        if index > 0,
           let image = await image_sequence.getImage(withName: image_sequence.filenames[index-1])
        {
            otherFrames.append(image)
        }
        if index < image_sequence.filenames.count - 1,
           let image = await image_sequence.getImage(withName: image_sequence.filenames[index+1])
        {
            otherFrames.append(image)
        }
        
        let test_paint_filename = self.test_paint ?
                                  "\(self.test_paint_output_dirname)/\(base_name)" : nil
        
        // the other frames that we use to detect outliers and repaint from
        let frame_plane_remover =
            await self.prepareForAdjecentFrameAnalysis(fromImage: image,
                                                       atIndex: index,
                                                       otherFrames: otherFrames,
                                                       output_filename: "\(self.output_dirname)/\(base_name)",
                                                       test_paint_filename: test_paint_filename)

        
        // next step is to add this frame_plane_remover to an array of optionals
        // indexed by frame number
        // then create a new class that uses the diapatchGroup to keep the process alive
        // and processes sequentially through them as they are available, doing
        // analysis of the outlier groups between frames and making them look better
        // by doing further analysis and cleanup

        if let final_processor = final_processor {
            await final_processor.add(frame: frame_plane_remover, at: index)
        } else {
            fatalError("should not happen")
        }
    }

    // balance the total number of active processes, and favor the end of the process
    // so that we don't experience backup and overload memory
    override func maxConcurrentRenders() async -> UInt {
        var ret = max_concurrent_renders
        // XXX this needs to take into account the final processor more
        if let final_processor = final_processor {
            let final_is_working = await final_processor.isWorking
            let final_frames_unprocessed = await final_processor.framesBetween
            let final_queue_size = await final_processor.final_queue.number_running.currentValue()
            let current_running = await self.number_running.currentValue()
            if final_is_working || final_frames_unprocessed > final_group_boundary_amt*2 {
                let signed_ret: Int = (Int(max_concurrent_renders) - Int(final_queue_size))-final_frames_unprocessed
                if signed_ret < 0 {
                    ret = 0
                } else {
                    ret = UInt(signed_ret)
                }
            } else {
                ret = max_concurrent_renders - final_queue_size
            }
            Log.d("final_is_working \(final_is_working) current_running \(current_running) final_queue_size \(final_queue_size) final_frames_unprocessed \(final_frames_unprocessed) max_renders \(ret)")
        }
        //Log.d("max_concurrent_renders \(ret)")
        return ret
    }
    
    // called after the list of already existing output files is known
    override func method_list_hook() async {
        var should_process = [Bool](repeating: false, count: self.existing_output_files.count)
        for (index, output_file_exists) in self.existing_output_files.enumerated() {
            should_process[index] = !output_file_exists
        }
        let immutable_should_process = should_process
        if let final_processor = final_processor {
            let name = "final processor run" 
            await dispatchGroup.enter(name)
            dispatchQueue.async {
                Task {
                    // run the final processor as a single separate thread
                    await final_processor.run(shouldProcess: immutable_should_process)
                    await self.dispatchGroup.leave(name)
                }
            }
        } else {
            Log.e("should have a processor")
            fatalError("no processor")
        }
    }

    // called async, check for access to shared data 
    func prepareForAdjecentFrameAnalysis(fromImage image: PixelatedImage,
                                         atIndex frame_index: Int,
                                         otherFrames: [PixelatedImage],
                                         output_filename: String,
                                         test_paint_filename tpfo: String?) async -> FrameAirplaneRemover
    {
        let start_time = NSDate().timeIntervalSince1970
        
        guard let frame_plane_remover = FrameAirplaneRemover(fromImage: image,
                                                             atIndex: frame_index,
                                                             otherFrames: otherFrames,
                                                             output_filename: output_filename,
                                                             test_paint_filename: tpfo,
                                                             outlier_output_dirname: outlier_output_dirname,
                                                             max_pixel_distance: max_pixel_distance)
        else {
            Log.d("DOH")
            fatalError("FAILED")
        }

        let time_1 = NSDate().timeIntervalSince1970
        let interval1 = String(format: "%0.1f", time_1 - start_time)
        
        Log.d("frame \(frame_index) populating the outlier map")

        // find outlying bright pixels between frames
        await frame_plane_remover.populateOutlierMap() 

        let time_2 = NSDate().timeIntervalSince1970
        let interval2 = String(format: "%0.1f", time_2 - time_1)

        Log.d("frame \(frame_index) pruning after \(interval2)s")

        // group neighboring outlying pixels into groups
        await frame_plane_remover.prune()

        let time_3 = NSDate().timeIntervalSince1970
        let interval3 = String(format: "%0.1f", time_3 - time_2)
        
        Log.d("frame \(frame_index) done processing the outlier map after \(interval3)s")
        
        let time_4 = NSDate().timeIntervalSince1970
        let interval4 = String(format: "%0.1f", time_4 - time_3)
        Log.d("frame \(frame_index) calculating group bounds \(interval4)s")

        // figure out what part of the image each outlier group lies in
        await frame_plane_remover.calculateGroupBoundsAndAmounts()

        if should_write_outlier_group_files {
            await frame_plane_remover.writeOutlierGroupFiles()
        } else {
            Log.e("WTF")
            fatalError("FUCK YOU")
        }
        
        let time_5 = NSDate().timeIntervalSince1970
        let interval5 = String(format: "%0.1f", time_5 - time_4)
        Log.d("frame \(frame_index) running full hough transform after \(interval5)s")

        // run a hough transform on large enough outliers only
        await frame_plane_remover.fullHoughTransform()

        let time_6 = NSDate().timeIntervalSince1970
        let interval6 = String(format: "%0.1f", time_6 - time_5)
        Log.d("frame \(frame_index) outlier group painting analysis after p\(interval6)s")

        // do a lot of analysis to determine what outlier groups we should paint over
        await frame_plane_remover.outlierGroupPaintingAnalysis()
        
        let time_7 = NSDate().timeIntervalSince1970
        let interval7 = String(format: "%0.1f", time_7 - time_6)
        Log.d("frame \(frame_index) timing for frame render - \(interval7)s - \(interval6)s - \(interval5)s - \(interval4)s - \(interval3)s - \(interval2)s - \(interval1)s")

        Log.i("frame \(frame_index) ready for analysis with groups in adjecent frames")
        
        return frame_plane_remover
   }        

}
              
              
