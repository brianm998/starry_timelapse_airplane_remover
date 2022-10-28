import Foundation
import CoreGraphics
import Cocoa

// this class handles removing airplanes from an entire sequence,
// delegating each frame to an instance of FrameAirplaneRemover

@available(macOS 10.15, *) 
class NighttimeAirplaneRemover : ImageSequenceProcessor {
    
    let test_paint_output_dirname: String

    // the following properties get included into the output videoname
    
    // difference between same pixels on different frames to consider an outlier
    let max_pixel_distance: UInt16

    // paint green on the outliers above the threshold for testing, that are not overwritten
    let test_paint_outliers: Bool
    
    let test_paint: Bool

    init(imageSequenceDirname image_sequence_dirname: String,
         maxConcurrent max_concurrent: UInt = 5,
         maxPixelDistance max_pixel_distance: UInt16 = 10000,
         testPaint: Bool = false,
         givenFilenames given_filenames: [String]? = nil)
    {
        self.max_pixel_distance = max_pixel_distance
        self.test_paint_outliers = testPaint
        self.test_paint = testPaint

        let formatted_theta_diff = String(format: "%0.1f", max_theta_diff)
        let formatted_rho_diff = String(format: "%0.1f", max_rho_diff)
        
        var basename = "\(image_sequence_dirname)-no-planes-\(max_pixel_distance)-\(min_group_size)-\(min_line_count)-\(group_min_line_count)-\(formatted_theta_diff)-\(formatted_rho_diff)-\(max_number_of_lines)-\(assume_airplane_size)"
        basename = basename.replacingOccurrences(of: ".", with: "_")
        test_paint_output_dirname = "\(basename)-test-paint"
        let output_dirname = basename
        super.init(imageSequenceDirname: image_sequence_dirname,
                   outputDirname: output_dirname,
                   maxConcurrent: max_concurrent,
                   givenFilenames: given_filenames)
    }

    // called by the superclass at startup
    override func startup_hook() {
        if test_paint { mkdir(test_paint_output_dirname) }
    }

    
    // called by the superclass to process each frame
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
        let data = self.removeAirplanes(fromImage: image,
                                    atIndex: index,
                                    otherFrames: otherFrames,
                                    filename: "\(self.output_dirname)/\(base_name)",
                                    test_paint_filename: test_paint_filename)

        if let data = data {
            // write frame out as a tiff file after processing it
            image.writeTIFFEncoding(ofData: data, toFilename: output_filename)
        } else {
            fatalError("FUCK")
        }
    }

    func removeAirplanes(fromImage image: PixelatedImage,
                         atIndex frame_index: Int,
                         otherFrames: [PixelatedImage],
                         filename: String,
                         test_paint_filename tpfo: String?) -> Data?
    {
        let start_time = NSDate().timeIntervalSince1970
        
        guard let frame_plane_remover = FrameAirplaneRemover(fromImage: image,
                                                       atIndex: frame_index,
                                                       otherFrames: otherFrames,
                                                       filename: filename,
                                                       test_paint_filename: tpfo,
                                                       max_pixel_distance: max_pixel_distance)
        else {
            Log.d("DOH")
            fatalError("FAILED")
        }

        let time_1 = NSDate().timeIntervalSince1970
        let interval1 = String(format: "%0.1f", time_1 - start_time)
        
        Log.d("frame \(frame_index) populating the outlier map")

        // almost all time is spent here
        frame_plane_remover.populateOutlierMap() 

        let time_2 = NSDate().timeIntervalSince1970
        let interval2 = String(format: "%0.1f", time_2 - time_1)

        Log.d("frame \(frame_index) pruning after \(interval2)s")

        frame_plane_remover.prune()

        let time_3 = NSDate().timeIntervalSince1970
        let interval3 = String(format: "%0.1f", time_3 - time_2)
        
        Log.d("frame \(frame_index) done processing the outlier map after \(interval3)s")
        // paint green on the outliers above the threshold for testing

        if(test_paint_outliers) {
            frame_plane_remover.testPaintOutliers()
        }
        
        let time_4 = NSDate().timeIntervalSince1970
        let interval4 = String(format: "%0.1f", time_4 - time_3)
        Log.d("frame \(frame_index) calculating group bounds \(interval4)s")

        frame_plane_remover.calculateGroupBoundsAndAmounts()

        let time_5 = NSDate().timeIntervalSince1970
        let interval5 = String(format: "%0.1f", time_5 - time_4)
        Log.d("frame \(frame_index) running full hough transform after \(interval5)s")

        frame_plane_remover.fullHoughTransform()

        let time_6 = NSDate().timeIntervalSince1970
        let interval6 = String(format: "%0.1f", time_6 - time_5)
        Log.d("frame \(frame_index) outlier group painting analysis after p\(interval6)s")

        frame_plane_remover.outlierGroupPaintingAnalysis()
        
        let time_7 = NSDate().timeIntervalSince1970
        let interval7 = String(format: "%0.1f", time_7 - time_6)
        Log.d("frame \(frame_index) painting over airplanes after p\(interval7)s")
        
        frame_plane_remover.paintOverAirplanes()
        
        let time_8 = NSDate().timeIntervalSince1970
        let interval8 = String(format: "%0.1f", time_8 - time_7)
        Log.d("frame \(frame_index) creating final image \(filename) after p\(interval7)s")

        frame_plane_remover.writeTestFile()
        
        let time_9 = NSDate().timeIntervalSince1970
        let interval9 = String(format: "%0.1f", time_9 - time_8)
        
        Log.d("frame \(frame_index) timing for frame render - \(interval9)s  - \(interval8)s - \(interval7)s - \(interval6)s - \(interval5)s - \(interval4)s - \(interval3)s - \(interval2)s - \(interval1)s")
        Log.i("frame \(frame_index) complete")

        return frame_plane_remover.data
    }
}
              
