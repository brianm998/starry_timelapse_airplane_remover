/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation

@available(macOS 10.15, *) 
actor OutlierGroup {
    let name: String
    let size: UInt              // number of pixels in this outlier group
    let bounds: BoundingBox     // a bounding box on the image that contains this group
    let brightness: UInt        // the average amount of brightness over the limit
    let frame: FrameAirplaneRemover

    var shouldPaint: PaintReason? // should we paint this group, and why?

    var lines: [Line] = []      // sorted lines from the hough transform of this outlier group

    var line: Line { return lines[0] } // returns the first, most likely line 

    private var _paint_score_from_lines: Double?
    
    init(name: String,
         size: UInt,
         brightness: UInt,
         bounds: BoundingBox,
         frame: FrameAirplaneRemover)
    {
        self.name = name
        self.size = size
        self.brightness = brightness
        self.bounds = bounds
        self.frame = frame
    }
    
    var value_score: Double {
        let mpd = frame.max_pixel_distance
        if self.brightness < mpd {
            return 0
        } else {
            let max = UInt(mpd)
            let score = Double(self.brightness - max)/Double(max)*20
            if score > 100 {
                return 100
            } else {
                return score
            }
        }
    }

    var score: Double {
        var overall_score =
          size_score +
          aspect_ratio_score + 
          (value_score/100) + 
          paint_score_from_lines
        
        overall_score /= 4
        return overall_score
    }

    func shouldPaint(_ should_paint: PaintReason) {
        self.shouldPaint = should_paint
    }

    func setShouldPaintFromScore() async {
        if score > 0.5 {
            //Log.d("frame \(frame_index) should_paint[\(name)] = (true, .goodScore(\(overall_score))")
            self.shouldPaint = .goodScore(score)
        } else {
            //Log.d("frame \(frame_index) should_paint[\(name)] = (false, .badScore(\(overall_score))")
            self.shouldPaint = .badScore(score)
        }
    }
    
    func canPaint() -> PaintReason? {
        return self.shouldPaint
    }

    func setLines(_ lines: [Line]) {
        self.lines = lines
    }

    var paint_score_from_lines: Double {
        if let _paint_score_from_lines = _paint_score_from_lines {
            return _paint_score_from_lines
        }
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
            let ret = (keys_over_lines_score + center_line_count_position_score)/2
            _paint_score_from_lines = ret
            return ret
        }
        return 0
    }

    // groups with larger fill amounts are less likely to be airplanes
    var fill_amount_score: Double {
        let fill_amount = Double(size)/(Double(self.bounds.width)*Double(self.bounds.height))
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
    
    var size_score: Double {
        if self.size < UInt(OAS_NON_AIRPLANES_MIN_GROUP_SIZE) { return 0 }
        if self.size > UInt(OAS_AIRPLANES_MAX_GROUP_SIZE)     { return 1 }

        let airplane_score =
          histogram_lookup(ofValue: Double(self.size),
                           minValue: OAS_AIRPLANES_MIN_GROUP_SIZE, 
                           maxValue: OAS_AIRPLANES_MAX_GROUP_SIZE,
                           stepSize: OAS_AIRPLANES_GROUP_SIZE_STEP_SIZE,
                           histogramValues: OAS_AIRPLANES_GROUP_SIZE_HISTOGRAM) ?? 0

        let non_airplane_score =
          histogram_lookup(ofValue: Double(self.size),
                           minValue: OAS_NON_AIRPLANES_MIN_GROUP_SIZE, 
                           maxValue: OAS_NON_AIRPLANES_MAX_GROUP_SIZE,
                           stepSize: OAS_NON_AIRPLANES_GROUP_SIZE_STEP_SIZE,
                           histogramValues: OAS_NON_AIRPLANES_GROUP_SIZE_HISTOGRAM) ?? 0

        return airplane_score / (non_airplane_score+airplane_score)
    }

    // smaller aspect ratios are more likely to be airplanes
    var aspect_ratio_score: Double {
        let aspect_ratio = Double(self.bounds.width) / Double(self.bounds.height)
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
