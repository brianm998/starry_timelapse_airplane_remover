/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import Cocoa

enum PaintScoreType {
    case houghTransform // based upon the lines returned from a hough transform
    case fillAmount     // based upon the amount of the bounding box that has pixels from this group
    case groupSize      // based upon the number of pixels in this group
    case aspectRatio    // based upon the aspect ratio of this groups bounding box
    case surfaceAreaRatio       //  based upon the surface area to size ratio
    case brightness     // based upon the relative brightness of this group
    case combined       // a combination, not using fillAmount
}

// represents a single outler group in a frame
@available(macOS 10.15, *) 
public actor OutlierGroup: CustomStringConvertible, Hashable, Equatable, Comparable {

    public let name: String
    public let size: UInt              // number of pixels in this outlier group
    public let bounds: BoundingBox     // a bounding box on the image that contains this group
    public let brightness: UInt        // the average amount per pixel of brightness over the limit 
    public let lines: [Line]           // sorted lines from the hough transform of this outlier group
    public let frame: FrameAirplaneRemover
    public let pixels: [UInt32]        // indexed by y * bounds.width + x, true if part of this group
                                // zero if pixel if not part of group, brightness value otherwise
    public let max_pixel_distance: UInt16
    public let surfaceAreaToSizeRatio: Double

    // after init, shouldPaint is usually set to a base value based upon different statistics 
    public var shouldPaint: PaintReason? // should we paint this group, and why?

    // returns the first, most likely line, if any
    var line: Line? {
        if lines.count > 0 {
            return lines[0]
        }
        return nil
    } 

    public static func == (lhs: OutlierGroup, rhs: OutlierGroup) -> Bool {
        return lhs.name == rhs.name && lhs.frame.frame_index == rhs.frame.frame_index
    }
    
    public static func < (lhs: OutlierGroup, rhs: OutlierGroup) -> Bool {
        return lhs.name < rhs.name
    }
    
    nonisolated public var description: String {
        "outlier group \(frame.frame_index).\(name) size \(size) "
    }
    
    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(frame.frame_index)
    }

    public func shouldPaint(_ should_paint: PaintReason) {
        //Log.d("\(self) should paint \(should_paint)")
        self.shouldPaint = should_paint
    }

    func paintScore(from type: PaintScoreType) -> Double {
        switch type {
        case .houghTransform:
            return self.paintScoreFromHoughTransformLines
        case .groupSize:
            return self.paintScoreFromGroupSize
        case .aspectRatio:
            return self.paintScoreFromAspectRatio
        case .surfaceAreaRatio:
            return self.paintScoreFromSurfaceAreaRatio            
        case .brightness:
            return self.paintScoreFromBrightness
        case .fillAmount:       // XXX not used right now
            return self.paintScoreFromFillAmount
        case .combined:
            var totalScore: Double = 0
            var totalWeight: Double = 0

            let weights: [PaintScoreType: Double]
              = [.houghTransform:   3,
//                 .surfaceAreaRatio: 0.2,
                 .groupSize:        0.6,
//                 .aspectRatio:      0.1,
                 .brightness:       1.5]

            for (type, weight) in weights {
                totalScore += self.paintScore(from: type) * weight
                totalWeight += weight
            }

            let ret = totalScore / totalWeight

            if ret > 0.5 {
                var logmsg = "\(self) paintScore \(ret) from "
                for (type, weight) in weights {
                    logmsg += "paintScore(from: \(type)) \(self.paintScore(from: type)) * \(weight) "
                }
                Log.d(logmsg)
            }
            
            return ret
        }
    }
    
    // outputs an image the same size as this outlier's bounding box,
    // coloring the outlier pixels red if will paint, green if not
    public func testImage() -> CGImage? {
        let bytesPerPixel = 64/8
        
        var image_data = Data(count: self.bounds.width*self.bounds.height*bytesPerPixel)
        for x in 0 ..< self.bounds.width {
            for y in 0 ..< self.bounds.height {
                let pixel_index = y*self.bounds.width + x
                var pixel = Pixel()
                if self.pixels[pixel_index] != 0 {                    
                    if let reason = self.shouldPaint {
                        if reason.willPaint {
                            pixel.red = 0xFFFF
                            pixel.alpha = 0xFFFF
                          } else {
                            pixel.green = 0xFFFF
                            pixel.alpha = 0xFFFF
                        }

                        var nextValue = pixel.value
                        
                        let offset = (Int(y) * bytesPerPixel*self.bounds.width) + (Int(x) * bytesPerPixel)
                        
                        image_data.replaceSubrange(offset ..< offset+bytesPerPixel,
                                                   with: &nextValue,
                                                   count: bytesPerPixel)
                    }
                }
            }
        }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let dataProvider = CGDataProvider(data: image_data as CFData) {
            return CGImage(width: self.bounds.width,
                           height: self.bounds.height,
                           bitsPerComponent: 16,
                           bitsPerPixel: bytesPerPixel*8,
                           bytesPerRow: self.bounds.width*bytesPerPixel,
                           space: colorSpace,
                           bitmapInfo: bitmapInfo,
                           provider: dataProvider,
                           decode: nil,
                           shouldInterpolate: false,
                           intent: .defaultIntent)
        } else {
            return nil
        }
    }
    
    init(name: String,
         size: UInt,
         brightness: UInt,
         bounds: BoundingBox,
         frame: FrameAirplaneRemover,
         pixels: [UInt32],
         max_pixel_distance: UInt16) async
    {
        self.name = name
        self.size = size
        self.brightness = brightness
        self.bounds = bounds
        self.frame = frame
        self.pixels = pixels
        self.max_pixel_distance = max_pixel_distance
        self.surfaceAreaToSizeRatio = surface_area_to_size_ratio(of: pixels,
                                                                 width: bounds.width,
                                                                 height: bounds.height)
        // do a hough transform on just this outlier group
        let transform = HoughTransform(data_width: bounds.width,
                                       data_height: bounds.height,
                                       input_data: pixels,
                                       max_pixel_distance: max_pixel_distance)
        
        self.lines = transform.lines(min_count: 1)

        if self.shouldPaint == nil,
           self.paintScoreFromHoughTransformLines > 0.5
        {
            if size < 300 { // XXX constant XXX
                // don't assume small ones are lines
            } else {
                //Log.d("frame \(frame.frame_index) will paint group \(name) because it looks like a line from the group hough transform")
                self.shouldPaint = .looksLikeALine(self.paintScoreFromHoughTransformLines)
            }
        }
            
        if self.shouldPaint == nil { setShouldPaintFromCombinedScore() }

        //Log.d("frame \(frame.frame_index) group \(self) bounds \(bounds) should_paint \(self.shouldPaint?.willPaint) reason \(String(describing: self.shouldPaint)) hough transform score \(paintScore(from: .houghTransform)) aspect ratio \(paintScore(from: .aspectRatio)) brightness score \(paintScore(from: .brightness)) size score \(paintScore(from: .groupSize)) combined \(paintScore(from: .combined)) ")
    }

    func setShouldPaintFromCombinedScore() {
        let score = self.paintScore(from: .combined)
        if score > 0.5 {
            //Log.d("frame \(frame.frame_index) should_paint[\(name)] = (true, .goodScore(\(score))")
            self.shouldPaint = .goodScore(score)
        } else {
            //Log.d("frame \(frame.frame_index) should_paint[\(name)] = (false, .badScore(\(score))")
            self.shouldPaint = .badScore(score)
        }
    }
    
    // used so we don't recompute on every access
    private var _paint_score_from_lines: Double?
    
    private var paintScoreFromHoughTransformLines: Double {
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
    private var paintScoreFromFillAmount: Double {
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
    
    private var paintScoreFromGroupSize: Double {
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
    private var paintScoreFromAspectRatio: Double {
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

    private var paintScoreFromSurfaceAreaRatio: Double {
        let airplane_score =
          histogram_lookup(ofValue: surfaceAreaToSizeRatio,
                           minValue: OAS_AIRPLANES_MIN_SURFACE_AREA_RATIO, 
                           maxValue: OAS_AIRPLANES_MAX_SURFACE_AREA_RATIO,
                           stepSize: OAS_AIRPLANES_SURFACE_AREA_RATIO_STEP_SIZE,
                           histogramValues: OAS_AIRPLANES_SURFACE_AREA_RATIO_HISTOGRAM) ?? 0
        
        let non_airplane_score =
          histogram_lookup(ofValue: surfaceAreaToSizeRatio,
                           minValue: OAS_NON_AIRPLANES_MIN_SURFACE_AREA_RATIO, 
                           maxValue: OAS_NON_AIRPLANES_MAX_SURFACE_AREA_RATIO,
                           stepSize: OAS_NON_AIRPLANES_SURFACE_AREA_RATIO_STEP_SIZE,
                           histogramValues: OAS_NON_AIRPLANES_SURFACE_AREA_RATIO_HISTOGRAM) ?? 0
        
        return airplane_score / (non_airplane_score+airplane_score)
    }

    private var paintScoreFromBrightness: Double {
        let mpd = frame.config.max_pixel_distance
        if self.brightness < mpd {
            return 0
        } else {
            let max = UInt(mpd)
            let score = Double(self.brightness - max)/Double(max)*20
            if score > 100 {
                return 1
            } else {
                return score/100
            }
        }
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

public func surface_area_to_size_ratio(of pixels: [UInt32], width: Int, height: Int) -> Double {
    var size: Int = 0
    var surface_area: Int = 0
    for x in 0 ..< width {
        for y in 0 ..< height {
            let index = y * width + x

            if pixels[index] != 0 {
                size += 1

                var has_top_neighbor = false
                var has_bottom_neighbor = false
                var has_left_neighbor = false
                var has_right_neighbor = false
                
                if x > 0 {
                    if pixels[y * width + x - 1] != 0 {
                        has_left_neighbor = true
                    }
                }
                if y > 0 {
                    if pixels[(y - 1) * width + x] != 0 {
                        has_top_neighbor = true
                    }
                }
                if x + 1 < width {
                    if pixels[y * width + x + 1] != 0 {
                        has_right_neighbor = true
                    }
                }
                if y + 1 < height {
                    if pixels[(y + 1) * width + x] != 0 {
                        has_bottom_neighbor = true
                    }
                }
                
                if has_top_neighbor,
                   has_bottom_neighbor,
                   has_left_neighbor,
                   has_right_neighbor
                {
                    
                } else {
                    surface_area += 1
                }
            }
        }
    }
    return Double(surface_area)/Double(size)
}
