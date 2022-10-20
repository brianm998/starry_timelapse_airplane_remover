import Foundation

// generated on Thu Oct 20 15:42:54 PDT 2022

// data used from 114 airplane records and 910950 non airplane records

// this is auto generated code, run regenerate_shouldPaint.sh to remake it, DO NOT EDIT BY HAND

// the unix time this file was created
let paint_group_logic_time = 1666305774

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

    // outlier groups smaller aren't airplanes
    if(group_size < 55) { return false } // not airplane

    // outlier groups larger are airplanes
    if(group_size > 1432) { return true } // is airplane

    // outlier groups with a smaller aspect ratio are airplanes
    if(aspect_ratio < 0.125) { return true } // is airplane

    // outlier groups with a higher fill amount aren't airplanes
    if(amount_filled > 0.502463054187192) { return false } // notAirplane

    // outlier groups with a lower fill amount aren't airplanes
    if(amount_filled < 0.15264367816092) { return false } // notAirplane

    // outlier groups with a larger aspect ratio aren't airplanes
    if(aspect_ratio > 0.272727272727273) { return false } // notAirplane

    //  groups with a smaller aspect ratio are airplanes
    if(aspect_ratio < 0.120689655172414) { return true } // airplane

    // with 0.272727272727273 > 0.120689655172414,
    // no outlier groups from the testing group reached this point

    Log.w("unable to properly detect outlier with width \(bounding_box_width) height \(bounding_box_height) and size \(group_size) further data collection and refinement in categorize.pl is necessary to resolve this")

    return false // guess it's not an airplane
}
