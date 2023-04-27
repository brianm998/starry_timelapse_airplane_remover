/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import Cocoa

// these need to be setup at startup so the decision tree values are right
internal var IMAGE_WIDTH: Double?
internal var IMAGE_HEIGHT: Double?

@available(macOS 10.15, *) 
public class OutlierGroups: Codable {
    
    public let frame_index: Int
    public var groups: [String: OutlierGroup]?  // keyed by name

    public init(frame_index: Int,
                groups: [String: OutlierGroup]? = nil)
    {
        self.frame_index = frame_index
        self.groups = groups
    }
    
    public var encodable_groups: [String: OutlierGroupEncodable]? = nil
    
    enum CodingKeys: String, CodingKey {
        case frame_index
        case groups
    }

    public func prepareForEncoding(_ closure: @escaping () -> Void) {
        Log.d("frame \(frame_index) about to prepare for encoding")
        Task {
            Log.d("frame \(frame_index) preparing for encoding")
            var encodable: [String: OutlierGroupEncodable] = [:]
            if let groups = self.groups {
                for (key, value) in groups {
                    encodable[key] = await value.encodable()
                }
                self.encodable_groups = encodable
            } else {
                Log.w("frame \(frame_index) has no group")
            }
            Log.d("frame \(frame_index) done with encoding")
            closure()
        }
    }
    
    public func encode(to encoder: Encoder) throws {
	var container = encoder.container(keyedBy: CodingKeys.self)
	try container.encode(frame_index, forKey: .frame_index)
        if let encodable_groups = encodable_groups {
            Log.d("frame \(frame_index) encodable_groups.count \(encodable_groups.count)")
	    try container.encode(encodable_groups, forKey: .groups)
        } else {
            Log.e("frame \(frame_index) NIL encodable_groups during encode!!!")
        }
    }
}

// represents a single outler group in a frame
@available(macOS 10.15, *) 
public actor OutlierGroup: CustomStringConvertible,
                           Hashable,
                           Equatable,
                           Comparable,
                           Decodable // can't be an actor and codable :(
{
    public let name: String
    public let size: UInt              // number of pixels in this outlier group
    public let bounds: BoundingBox     // a bounding box on the image that contains this group
    public let brightness: UInt        // the average amount per pixel of brightness over the limit 
    public var lines: [Line]           // sorted lines from the hough transform of this outlier group

    // pixel value is zero if pixel is not part of group,
    // otherwise it's the amount brighter this pixel was than those in the adjecent frames 
    public let pixels: [UInt32]        // indexed by y * bounds.width + x

    public let max_pixel_distance: UInt16
    public let surfaceAreaToSizeRatio: Double

    // after init, shouldPaint is usually set to a base value based upon different statistics 
    public var shouldPaint: PaintReason? // should we paint this group, and why?

    public let frame_index: Int

    // has to be optional so we can read OuterlierGroups as codable
    public var frame: FrameAirplaneRemover?

    public func setFrame(_ frame: FrameAirplaneRemover) {
        self.frame = frame
    }
    
    // returns the first, most likely line, if any
    var firstLine: Line? {
        if lines.count > 0 {
            return lines[0]
        }
        return nil
    } 

    init(name: String,
         size: UInt,
         brightness: UInt,      // average brightness
         bounds: BoundingBox,
         frame: FrameAirplaneRemover,
         pixels: [UInt32],
         max_pixel_distance: UInt16) async
    {
        self.name = name
        self.size = size
        self.brightness = brightness
        self.bounds = bounds
        self.frame_index = frame.frame_index
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

        // we want all the lines, all of them.
        self.lines = transform.lines(min_count: 1)
    }

    public static func == (lhs: OutlierGroup, rhs: OutlierGroup) -> Bool {
        return lhs.name == rhs.name && lhs.frame_index == rhs.frame_index
    }
    
    public static func < (lhs: OutlierGroup, rhs: OutlierGroup) -> Bool {
        return lhs.name < rhs.name
    }
    
    nonisolated public var description: String {
        "outlier group \(frame_index).\(name) size \(size) "
    }
    
    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(frame_index)
    }
    
    public func shouldPaint(_ should_paint: PaintReason) {
        //Log.d("\(self) should paint \(should_paint)")
        self.shouldPaint = should_paint
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
                    // the real color is set in the view layer 
                    pixel.red = 0xFFFF
                    pixel.green = 0xFFFF
                    pixel.blue = 0xFFFF
                    pixel.alpha = 0xFFFF

                    var nextValue = pixel.value
                    
                    let offset = (Int(y) * bytesPerPixel*self.bounds.width) + (Int(x) * bytesPerPixel)
                    
                    image_data.replaceSubrange(offset ..< offset+bytesPerPixel,
                                               with: &nextValue,
                                               count: bytesPerPixel)

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

    // how many pixels actually overlap between the groups ?  returns 0-1 value of overlap amount
    @available(macOS 10.15, *)
    func pixelOverlap(with group_2: OutlierGroup) async -> Double // 1 means total overlap, 0 means none
    {
        let group_1 = self
        // throw out non-overlapping frames, do any slip through?
        if group_1.bounds.min.x > group_2.bounds.max.x || group_1.bounds.min.y > group_2.bounds.max.y { return 0 }
        if group_2.bounds.min.x > group_1.bounds.max.x || group_2.bounds.min.y > group_1.bounds.max.y { return 0 }

        var min_x = group_1.bounds.min.x
        var min_y = group_1.bounds.min.y
        var max_x = group_1.bounds.max.x
        var max_y = group_1.bounds.max.y
        
        if group_2.bounds.min.x > min_x { min_x = group_2.bounds.min.x }
        if group_2.bounds.min.y > min_y { min_y = group_2.bounds.min.y }
        
        if group_2.bounds.max.x < max_x { max_x = group_2.bounds.max.x }
        if group_2.bounds.max.y < max_y { max_y = group_2.bounds.max.y }
        
        // XXX could search a smaller space probably

        var overlap_pixel_amount = 0;
        
        for x in min_x ... max_x {
            for y in min_y ... max_y {
                let outlier_1_index = (y - group_1.bounds.min.y) * group_1.bounds.width + (x - group_1.bounds.min.x)
                let outlier_2_index = (y - group_2.bounds.min.y) * group_2.bounds.width + (x - group_2.bounds.min.x)
                if outlier_1_index > 0,
                   outlier_1_index < group_1.pixels.count,
                   group_1.pixels[outlier_1_index] != 0,
                   outlier_2_index > 0,
                   outlier_2_index < group_2.pixels.count,
                   group_2.pixels[outlier_2_index] != 0
                {
                    overlap_pixel_amount += 1
                }
            }
        }

        if overlap_pixel_amount > 0 {
            let avg_group_size = (Double(group_1.size) + Double(group_2.size)) / 2
            return Double(overlap_pixel_amount)/avg_group_size
        }
        
        return 0
    }


    
    // manual Decodable conformance so this class can be an actor
    // Encodable conformance is left to the non-actor class OutlierGroupEncodable
    enum CodingKeys: String, CodingKey {
        case name
        case size
        case bounds
        case brightness
        case lines
        case pixels
        case max_pixel_distance
        case surfaceAreaToSizeRatio
        case shouldPaint
        case frame_index
    }
    
    public init(from decoder: Decoder) throws {
	let data = try decoder.container(keyedBy: CodingKeys.self)

        self.name = try data.decode(String.self, forKey: .name)
        self.size = try data.decode(UInt.self, forKey: .size)
        self.bounds = try data.decode(BoundingBox.self, forKey: .bounds)
        self.brightness = try data.decode(UInt.self, forKey: .brightness)
        self.pixels = try data.decode(Array<UInt32>.self, forKey: .pixels)
        self.max_pixel_distance = try data.decode(UInt16.self, forKey: .max_pixel_distance)
        self.surfaceAreaToSizeRatio = try data.decode(Double.self, forKey: .surfaceAreaToSizeRatio)
        self.shouldPaint = try data.decode(PaintReason.self, forKey: .shouldPaint)
        self.frame_index = try data.decode(Int.self, forKey: .frame_index)

        if false {
            // XXX this calculates the lines instead of loading them
            // however it appears to be slower
            
            // the lines are calculated from saved data, not saved themselves
            let transform = HoughTransform(data_width: bounds.width,
                                           data_height: bounds.height,
                                           input_data: pixels,
                                           max_pixel_distance: max_pixel_distance)

            // we want all the lines, all of them.
            self.lines = transform.lines(min_count: 1)
        } else {
            self.lines = try data.decode(Array<Line>.self, forKey: .lines)
        }
    }

    public func encodable() -> OutlierGroupEncodable {
        return OutlierGroupEncodable(name: self.name,
                                     size: self.size,
                                     bounds: self.bounds,
                                     brightness: self.brightness,
                                     lines: self.lines,
                                     pixels: self.pixels,
                                     max_pixel_distance: self.max_pixel_distance,
                                     surfaceAreaToSizeRatio: self.surfaceAreaToSizeRatio,
                                     shouldPaint: self.shouldPaint,
                                     frame_index: self.frame_index)
    }
}

// this class is a property by property copy of an OutlierGroup,
// but not an actor so it's both encodable and usable by the view layer
public class OutlierGroupEncodable: Encodable {
    public let name: String
    public let size: UInt
    public let bounds: BoundingBox
    public let brightness: UInt   
    public let lines: [Line]
    public let pixels: [UInt32]   
    public let max_pixel_distance: UInt16
    public let surfaceAreaToSizeRatio: Double
    public var shouldPaint: PaintReason?
    public let frame_index: Int

    public init(name: String,
                size: UInt,
                bounds: BoundingBox,
                brightness: UInt,
                lines: [Line],
                pixels: [UInt32],
                max_pixel_distance: UInt16,
                surfaceAreaToSizeRatio: Double,
                shouldPaint: PaintReason?,
                frame_index: Int)
    {
        self.name = name
        self.size = size
        self.bounds = bounds
        self.brightness = brightness
        self.lines = lines
        self.pixels = pixels
        self.max_pixel_distance = max_pixel_distance
        self.surfaceAreaToSizeRatio = surfaceAreaToSizeRatio
        self.shouldPaint = shouldPaint
        self.frame_index = frame_index
    }
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
