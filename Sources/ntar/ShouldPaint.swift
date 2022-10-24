import Foundation

// generated on Sat Oct 22 11:31:27 PDT 2022

// data used from 37 airplane records and 131486 non airplane records

// this is auto generated code, run regenerate_shouldPaint.sh to remake it, DO NOT EDIT BY HAND

// the unix time this file was created
let paint_group_logic_time = 1666463487

let airplane_min_size: UInt64 = 77
let airplane_max_size: UInt64 = 6857
let airplane_size_step_size: Double = 678

let non_airplane_min_size: UInt64 = 4
let non_airplane_max_size: UInt64 = 129
let non_airplane_size_step_size: Double = 12.5

let airplane_min_aspect_ratio: Double = 0.0511811023622047
let airplane_max_aspect_ratio: Double = 0.857740585774059
let airplane_aspect_ratio_step_size: Double = 0.0806559483411854

let non_airplane_min_aspect_ratio: Double = 0.142857142857143
let non_airplane_max_aspect_ratio: Double = 1
let non_airplane_aspect_ratio_step_size: Double = 0.0857142857142857

let airplane_min_fill: Double = 0.0178154100600439
let airplane_max_fill: Double = 0.457875457875458
let airplane_fill_step_size: Double = 0.0440060047815414

let non_airplane_min_fill: Double = 0.171945701357466
let non_airplane_max_fill: Double = 1
let non_airplane_fill_step_size: Double = 0.0828054298642534

let airplane_size_histogram = [
    0.72972972972973,
    0.162162162162162,
    0.027027027027027,
    0,
    0.027027027027027,
    0,
    0,
    0,
    0,
    0.027027027027027,
    0.027027027027027,
]

let non_airplane_size_histogram = [
    0.913519310040613,
    0.0725476476583058,
    0.0105790730572076,
    0.00229682247539662,
    0.000608429794807052,
    0.000235766545487733,
    0.000106475214091234,
    3.80268621754407e-05,
    4.56322346105289e-05,
    1.52107448701763e-05,
    7.60537243508815e-06,
]
let airplane_fill_histogram = [
    0.27027027027027,
    0.216216216216216,
    0.135135135135135,
    0.108108108108108,
    0.0540540540540541,
    0.108108108108108,
    0,
    0.0540540540540541,
    0.027027027027027,
    0,
    0.027027027027027,
]

let non_airplane_fill_histogram = [
    0.000342241759578967,
    0.00292046301507385,
    0.0144197861369271,
    0.0761069619579271,
    0.14022025158572,
    0.353467289293157,
    0.122416074715179,
    0.154442298039335,
    0.0387265564394688,
    0.00174163028763519,
    0.0951964467699983,
]

let airplane_aspect_ratio_histogram = [
    0.216216216216216,
    0.0540540540540541,
    0.189189189189189,
    0.135135135135135,
    0.108108108108108,
    0.0810810810810811,
    0.108108108108108,
    0.0540540540540541,
    0,
    0.027027027027027,
    0.027027027027027,
]

let non_airplane_aspect_ratio_histogram = [
    0.0011560166101334,
    0.00869294069330575,
    0.00431985154313007,
    0.0171577202135589,
    0.0705854615700531,
    0.0511385242535327,
    0.277193009141658,
    0.215878496569977,
    0.0325966262567878,
    0.000114080586526322,
    0.321167272561337,
]

func airplane_size_histogram_value(for size: UInt64) -> Double {
    if size < airplane_min_size { return 0 }
    if size > airplane_max_size { return 0 }

    let histogram_index = Int(Double(size - airplane_min_size)/airplane_size_step_size)

    return airplane_size_histogram[histogram_index]
}

func non_airplane_size_histogram_value(for size: UInt64) -> Double {
    if size < non_airplane_min_size { return 0 }
    if size > non_airplane_max_size { return 0 }

    let histogram_index = Int(Double(size - non_airplane_min_size)/non_airplane_size_step_size)

    return non_airplane_size_histogram[histogram_index]
}

func airplane_aspect_ratio_histogram_value(for aspect_ratio: Double) -> Double {
    if aspect_ratio < airplane_min_aspect_ratio { return 0 }
    if aspect_ratio > airplane_max_aspect_ratio { return 0 }

    let histogram_index = Int((aspect_ratio - airplane_min_aspect_ratio)/airplane_aspect_ratio_step_size)

    return airplane_aspect_ratio_histogram[histogram_index]
}

func non_airplane_aspect_ratio_histogram_value(for aspect_ratio: Double) -> Double {
    if aspect_ratio < non_airplane_min_aspect_ratio { return 0 }
    if aspect_ratio > non_airplane_max_aspect_ratio { return 0 }

    let histogram_index = Int((aspect_ratio - non_airplane_min_aspect_ratio)/non_airplane_aspect_ratio_step_size)

    return non_airplane_aspect_ratio_histogram[histogram_index]
}

func airplane_fill_histogram_value(for fill: Double) -> Double {
    if fill < airplane_min_fill { return 0 }
    if fill > airplane_max_fill { return 0 }

    let histogram_index = Int((fill - airplane_min_fill)/airplane_fill_step_size)

    return airplane_fill_histogram[histogram_index]
}

func non_airplane_fill_histogram_value(for fill: Double) -> Double {
    if fill < non_airplane_min_fill { return 0 }
    if fill > non_airplane_max_fill { return 0 }

    let histogram_index = Int((fill - non_airplane_min_fill)/non_airplane_fill_step_size)

    return non_airplane_fill_histogram[histogram_index]
}

func shouldPaintGroup(min_x: Int, min_y: Int,
                      max_x: Int, max_y: Int,
                      group_name: String,
                      group_size: UInt64) -> Bool
{
    let bounding_box_width = max_x - min_x + 1
    let bounding_box_height = max_y - min_y + 1

    // the size of the bounding box in number of pixels
    let max_pixels = bounding_box_width * bounding_box_height

    // how much (betwen 0 and 1) of the bounding box is filled by outliers?
    let amount_filled = Double(group_size)/Double(max_pixels)

    // the aspect ratio of the bounding box.
    // 1 is square, closer to zero is more regangular.
    var aspect_ratio: Double = 0
    if bounding_box_width > bounding_box_height {
        aspect_ratio = Double(bounding_box_height)/Double(bounding_box_width)
    } else {
        aspect_ratio = Double(bounding_box_width)/Double(bounding_box_height)
    }

    // outlier groups smaller aren't airplanes
    if(group_size < 77) { return false } // not airplane

    // outlier groups larger are airplanes
    //if(group_size > 129) { return true } // is airplane

    // outlier groups with a smaller aspect ratio are airplanes
    if(aspect_ratio < 0.347826086956522) { return true } // is airplane

    // outlier groups with a higher fill amount aren't airplanes
    if(amount_filled > 0) { return false } // notAirplane

    // outlier groups with a lower fill amount aren't airplanes
    //if(amount_filled < 1000000000000) { return false } // notAirplane

    // outlier groups with a larger aspect ratio aren't airplanes
    //if(aspect_ratio > 1000000000000) { return false } // notAirplane

    //  groups with a smaller aspect ratio are airplanes
    //if(aspect_ratio < 0) { return true } // airplane

    // with 1000000000000 > 0,
    // no outlier groups from the testing group reached this point

    //Log.w("unable to properly detect outlier with width \(bounding_box_width) height \(bounding_box_height) and size \(group_size) further data collection and refinement in categorize.pl is necessary to resolve this")

    let is_airplane_from_size = airplane_size_histogram_value(for: group_size)
    let is_non_airplane_from_size = non_airplane_size_histogram_value(for: group_size)

    let is_airplane_from_aspect_ratio = airplane_aspect_ratio_histogram_value(for: aspect_ratio)
    let is_non_airplane_from_aspect_ratio = non_airplane_aspect_ratio_histogram_value(for: aspect_ratio)

    let is_airplane_from_fill = airplane_fill_histogram_value(for: amount_filled)
    let is_non_airplane_from_fill = non_airplane_fill_histogram_value(for: amount_filled)

    let is_airplane = is_airplane_from_size + is_airplane_from_aspect_ratio + is_airplane_from_fill
    let is_non_airplane = is_non_airplane_from_size + is_non_airplane_from_aspect_ratio + is_non_airplane_from_fill

    let ret = is_airplane > is_non_airplane

    if is_airplane_from_aspect_ratio < is_non_airplane_from_aspect_ratio {
        //Log.w("for size \(group_size) aspect_ratio \(aspect_ratio) fill \(amount_filled) using is_airplane_from_aspect_ratio \(is_airplane_from_aspect_ratio) < \(is_non_airplane_from_aspect_ratio) false")
        return false
    }

    if ret {
        Log.i("is_airplane from_size \(is_airplane_from_size) \(is_non_airplane_from_size) from_aspect_ratio \(is_airplane_from_aspect_ratio) \(is_non_airplane_from_aspect_ratio) from_fill \(is_airplane_from_fill) \(is_non_airplane_from_fill)")

        Log.w("for size \(group_size) aspect_ratio \(aspect_ratio) fill \(amount_filled) using is_airplane \(is_airplane) is_non_airplane \(is_non_airplane) for \(ret)")
    }
    return ret
}
