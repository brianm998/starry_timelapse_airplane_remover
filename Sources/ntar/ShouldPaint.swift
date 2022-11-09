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
        if counts_over_lines < airplane_keys_over_lines_avg {
            keys_over_lines_score = 1
        } else if counts_over_lines > non_airplane_keys_over_lines_avg {
            keys_over_lines_score = 0
        } else {
            keys_over_lines_score = (counts_over_lines - airplane_keys_over_lines_avg) /
                       (non_airplane_keys_over_lines_avg-airplane_keys_over_lines_avg)
        }

        if mid_value < airplane_mid_value_avg {
            mid_value_score = 1
        } else if mid_value > non_airplane_mid_value_avg {
            mid_value_score = 0
        } else {
            mid_value_score = (mid_value - airplane_mid_value_avg) /
                       (non_airplane_mid_value_avg-airplane_mid_value_avg)
        }
        return (keys_over_lines_score + mid_value_score)/2

    }
    return 0
}

