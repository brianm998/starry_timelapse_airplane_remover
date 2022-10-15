import Foundation
import CoreGraphics
import Cocoa

@available(macOS 10.15, *)
class FrameAirplaneRemover {
    let width: Int
    let height: Int
    let bytesPerPixel: Int
    let bytesPerRow: Int
    let orig_data: Data
    let image: PixelatedImage
    let otherFrames: [PixelatedImage]
    let min_neighbors: UInt16
    let max_pixel_distance: UInt16

    var data: Data              // a mutable copy of the original data
    var test_paint_data: Data?
    
    var outlier_map: [String: Outlier] = [:] // keyed by "\(x),\(y)"

    // populated by pruning
    var neighbor_groups: [String: UInt64] = [:]
    
    var test_paint_filename: String = ""
    var test_paint = false

    init?(fromImage image: PixelatedImage,
          otherFrames: [PixelatedImage],
          filename: String,
          test_paint_filename tpfo: String?,
          max_pixel_distance: UInt16,
          min_neighbors: UInt16
         )
    {
        self.min_neighbors = min_neighbors
        self.image = image
        self.otherFrames = otherFrames
        if let tp_filename = tpfo {
            self.test_paint = true
            self.test_paint_filename = tp_filename
        }
        self.width = image.width
        self.height = image.height
        self.bytesPerPixel = image.bytesPerPixel
        self.bytesPerRow = width*bytesPerPixel
        self.max_pixel_distance = max_pixel_distance
        
        guard let dataProvider = image.image.dataProvider,
              let _data = dataProvider.data
        else { return nil }

        self.orig_data = _data as Data
        
        // copy the original image data as adjecent frames need
        // to access the original unmodified version
        guard let _mut_data = CFDataCreateMutableCopy(kCFAllocatorDefault,
                                                  CFDataGetLength(_data),
                                                  _data) as? Data else { return nil }

        self.data = _mut_data
              
        if test_paint {
            guard let test_data = CFDataCreateMutableCopy(kCFAllocatorDefault,
                                                          CFDataGetLength(_data),
                                                          _data) as? Data else { return nil }
            self.test_paint_data = test_data
        }
        Log.d("got image data, detecting outlying pixels")
    }

    func populateOutlierMap() async {
        // compare pixels at the same image location in adjecent frames
        // detect Outliers which are much more brighter than the adject frames
        for y in 0 ..< height {
            for x in 0 ..< width {
                
                let origPixel = await image.pixel(atX: x, andY: y)
                var otherPixels: [Pixel] = []

                for i in 0 ..< otherFrames.count {
                    otherPixels.append(await otherFrames[i].pixel(atX: x, andY: y))
                }
                if otherPixels.count == 0 {
                    fatalError("need more than one image in the sequence")
                }
                
                var total_difference: Int32 = 0
                otherPixels.forEach { pixel in
                    total_difference += Int32(origPixel.difference(from: pixel))
                }
                
                total_difference /= Int32(otherPixels.count)
                
                if total_difference > max_pixel_distance {
                    outlier_map["\(x),\(y)"] = Outlier(x: x, y: y,
                                                       amount: total_difference)
                }
            }
        }
    }

    func prune() {
        Log.i("processing the outlier map")
        
        // go through the outlier_map and link together all the outliers that are adject to eachother,
        // outputting a mapping of group name to size
    
        // first link all outliers to their direct neighbors
        for (_, outlier) in outlier_map {
            let x = outlier.x
            let y = outlier.y
            if y > 0, let neighbor = outlier_map["\(x),\(y-1)"] {
                outlier.top = neighbor
            }
            if x > 0, let neighbor = outlier_map["\(x-1),\(y)"] {
                outlier.left = neighbor
            }
            if let neighbor = outlier_map["\(x+1),\(y)"] {
                outlier.bottom = neighbor
            }
            if let neighbor = outlier_map["\(x),\(y+1)"] {
                outlier.right = neighbor
            }
        }
    
        // then label all adject outliers
        for (outlier_key, outlier) in outlier_map {
            if outlier.tag == nil,
               !outlier.done
            {
                outlier.tag = outlier_key
                var pending_outliers = outlier.taglessUndoneNeighbors
                // these outliers have a tag, but are set as done
                while pending_outliers.count > 0 {
                    let next_outlier = pending_outliers.removeFirst()
                    next_outlier.tag = outlier_key
                    let more_pending_outliers = next_outlier.taglessUndoneNeighbors
                    pending_outliers = more_pending_outliers + pending_outliers
                }
            }
        }
    
        var individual_group_counts: [String: UInt64] = [:]
    
        // finally collect counts by outlier tag name
        for (_, outlier) in outlier_map {
            //Log.d("outlier \(outlier)")
            if let tag = outlier.tag {
                if let outlier_count = individual_group_counts[tag] {
                    individual_group_counts[tag] = outlier_count + 1
                } else {
                    individual_group_counts[tag] = 1
                }
            } else {
                Log.e("FUCK")       // all outliers should be tagged now
                fatalError("FUCKED")
            }
        }
        self.neighbor_groups = individual_group_counts
    }    
                  
    func testPaintOutliers() {
        Log.d("painting outliers green")

        for (_, outlier) in outlier_map {
            let x = outlier.x
            let y = outlier.y
            
            if outlier.amount > max_pixel_distance { // XXX global variable
                //Log.d("found \(outlier.neighbors.count) neighbors")
                
                let offset = (Int(y) * bytesPerRow) + (Int(x) * bytesPerPixel)
                
                var nextPixel = Pixel()
                nextPixel.green = 0xFFFF
                        
                var nextValue = nextPixel.value

                //Log.e("offset \(offset) nextValue \(nextValue) \(test_paint_data) bytesPerPixel \(bytesPerPixel) bytesPerRow \(bytesPerRow)")
                
                test_paint_data?.replaceSubrange(offset ..< offset+6,//XXX ??? bytesPerPixel,
                                                 with: &nextValue, count: 6)
            }
        }
    }

   func addPadding(padding_value: UInt) {
        // add padding when desired
        // XXX this is slower than the other steps here :(
        // also not sure it's really needed
        if(padding_value > 0) {
            Log.d("adding padding") // XXX search the outlier map, looking for missing neighbors
            for y in 0 ..< height {
                //Log.d("y \(y)")
                for x in 0 ..< width {
                    let outlier_tag = "\(x),\(y)"
                    let outlier = outlier_map[outlier_tag]
                    var should_try = false
                    if outlier == nil {
                        should_try = true
                    } else if let outlier = outlier,
                              outlier.amount > max_pixel_distance
                    {
                        should_try = true
                    }
                    
                    if should_try,
                       let bigTag = tag(within: padding_value,
                                        ofX: x, andY: y,
                                        outlierMap: outlier_map,
                                        neighborGroups: neighbor_groups,
                                        minNeighbors: min_neighbors)
                    {
                        let padding = Outlier(x: x, y: y, amount: 0)
                        padding.tag = bigTag
                        outlier_map[outlier_tag] = padding
                    }
                }
            }
        }
    }

    func paintOverAirplanes() async {
        // paint on the large groups of outliers with values from the other frames
        // iterate over the outlier_map instead
        for (_, outlier) in outlier_map {
            let x = outlier.x
            let y = outlier.y
            // figure out if this outlier is next to enough other outliers
            if let tag = outlier.tag,
               let total_size = neighbor_groups[tag] {
                if total_size > min_neighbors { 
                    // we've found a spot to paint over
                            
                    var otherPixels: [Pixel] = []

                    // grab the pixels from the same image spot from adject frames
                    for i in 0 ..< otherFrames.count {
                        otherPixels.append(await otherFrames[i].pixel(atX: x, andY: y))
                    }

                    // blend the pixels from the adjecent frames
                    var nextPixel = Pixel(merging: otherPixels)
                    
                    // this is the numeric value we need to write out to paint over the airplane
                    var nextValue = nextPixel.value

                    // the is the place in the image data to write to
                    let offset = (Int(y) * bytesPerRow) + (Int(x) * bytesPerPixel)

                    // actually paint over that airplane like thing in the image data
                    data.replaceSubrange(offset ..< offset+bytesPerPixel, with: &nextValue, count: 6)

                    // for testing, colors changed pixels
                    if test_paint {
                        if outlier.amount == 0 {
                            nextPixel.blue = 0xFFFF // for padding
                        } else {
                            nextPixel.red = 0xFFFF // for unpadded changed area
                        }
                    }
                    var testPaintValue = nextPixel.value
                    
                    if test_paint {
                        test_paint_data?.replaceSubrange(offset ..< offset+bytesPerPixel,
                                                         with: &testPaintValue, count: 6)
                    }
                }
            }
        }
    }

    func writeTestFile() {
        if test_paint,
           let test_paint_data = test_paint_data
        {
            image.writeTIFFEncoding(ofData: test_paint_data, toFilename: test_paint_filename)
        }
    }
}

                  
// used for padding          
func tag(within distance: UInt, ofX x: Int, andY y: Int,
         outlierMap outlier_map: [String: Outlier],
         neighborGroups neighbor_groups: [String: UInt64],
         minNeighbors min_neighbors: UInt16) -> String?
{
    var x_start = 0;
    var y_start = 0;
    if x < distance {
        x_start = 0
    } else {
        x_start = x - Int(distance)
    }
    if y < distance {
        y_start = 0
    } else {
        y_start = y - Int(distance)
    }
    for y_idx in y_start ..< y+Int(distance) {
        for x_idx in x_start ..< x+Int(distance) {
            if let outlier = outlier_map["\(x_idx),\(y_idx)"],
               hypotenuse(x1: x, y1: y, x2: x_idx, y2: y_idx) <= distance,
               outlier.amount != 0,
               let tag = outlier.tag,
               let group_size = neighbor_groups[tag],
               group_size > min_neighbors
            {
                return outlier.tag
            }
        }
   }
   return nil
}

func hypotenuse(x1: Int, y1: Int, x2: Int, y2: Int) -> Int {
    let x_dist = Int(abs(Int32(x2)-Int32(x1)))
    let y_dist = Int(abs(Int32(y2)-Int32(y1)))
    return Int(sqrt(Float(x_dist*x_dist+y_dist*y_dist)))
}

