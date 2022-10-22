import Foundation

// generated on Fri Oct 21 21:14:18 PDT 2022

// data used from 140 airplane records and 1164143 non airplane records

// this is auto generated code, run regenerate_shouldPaint.sh to remake it, DO NOT EDIT BY HAND

// the unix time this file was created
let paint_group_logic_time = 1666412058

let airplane_min_size = 20
let airplane_max_size = 7502

let non_airplane_min_size = 4
let non_airplane_max_size = 521

let airplane_min_aspect_ratio = 0.0510204081632653
let airplane_max_aspect_ratio = 1

let non_airplane_min_aspect_ratio = 0.0909090909090909
let non_airplane_max_aspect_ratio = 1

let airplane_min_fill = 0.0132756250967114
let airplane_max_fill = 0.665656565656566

let non_airplane_min_fill = 0.103030303030303
let non_airplane_max_fill = 1

let airplane_size_histogram = [
    102,
    20,
    10,
    2,
    1,
    2,
    1,
    0,
    0,
    1,
    1,
]

let non_airplane_size_histogram = [
    1142060,
    19785,
    1655,
    400,
    132,
    59,
    29,
    11,
    7,
    4,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    1,
]
let airplane_fill_histogram = [
    43,
    31,
    18,
    19,
    11,
    5,
    6,
    4,
    2,
    0,
    1,
]

let non_airplane_fill_histogram = [
    2,
    9,
    74,
    378,
    1319,
    4498,
    12592,
    25829,
    74419,
    47848,
    136583,
    109907,
    324261,
    46208,
    88145,
    52814,
    102092,
    28326,
    6194,
    43,
    102602,
]
let airplane_aspect_ratio_histogram = [
    28,
    18,
    23,
    15,
    14,
    15,
    8,
    7,
    7,
    4,
    1,
]

let non_airplane_aspect_ratio_histogram = [
    3,
    119,
    874,
    8107,
    750,
    3175,
    14602,
    5705,
    83306,
    1022,
    12972,
    55292,
    315527,
    15057,
    156449,
    85445,
    44955,
    6956,
    371,
    7,
    353449,
]

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
    if(group_size < 20) { return false } // not airplane

    // outlier groups larger are airplanes
    if(group_size > 521) { return true } // is airplane

    // outlier groups with a smaller aspect ratio are airplanes
    if(aspect_ratio < 0.16) { return true } // is airplane

    // outlier groups with a higher fill amount aren't airplanes
    if(amount_filled > 0.521917808219178) { return false } // notAirplane

    // outlier groups with a lower fill amount aren't airplanes
    if(amount_filled < 0.14780701754386) { return false } // notAirplane

    // outlier groups with a larger aspect ratio aren't airplanes
    if(aspect_ratio > 0.166666666666667) { return false } // notAirplane

    //  groups with a smaller aspect ratio are airplanes
    if(aspect_ratio < 0.147540983606557) { return true } // airplane

    // with 0.166666666666667 > 0.147540983606557,
    // no outlier groups from the testing group reached this point

    Log.w("unable to properly detect outlier with width \(bounding_box_width) height \(bounding_box_height) and size \(group_size) further data collection and refinement in categorize.pl is necessary to resolve this")

    return false // guess it's not an airplane
}
