import Foundation

// generated on Wed Oct 19 06:22:54 PDT 2022

// data used from 56 airplane records and 706762 non airplane records

// this is auto generated code, run regenerate_shouldPaint.sh to remake it, DO NOT EDIT BY HAND

// the unix time this file was created
let paint_group_logic_time = 1666185774

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

    if(group_size < 67) { return false } // not airplane
    if(group_size > 521) { return true } // is airplane
    if(aspect_ratio < 0.210526315789474) { return true } // is airplane
    if(amount_filled > 0.587962962962963) { return false } // notAirplane
    if(amount_filled < 0.188618925831202) { return false } // notAirplane
    if(aspect_ratio > 0.214285714285714) { return false } // notAirplane
    if(aspect_ratio < 0.184782608695652) { return true } // airplane
    return false // not airplane
}


