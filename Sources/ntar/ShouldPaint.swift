import Foundation

func paint_score_from(lines: [Line]) -> Double { // greater than 0.5 means paint
    if lines.count < 10 { return 0 }
    let first_count = lines[0].count
    let last_count = lines[lines.count-1].count
    let mid_count = (first_count - last_count) / 2
    var line_counts: Set<Int> = []
    var center_line_count_position: Double?
    for (index, line) in lines.enumerated() {
        line_counts.insert(line.count)
        if center_line_count_position == nil && lines[index].count <= mid_count {
            center_line_count_position = Double(index) / Double(lines.count)
	}
    }
    let counts_over_lines = Double(line_counts.count) / Double(lines.count)
    if let center_line_count_position = center_line_count_position {
        var keys_over_lines_score: Double = 0
        var center_line_count_position_score: Double = 0
        if counts_over_lines < OAS_AIRPLANE_KEYS_OVER_LINES_AVG {
            keys_over_lines_score = 1
        } else if counts_over_lines > OAS_NON_AIRPLANE_KEYS_OVER_LINES_AVG {
            keys_over_lines_score = 0
        } else {
            keys_over_lines_score = (counts_over_lines - OAS_AIRPLANE_KEYS_OVER_LINES_AVG) /
                       (OAS_NON_AIRPLANE_KEYS_OVER_LINES_AVG-OAS_AIRPLANE_KEYS_OVER_LINES_AVG)
        }

        if center_line_count_position < OAS_AIRPLANE_CENTER_LINE_COUNT_POSITION_AVG {
            center_line_count_position_score = 1
        } else if center_line_count_position > OAS_NON_AIRPLANE_CENTER_LINE_COUNT_POSITION_AVG {
            center_line_count_position_score = 0
        } else {
            center_line_count_position_score =
              (center_line_count_position - OAS_AIRPLANE_CENTER_LINE_COUNT_POSITION_AVG) /
              (OAS_NON_AIRPLANE_CENTER_LINE_COUNT_POSITION_AVG -
               OAS_AIRPLANE_CENTER_LINE_COUNT_POSITION_AVG)
        }
        return (keys_over_lines_score + center_line_count_position_score)/2

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
