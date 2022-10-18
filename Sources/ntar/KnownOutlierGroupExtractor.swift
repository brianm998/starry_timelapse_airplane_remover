import Foundation
import CoreGraphics
import Cocoa


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



// this is a subclass of NighttimeAirplaneRemover which handles
// the case of three frames, with a mask for the middle frame.
// only the middle frame is processed, and the mask is used to determine
// how to classify outliers.  Then an output file is written with the data
// classified as airplane and non airplane, and output tiff files output, no videos
@available(macOS 10.15, *) 
class KnownOutlierGroupExtractor : NighttimeAirplaneRemover {

    // these are detected based upon all white 0xFFFF pixels in a retangle
    var airplane_groups: [ImageMask] = []

    // these are detected based upon a retangle of pixels
    // that are brighter tahan 0x0000 and dimmer than 0xFFFF.  i.e. any intermediate color.
    var non_airplane_groups: [ImageMask] = []
    
    init(layerMask: PixelatedImage,
         imageSequenceDirname image_sequence_dirname: String,
         maxConcurrent max_concurrent: UInt = 5,
         minTrailLength min_group_trail_length: UInt16 = 100,
         maxPixelDistance max_pixel_distance: UInt16 = 10000,
         padding: UInt = 0,
         testPaint: Bool = false)
    {
        super.init(imageSequenceDirname: image_sequence_dirname,
                   maxConcurrent: max_concurrent,
                   minTrailLength: min_group_trail_length,
                   maxPixelDistance: max_pixel_distance,
                   padding: padding,
                   testPaint: testPaint)

        // assume three files starting with LRT_00001.tif
        self.image_sequence = ImageSequence(dirname: image_sequence_dirname,
                                            givenFilenames: ["LRT_00001.tif",
                                                             "LRT_00002.tif",
                                                             "LRT_00003.tif"])
    }

    func readMasks(fromImage image: PixelatedImage) async -> [MaskType:[ImageMask]] {
        // first read the layer mask
        let pixels = await image.pixels
        
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
                    // XXX this and the following else block are duplicates 
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
}
