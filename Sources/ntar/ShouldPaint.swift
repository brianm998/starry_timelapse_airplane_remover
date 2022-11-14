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
        if counts_over_lines < OAS_AIRPLANES_MIN_KEYS_OVER_LINES {
            keys_over_lines_score = 1
        } else if counts_over_lines > OAS_NON_AIRPLANES_MAX_KEYS_OVER_LINES {
            keys_over_lines_score = 0
        } else {
            let value = Double(counts_over_lines)
            let airplane_score =
              histogram_lookup(ofValue: value,
                               minValue: OAS_AIRPLANES_MIN_KEYS_OVER_LINES, 
                               maxValue: OAS_AIRPLANES_MAX_KEYS_OVER_LINES,
                               stepSize: OAS_AIRPLANES_KEYS_OVER_LINES_STEP_SIZE,
                               histogramValues: OAS_AIRPLANES_KEYS_OVER_LINES_HISTOGRAM) ?? 0

            let non_airplane_score =
              histogram_lookup(ofValue: value,
                               minValue: OAS_NON_AIRPLANES_MIN_KEYS_OVER_LINES, 
                               maxValue: OAS_NON_AIRPLANES_MAX_KEYS_OVER_LINES,
                               stepSize: OAS_NON_AIRPLANES_KEYS_OVER_LINES_STEP_SIZE,
                               histogramValues: OAS_NON_AIRPLANES_KEYS_OVER_LINES_HISTOGRAM) ?? 0

            keys_over_lines_score = airplane_score / (non_airplane_score+airplane_score)
        }

        if center_line_count_position < OAS_AIRPLANES_MIN_CENTER_LINE_COUNT_POSITION {
            center_line_count_position_score = 1
        } else if center_line_count_position > OAS_NON_AIRPLANES_MAX_CENTER_LINE_COUNT_POSITION {
            center_line_count_position_score = 0
        } else {
            let value = Double(center_line_count_position)
            let airplane_score =
              histogram_lookup(ofValue: value,
                               minValue: OAS_AIRPLANES_MIN_CENTER_LINE_COUNT_POSITION, 
                               maxValue: OAS_AIRPLANES_MAX_CENTER_LINE_COUNT_POSITION,
                               stepSize: OAS_AIRPLANES_CENTER_LINE_COUNT_POSITION_STEP_SIZE,
                               histogramValues: OAS_AIRPLANES_CENTER_LINE_COUNT_POSITION_HISTOGRAM) ?? 0

            let non_airplane_score =
              histogram_lookup(ofValue: value,
                               minValue: OAS_NON_AIRPLANES_MIN_CENTER_LINE_COUNT_POSITION, 
                               maxValue: OAS_NON_AIRPLANES_MAX_CENTER_LINE_COUNT_POSITION,
                               stepSize: OAS_NON_AIRPLANES_CENTER_LINE_COUNT_POSITION_STEP_SIZE,
                               histogramValues: OAS_NON_AIRPLANES_CENTER_LINE_COUNT_POSITION_HISTOGRAM) ?? 0

            center_line_count_position_score = airplane_score / (non_airplane_score+airplane_score)
        }
        return (keys_over_lines_score + center_line_count_position_score)/2

    }
    return 0
}

// bigger groups are more likely to be airplanes
func paint_score_from(groupSize group_size: UInt) -> Double { // returns values between 0 and 1
    if group_size < UInt(OAS_NON_AIRPLANES_MIN_GROUP_SIZE) { return 0 }
    if group_size > UInt(OAS_AIRPLANES_MAX_GROUP_SIZE)     { return 1 }

    let airplane_score =
      histogram_lookup(ofValue: Double(group_size),
                       minValue: OAS_AIRPLANES_MIN_GROUP_SIZE, 
                       maxValue: OAS_AIRPLANES_MAX_GROUP_SIZE,
                       stepSize: OAS_AIRPLANES_GROUP_SIZE_STEP_SIZE,
                       histogramValues: OAS_AIRPLANES_GROUP_SIZE_HISTOGRAM) ?? 0

    let non_airplane_score =
      histogram_lookup(ofValue: Double(group_size),
                       minValue: OAS_NON_AIRPLANES_MIN_GROUP_SIZE, 
                       maxValue: OAS_NON_AIRPLANES_MAX_GROUP_SIZE,
                       stepSize: OAS_NON_AIRPLANES_GROUP_SIZE_STEP_SIZE,
                       histogramValues: OAS_NON_AIRPLANES_GROUP_SIZE_HISTOGRAM) ?? 0

    return airplane_score / (non_airplane_score+airplane_score)
}


// groups with larger fill amounts are less likely to be airplanes
func paint_score_from(fillAmount fill_amount: Double) -> Double { // returns values between 0 and 1
    if fill_amount < OAS_AIRPLANES_MIN_FILL_AMOUNT     { return 1 }
    if fill_amount > OAS_NON_AIRPLANES_MAX_FILL_AMOUNT { return 0 }

    let airplane_score =
      histogram_lookup(ofValue: Double(fill_amount),
                       minValue: OAS_AIRPLANES_MIN_FILL_AMOUNT, 
                       maxValue: OAS_AIRPLANES_MAX_FILL_AMOUNT,
                       stepSize: OAS_AIRPLANES_FILL_AMOUNT_STEP_SIZE,
                       histogramValues: OAS_AIRPLANES_FILL_AMOUNT_HISTOGRAM) ?? 0

    let non_airplane_score =
      histogram_lookup(ofValue: Double(fill_amount),
                       minValue: OAS_NON_AIRPLANES_MIN_FILL_AMOUNT, 
                       maxValue: OAS_NON_AIRPLANES_MAX_FILL_AMOUNT,
                       stepSize: OAS_NON_AIRPLANES_FILL_AMOUNT_STEP_SIZE,
                       histogramValues: OAS_NON_AIRPLANES_FILL_AMOUNT_HISTOGRAM) ?? 0

    return airplane_score / (non_airplane_score+airplane_score)
}

// smaller aspect ratios are more likely to be airplanes
func paint_score_from(aspectRatio aspect_ratio: Double) -> Double { // returns values between 0 and 1
    if aspect_ratio < OAS_AIRPLANES_MIN_ASPECT_RATIO     { return 1 }
    if aspect_ratio > OAS_NON_AIRPLANES_MAX_ASPECT_RATIO { return 0 }

    let airplane_score =
      histogram_lookup(ofValue: Double(aspect_ratio),
                       minValue: OAS_AIRPLANES_MIN_ASPECT_RATIO, 
                       maxValue: OAS_AIRPLANES_MAX_ASPECT_RATIO,
                       stepSize: OAS_AIRPLANES_ASPECT_RATIO_STEP_SIZE,
                       histogramValues: OAS_AIRPLANES_ASPECT_RATIO_HISTOGRAM) ?? 0

    let non_airplane_score =
      histogram_lookup(ofValue: Double(aspect_ratio),
                       minValue: OAS_NON_AIRPLANES_MIN_ASPECT_RATIO, 
                       maxValue: OAS_NON_AIRPLANES_MAX_ASPECT_RATIO,
                       stepSize: OAS_NON_AIRPLANES_ASPECT_RATIO_STEP_SIZE,
                       histogramValues: OAS_NON_AIRPLANES_ASPECT_RATIO_HISTOGRAM) ?? 0

    return airplane_score / (non_airplane_score+airplane_score)
}

func histogram_lookup(ofValue value: Double,
                      minValue min_value: Double,
                      maxValue max_value: Double,
                      stepSize step_size: Double,
                      histogramValues histogram_values: [Double]) -> Double?
{
    if value < min_value { return nil }
    if value > max_value { return nil }

    let index = Int((value - min_value)/step_size)
    if index < 0 { return nil }
    if index >= histogram_values.count { return nil }
    return histogram_values[index]
}
