import Foundation
import CoreGraphics
import Cocoa

/*
todo:

 - identify outliers that are in a line somehow, and apply a smaller threshold to those that are
 - figure out crashes after hundreds of frames (more threading problems?) (not yet fully fixed)
 - write perl wrapper to keep it running when it crashes (make sure all saved files are ok first?)
 - try image blending
 - make it faster
 - figure out how to parallelize processing of each frame
 - create a direct access pixel object that doesn't copy the value
   make an interface to also allow a mutable one like there is now
   reading pixels out of the base data is time consuming, and unnecessary
 - figure out some way to identify multiple outlier groups that are in a line (hough transform?)
 - fix padding (not sure it still works, could use a different alg)
 - try detecting outlier groups close to eachother by adding padding and re-analyzing
 - do a deep unsafe pointer audit to better understand some difficult to reproduce crashes
   have a good understanding of when and where each image buffer is allocated and released

   https://stackoverflow.com/questions/52420160/ios-error-heap-corruption-detected-free-list-is-damaged-and-incorrect-guard-v
   https://developer.apple.com/documentation/xcode/diagnosing-memory-thread-and-crash-issues-early

   b malloc_error_break

 - add scripts to allow video to processed video in one command
   - decompress existing video w/ ffmpeg (and note exactly how it was compressed)
   - process image sequence with ntar
   - recompress processed image sequence w/ ffmpeg with same parameters as before
   - remove image sequence dir

 - consider using aspect ration of outlier group bounding box to inform calculation
   i.e. if the box is small, then it needs to not be close to square to paint on it
 - also consider using the percentage of bounding box fill with outliers
 - produce training set of good and bad data?


   group painting criteria:
     - group size in pix2els 
     - bounding box width, height, aspect ratio and diagonal size
     - percentage of bounding box filled w/ pixels



  group selection plan:

   - make training mode
   - for a frame, give areas and number of expected planes in each area.
     also include areas in which there are no planes or sattelite tracks (ideally milky way too)
   - use this to output a bunch of information about groups that are and are not plane groups
   - include width, height and outlier count for each pland and non plane group
   - build up a big database of known valid plane groups and invalid plane groups (lots of data)
   - write a code generating script which is able to clearly distinguish between the data sets
   - use this big if branch statement in a separate generated .swift file
   - iterate with more data, allowing the re-generation of all data with different max pixel dist
*/

Log.handlers = 
[
      .console: ConsoleLogHandler(at: .debug)
    ]


if CommandLine.arguments.count < 1 {
    Log.d("need more args!")    // XXX make this better
} else {
    let first_command_line_arg = CommandLine.arguments[1]

    if first_command_line_arg.hasSuffix("/layer_mask.tif") {
        let layer_mask_image_name = first_command_line_arg

        if #available(macOS 10.15, *) {
            if let image = PixelatedImage.getImage(withName: layer_mask_image_name) {
                // this is a data gathering path 

                let dispatchGroup = DispatchGroup()
                dispatchGroup.enter()
                Task {

                    var parts = first_command_line_arg.components(separatedBy: "/")
                    parts.removeLast()
                    let path = parts.joined(separator: "/")

                    let eraser = KnownOutlierGroupExtractor(layerMask: image,
                                                            imageSequenceDirname: path,
                                                            maxConcurrent: 24,
                                                            // minTrailLength: 50 // no falses, some missed
                                                            maxPixelDistance: 7200,
                                                            padding: 0,
                                                            testPaint: true)

                    await eraser.readMasks(fromImage: image)
            
                    // next step is to refactor group selection work from FrameAirplaneRemover:328
                    // into a method, and then override that in KnownOutlierGroupExtractor to
                    // use the masks just read to determine what outlier groups are what

                    eraser.run()
                    
                    // inside of a known mask, the largest group is assumed to be airplane
                    // verify this visulaly in the test-paint image
                    // all other image groups inside any group are considered non-airplane
                    // perhaps threshold above 5 pixels or so
                    
                    dispatchGroup.leave()
                }
                dispatchGroup.wait()

            } else {
                Log.e("can't load \(layer_mask_image_name)")
            }
        } else {
            Log.e("doh")
        }

    } else {
        // this is the main path
        
        let path = FileManager.default.currentDirectoryPath
        let input_image_sequence_dirname = first_command_line_arg
        // XXX maybe check to make sure this is a directory
        Log.d("will process \(input_image_sequence_dirname)")
        Log.d("on path \(path)")

        if #available(macOS 10.15, *) {
            let dirname = "\(path)/\(input_image_sequence_dirname)"
            let eraser = NighttimeAirplaneRemover(imageSequenceDirname: dirname,
                                                  maxConcurrent: 24,
                                                  // minTrailLength: 50 // no falses, some missed
                                                  maxPixelDistance: 7200,
                                                  padding: 0,
                                                  testPaint: true)
            eraser.run()
        } else {
            Log.d("cannot run :(")
        }
    }
}

