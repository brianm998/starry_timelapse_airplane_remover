import Foundation
import CoreGraphics
import Cocoa


enum MaskType {
    case airplanes
    case noAirplanes
}

class ImageMask: Hashable, Equatable {
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

    func fullyContains(min_x: Int, min_y: Int, max_x: Int, max_y: Int) -> Bool {
        let ret = min_x >= leftX && max_x <= rightX && min_y >= topY && max_y <= bottomY
        //Log.d("\(min_x) >= \(leftX) && \(max_x) <= \(rightX) && \(min_y) >= \(topY) && \(max_y)f <= \(bottomY) -> \(ret)")
        return ret;
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(leftX)
        hasher.combine(rightX)
        hasher.combine(topY)
        hasher.combine(bottomY)
        hasher.combine(type)
    }

    public static func == (lhs: ImageMask, rhs: ImageMask) -> Bool {
        return lhs.leftX == rhs.leftX && 
               lhs.rightX == rhs.rightX &&
               lhs.topY == rhs.topY &&
               lhs.bottomY == rhs.bottomY &&
               lhs.type == rhs.type
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

    var has_airline_already: Set<ImageMask> = []
    
    // these are detected based upon a retangle of pixels
    // that are brighter tahan 0x0000 and dimmer than 0xFFFF.  i.e. any intermediate color.
    var non_airplane_groups: [ImageMask] = []

    var csv_output_url: URL?
    
    init(layerMask: PixelatedImage,
         imageSequenceDirname image_sequence_dirname: String,
         maxConcurrent max_concurrent: UInt = 5,
         maxPixelDistance max_pixel_distance: UInt16 = 10000,
         padding: UInt = 0,
         testPaint: Bool = false)
    {
        super.init(imageSequenceDirname: image_sequence_dirname,
                   maxConcurrent: max_concurrent,
                   maxPixelDistance: max_pixel_distance,
                   padding: padding,
                   testPaint: testPaint,
                   givenFilenames: ["LRT_00001.tif",
                                    "LRT_00002.tif",
                                    "LRT_00003.tif"])

        self.should_paint_group = { min_x, min_y, max_x, max_y, group, group_size, frame_number in
            // here we only care about group #1, the one in the middle
            return frame_number == 1 && self.shouldPaintGroup(min_x: min_x, min_y: min_y,
                                                              max_x: max_x, max_y: max_y,
                                                              group_name: group,
                                                              group_size: group_size)
        }
        
        self.process_only_this_index = 1
        
        let output_filename = "\(image_sequence_dirname)/outlier_data_\(max_pixel_distance).csv"

        do {
            if FileManager.default.fileExists(atPath: output_filename) {
                // delete any existing copy
                try FileManager.default.removeItem(atPath: output_filename)
            }
            // start output file
            if FileManager.default.createFile(atPath: output_filename, contents: nil) {
                self.csv_output_url = NSURL(fileURLWithPath: output_filename, isDirectory: false) as URL
            } else {
                fatalError("fuck")
            }
        } catch {
            Log.e("\(error)")
        }
    }

    func write_to_csv(width: Int, height: Int, group_size: UInt64, type: MaskType) {
        if let csv_output_url = self.csv_output_url {
            var string = ""
            switch type {
            case .airplanes:
                string = "\(width),\(height),\(group_size),1\n"
            case .noAirplanes:
                string = "\(width),\(height),\(group_size),0\n"
                
            }
            do {
                let fileHandle = try FileHandle.init(forWritingTo: csv_output_url)
                if let output_data = string.data(using: .utf8) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(output_data)
                    fileHandle.closeFile() // could close on finish_hook()
                } else {
                    Log.e("CSV LOGGING ERROR")
                }
            } catch {
                Log.e("\(error)")
            }
        }
    }
    
    override func finished_hook() {
        // XXX don't need this
        // close output file 
        // write to 
    }

    func shouldPaintGroup(min_x: Int, min_y: Int,
                          max_x: Int, max_y: Int,
                          group_name: String,
                          group_size: UInt64) -> Bool
    {
        let width = max_x - min_x + 1
        let height = max_y - min_y + 1

        if group_size < 4 { return false } // XXX hardcoded constant

        if group_size > 100 {
            Log.d("should paint \(group_name) of size \(group_size) group [\(min_x), \(min_y)], [\(max_x), \(max_y)]")
        }
        var should_paint: Bool = false

        //var was_part_of_group = false
        
        airplane_groups.forEach { imageMask in
            if group_size > 100 {
                Log.d("airplane image mask [\(imageMask.leftX), \(imageMask.topY)], [\(imageMask.rightX), \(imageMask.bottomY)] group [(\(min_x), \(min_y))], [\(max_x), \(max_y)]")
            }
            if imageMask.fullyContains(min_x: min_x, min_y: min_y, max_x: max_x, max_y: max_y) {
                //was_part_of_group = true
                if !has_airline_already.contains(imageMask) {
                    Log.i("marking group \(group_name) of size \(group_size) for painting into mask \(imageMask) [\(imageMask.leftX), \(imageMask.topY)], [\(imageMask.rightX), \(imageMask.bottomY)]")
                    has_airline_already.insert(imageMask)
                    self.write_to_csv(width: width, height: height,
                                      group_size: group_size, type: .airplanes)
                    should_paint = true
                } else {
                    //if group_size > 100 {
                        //Log.d("will not paint \(group_name) of size \(group_size), already contained")
                //}
                }
            }
        }

//        if group_size > 100 && !was_part_of_group {
//            Log.d("should paint \(group_name) of size \(group_size) was not part of any group")
//        }

        
        non_airplane_groups.forEach { imageMask in
            if group_size > 100 {
                Log.d("airplane image mask [\(imageMask.leftX), \(imageMask.topY)], [\(imageMask.rightX), \(imageMask.bottomY)] group [(\(min_x), \(min_y))], [\(max_x), \(max_y)]")
            }
            if imageMask.fullyContains(min_x: min_x, min_y: min_y, max_x: max_x, max_y: max_y) {
                if group_size > 100 {
                    Log.i("marking group \(group_name) of size \(group_size) for NOT painting into mask \(imageMask) [\(imageMask.leftX), \(imageMask.topY)], [\(imageMask.rightX), \(imageMask.bottomY)]")
                }
                self.write_to_csv(width: width, height: height,
                                  group_size: group_size, type: .noAirplanes)
            }
        }

        // check with non_airplane_groups to output data set as non airplane
        
        return should_paint
    }

    func readMasks(fromImage image: PixelatedImage) -> [MaskType:[ImageMask]] {
        // first read the layer mask
        
        var current_mask: ImageMask?

        image.read() { image_data_pointer in
            for x in 0..<image.width {
                for y in 0..<image.height {
                    let offset = (y * image.width*3) + (x * 3) // XXX hardcoded 3
                    let pixel_red = image_data_pointer[offset]
                    let pixel_green = image_data_pointer[offset+1]
                    let pixel_blue = image_data_pointer[offset+2]
                    
                    //Log.d("[\(x), \(y)] \(pixel_red) \(pixel_green) \(pixel_blue) \(current_mask)")
                    if pixel_red == 0 && pixel_blue == 0 && pixel_green == 0 {
                        if current_mask != nil {
                            current_mask = nil
                        }
                    } else if pixel_red == 0xFFFF,
                              pixel_blue == 0xFFFF, 
                              pixel_green == 0xFFFF
                    {
                        // XXX this and the following else block are duplicates 
                        if let current_mask = current_mask {
                            // just keep updating these as long as we can
                            current_mask.rightX = x
                            current_mask.bottomY = y
                        } else {
                            // look through existing airplane masks first
                            for (mask) in airplane_groups {
                                //Log.d("existing mask \(mask.leftX) \(mask.topY)  \(mask.rightX) \(mask.bottomY)")
                                if mask.topY == y && mask.rightX == x - 1 {
                                    current_mask = mask
                                    break
                                }
                            }
                            if current_mask == nil {
                                let new_mask = ImageMask(withType: .airplanes)
                                new_mask.leftX = x
                                new_mask.topY = y
                                Log.d("new airplane mask starting @ \(x), \(y)")
                                airplane_groups.append(new_mask)
                                current_mask = new_mask
                            }
                        }
                        // all white
                        //Log.d("woot \(pixel_red) \(pixel_green) \(pixel_blue)")
                    } else {
                        if let current_mask = current_mask {
                            // just keep updating these as long as we can
                            current_mask.rightX = x
                            current_mask.bottomY = y
                        } else {
                            // look through existing airplane masks first
                            for (mask) in non_airplane_groups {
                                if mask.topY == y && mask.rightX == x - 1 {
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
                        //Log.d("BAD \(pixel_red) \(pixel_green) \(pixel_blue)")
                    }
                }
            }
        }
        Log.i("found \(airplane_groups.count) airplane groups")
        Log.i("found \(non_airplane_groups.count) non_airplane groups")
        airplane_groups.forEach { group in
            Log.d("   airplane group from (\(group.leftX), \(group.topY)), (\(group.rightX), \(group.bottomY))")
        }
        non_airplane_groups.forEach { group in
            Log.d("nonairplane group from (\(group.leftX), \(group.topY)), (\(group.rightX), \(group.bottomY))")
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
