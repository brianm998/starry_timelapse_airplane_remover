import Foundation

func paint_score_from(lines: [Line]) -> Double { // greater than 0.5 means paint
    if lines.count < 10 { return 0 }
    let first_count = lines[0].count
    let last_count = lines[lines.count-1].count
    let mid_count = (first_count - last_count) / 2
    var line_counts: Set<Int> = []
    var mid_value: Double?
    for (index, line) in lines.enumerated() {
        line_counts.insert(line.count)
        if mid_value == nil && lines[index].count <= mid_count {
            mid_value = Double(index) / Double(lines.count)
	}
    }
    let counts_over_lines = Double(line_counts.count) / Double(lines.count)
    if let mid_value = mid_value {
        var keys_over_lines_score: Double = 0
        var mid_value_score: Double = 0
        if counts_over_lines < OAS_AIRPLANE_KEYS_OVER_LINES_AVG {
            keys_over_lines_score = 1
        } else if counts_over_lines > OAS_NON_AIRPLANE_KEYS_OVER_LINES_AVG {
            keys_over_lines_score = 0
        } else {
            keys_over_lines_score = (counts_over_lines - OAS_AIRPLANE_KEYS_OVER_LINES_AVG) /
                       (OAS_NON_AIRPLANE_KEYS_OVER_LINES_AVG-OAS_AIRPLANE_KEYS_OVER_LINES_AVG)
        }

        if mid_value < OAS_AIRPLANE_MID_VALUE_AVG {
            mid_value_score = 1
        } else if mid_value > OAS_NON_AIRPLANE_MID_VALUE_AVG {
            mid_value_score = 0
        } else {
            mid_value_score = (mid_value - OAS_AIRPLANE_MID_VALUE_AVG) /
                       (OAS_NON_AIRPLANE_MID_VALUE_AVG-OAS_AIRPLANE_MID_VALUE_AVG)
        }
        return (keys_over_lines_score + mid_value_score)/2

    }
    return 0
}

func paint_score_from(groupSize group_size: UInt64) -> Double { // returns values between 0 and 1
    if group_size < UInt64(OAS_NON_AIRPLANE_GROUP_SIZE_AVG) { return 0 }
    if group_size > UInt64(OAS_AIRPLANE_GROUP_SIZE_AVG)     { return 1 }
    return Double(group_size) - OAS_NON_AIRPLANE_GROUP_SIZE_AVG /
      (OAS_AIRPLANE_GROUP_SIZE_AVG - OAS_NON_AIRPLANE_GROUP_SIZE_AVG)
}


func paint_score_from(fillAmount fill_amount: Double) -> Double { // returns values between 0 and 1
    if fill_amount > OAS_NON_AIRPLANE_FILL_AMOUNT_AVG { return 1 }
    if fill_amount < OAS_AIRPLANE_FILL_AMOUNT_AVG     { return 0 }
    return fill_amount - OAS_AIRPLANE_FILL_AMOUNT_AVG /
      (OAS_NON_AIRPLANE_FILL_AMOUNT_AVG - OAS_AIRPLANE_FILL_AMOUNT_AVG)
}

func paint_score_from(aspectRatio aspect_ratio: Double) -> Double { // returns values between 0 and 1
    if aspect_ratio > OAS_NON_AIRPLANE_ASPECT_RATIO_AVG { return 0 }
    if aspect_ratio < OAS_AIRPLANE_ASPECT_RATIO_AVG     { return 1 }
    return aspect_ratio - OAS_NON_AIRPLANE_ASPECT_RATIO_AVG /
      (OAS_NON_AIRPLANE_ASPECT_RATIO_AVG - OAS_AIRPLANE_ASPECT_RATIO_AVG)
}
