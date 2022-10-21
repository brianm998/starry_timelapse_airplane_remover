import Foundation

// generated on Fri Oct 21 09:22:17 PDT 2022

// data used from 137 airplane records and 1084227 non airplane records

// this is auto generated code, run regenerate_shouldPaint.sh to remake it, DO NOT EDIT BY HAND

// the unix time this file was created
let paint_group_logic_time = 1666369337

let airplane_min_size = 20
let airplane_max_size = 7502

let non_airplane_min_size = 4
let non_airplane_max_size = 521

let airplane_min_aspect_ratio = 0.0461538461538462
let airplane_max_aspect_ratio = 1

let non_airplane_min_aspect_ratio = 0.1
let non_airplane_max_aspect_ratio = 1

let airplane_min_fill = 1.33371740005121
let airplane_max_fill = 74.0740740740741

let non_airplane_min_fill = 10.8664772727273
let non_airplane_max_fill = 400

let airplane_size_histogram = [
    99,
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
    1063961,
    18178,
    1500,
    366,
    121,
    56,
    25,
    9,
    7,
    3,
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
    44,
    28,
    20,
    14,
    12,
    6,
    4,
    3,
    3,
    2,
    1,
]

let non_airplane_fill_histogram = [
    171,
    4960,
    35389,
    88302,
    135060,
    189627,
    71869,
    88257,
    77525,
    208864,
    154,
    12766,
    78263,
    1784,
    13625,
    0,
    0,
    0,
    0,
    0,
    69361,
]
let airplane_aspect_ratio_histogram = [
    29,
    17,
    24,
    14,
    15,
    12,
    8,
    6,
    7,
    4,
    1,
]

let non_airplane_aspect_ratio_histogram = [
    117,
    478,
    2436,
    12244,
    1403,
    64223,
    14240,
    5111,
    320484,
    523,
    6979,
    29626,
    154434,
    6014,
    78757,
    31580,
    14601,
    2637,
    208,
    3,
    338129,
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
    if(aspect_ratio < 0.125) { return true } // is airplane

    // outlier groups with a higher fill amount aren't airplanes
    if(amount_filled > 0.644444444444444) { return false } // notAirplane

    // outlier groups with a lower fill amount aren't airplanes
    if(amount_filled < 0.159413434247871) { return false } // notAirplane

    // outlier groups with a larger aspect ratio aren't airplanes
    if(aspect_ratio > 0.137931034482759) { return false } // notAirplane

    //  groups with a smaller aspect ratio are airplanes
    if(aspect_ratio < 0.123076923076923) { return true } // airplane

    // with 0.137931034482759 > 0.123076923076923,
    // no outlier groups from the testing group reached this point

    Log.w("unable to properly detect outlier with width \(bounding_box_width) height \(bounding_box_height) and size \(group_size) further data collection and refinement in categorize.pl is necessary to resolve this")

    return false // guess it's not an airplane
}
