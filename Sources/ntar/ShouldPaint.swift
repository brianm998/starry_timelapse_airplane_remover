import Foundation

// this is auto generated code, run regenerate_ShouldPaint.sh to remake it

func shouldPaintGroup(min_x: Int, min_y: Int,
                      max_x: Int, max_y: Int,
                      group_name: String,
                      group_size: UInt64) -> Bool
{
    // the size of the bounding box in number of pixels
    let max_pixels = (max_x-min_x)*(max_y-min_y)

    // how much (betwen 0 and 1) of the bounding box is filled by outliers?
    let amount_filled = Double(group_size)/Double(max_pixels)

    let bounding_box_width = max_x-min_x
    let bounding_box_height = max_y-min_y

    // the aspect ratio of the bounding box.
    // 1 is square, closer to zero is more regangular.
    var aspect_ratio: Double = 0
    if bounding_box_width > bounding_box_height {
        aspect_ratio = Double(bounding_box_height)/Double(bounding_box_width)
    } else {
        aspect_ratio = Double(bounding_box_width)/Double(bounding_box_height)
    }

    if(group_size < 84) { return false } // not airplane
    if(group_size > 246) { return true } // is airplane
    if(aspect_ratio < 0.421052631578947) { return true } // is airplane
    if(amount_filled > 0.419540229885057) { return false } // notAirplane
    if(amount_filled < 0.173333333333333) { return false } // notAirplane
    if(aspect_ratio > 0.481481481481481) { return false } // notAirplane
    if(aspect_ratio < 0.413793103448276) { return true } // airplane
    return false // not airplane
}


