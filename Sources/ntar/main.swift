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


enum MaskType {
    case airplanes
    case noAirplanes
}

class ImageMask {
    var leftX: Int
    var rightX: Int
    var topY: Int
    var bottomY: Int

    let type: MaskType
    
    init(withType type: MaskType) {
        self.type = type
        self.leftX = -1         // initial values are invalid
        self.rightX = -1
        self.topY = -1
        self.bottomY = -1
    }
}

@available(macOS 10.15, *)
func readMasks(fromImage image: PixelatedImage) async -> [MaskType:[ImageMask]] {
    // first read the layer mask
    let pixels = await image.pixels
    
    var airplane_groups: [ImageMask] = []
    var non_airplane_groups: [ImageMask] = []

    var current_mask: ImageMask?
    
    for x in 0..<image.width {
        for y in 0..<image.height {
            let pixel = pixels[x][y]
            if pixel.red == 0 && pixel.blue == 0 && pixel.green == 0 {
                if current_mask != nil {
                    current_mask = nil
                }
            } else if pixel.red == 0xFFFF,
                      pixel.blue == 0xFFFF, 
                      pixel.green == 0xFFFF
            {
                if let current_mask = current_mask {
                    // just keep updating these as long as we can
                    current_mask.rightX = x
                    current_mask.bottomY = y
                } else {
                // look through existing airplane masks first
                for (mask) in airplane_groups {
                    if mask.leftX == x || mask.topY == y {
                        current_mask = mask
                        break
                    }
                }
                if current_mask == nil {
                    let new_mask = ImageMask(withType: .airplanes)
                    new_mask.leftX = x
                    new_mask.topY = y
                    airplane_groups.append(new_mask)
                    current_mask = new_mask
                }
                }
                // all white
                //Log.d("woot \(pixel.red) \(pixel.green) \(pixel.blue)")
            } else {
                if let current_mask = current_mask {
                    // just keep updating these as long as we can
                    current_mask.rightX = x
                    current_mask.bottomY = y
                } else {
                    // look through existing airplane masks first
                    for (mask) in non_airplane_groups {
                        if mask.leftX == x || mask.topY == y {
                            current_mask = mask
                            break
                        }
                    }
                    if current_mask == nil {
                        let new_mask = ImageMask(withType: .noAirplanes)
                        new_mask.leftX = x
                        new_mask.topY = y
                        non_airplane_groups.append(new_mask)
                        current_mask = new_mask
                    }
                }
                // not black or white
                //Log.d("BAD \(pixel.red) \(pixel.green) \(pixel.blue)")
            }
        }
    }
    Log.i("found \(airplane_groups.count) airplane groups")
    Log.i("found \(non_airplane_groups.count) non_airplane groups")
    airplane_groups.forEach { group in
        Log.d("group from (\(group.leftX), \(group.topY)), (\(group.rightX), \(group.bottomY))")
    }
    non_airplane_groups.forEach { group in
        Log.d("group from (\(group.leftX), \(group.topY)), (\(group.rightX), \(group.bottomY))")
    }
    var ret:[MaskType:[ImageMask]] = [:]                 
    if airplane_groups.count > 0 {
        ret[.airplanes] = airplane_groups
    }
    if non_airplane_groups.count > 0 {
        ret[.noAirplanes] = non_airplane_groups
    }
    return ret
}

if CommandLine.arguments.count < 1 {
    Log.d("need more args!")    // XXX make this better
} else {
    let first_command_line_arg = CommandLine.arguments[1]

    if first_command_line_arg.hasSuffix("/layer_mask.tif") {
        let layer_mask_image_name = first_command_line_arg

        if #available(macOS 10.15, *) {
            if let image = PixelatedImage.getImage(withName: layer_mask_image_name) {
                // this is a data gathering path 
                Log.i("woot")

                let dispatchGroup = DispatchGroup()
                dispatchGroup.enter()
                Task {
                    let masks = await readMasks(fromImage: image)

                    // now that we have read the masks from the file,
                    // we should remove /layer_mask.tif from the filename
                    // and process as below, but just the second frame and
                    // applying the layer mask to outlyer group selection for painting 
                    // then outupt some kind of logging that can be digested to
                    // product a data set of known data,
                    // a stream of width/height/outlier# for both airplane and non-airplane outlier
                    // groups
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
                                                  minTrailLength: 35,
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

