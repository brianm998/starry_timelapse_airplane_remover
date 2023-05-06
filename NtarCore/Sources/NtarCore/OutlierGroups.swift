/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import Cocoa

// this class holds all the outlier groups for a frame

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

    public func write(to dir: String) async throws {
        if let groups = self.groups {

            Log.d("loaded frame \(self.frame_index) with \(self.groups?.count ?? -1) outlier groups from binary file")

            let frame_dir = "\(dir)/\(frame_index)"
            
            try mkdir(frame_dir)

            for group in groups.values {
                try await group.writeToFile(in: frame_dir)
            }
        } else {
            Log.w("cannot write with no groups")
        }
    }
    
    public init(at frame_index: Int,
                from dir: String) async throws
    {
        self.frame_index = frame_index

        var data_bin_files: [String] = []
        
        let contents = try file_manager.contentsOfDirectory(atPath: dir)
        contents.forEach { file in
            if file.hasSuffix(OutlierGroup.data_bin_suffix) {
                data_bin_files.append(file)
            }
        }
        var groups: [String: OutlierGroup] = [:]
        for file in data_bin_files {
            // load file into data
            let fileurl = NSURL(fileURLWithPath: "\(dir)/\(file)", isDirectory: false)

            let (group_data, _) = try await URLSession.shared.data(for: URLRequest(url: fileurl as URL))
            var fu: String = file
            let fuck = String(fu.dropLast(OutlierGroup.data_bin_suffix.count+1))
            //Log.d("trying to load group \(fuck)")
            let group = OutlierGroup(withName: fuck,
                                     frameIndex: frame_index,
                                     with: group_data)

            groups[fuck] = group
            
            let paint_filename = String(file.dropLast(OutlierGroup.data_bin_suffix.count) + OutlierGroup.paint_json_suffix)

            if file_manager.fileExists(atPath: "\(dir)/\(paint_filename)") {
                //Log.d("paint_filename \(paint_filename) exists for \(file)")
                // XXX load this shit up too

                let paintfileurl = NSURL(fileURLWithPath: "\(dir)/\(paint_filename)",
                                         isDirectory: false)

                let (paint_data, _) = try await URLSession.shared.data(for: URLRequest(url: paintfileurl as URL))
                
                // XXX this is json, decode it
                
                let decoder = JSONDecoder()
                decoder.nonConformingFloatDecodingStrategy = .convertFromString(
                  positiveInfinity: "inf",
                  negativeInfinity: "-inf",
                  nan: "nan")
                
                await group.shouldPaint(try decoder.decode(PaintReason.self, from: paint_data))

                //Log.d("loaded group.shouldPaint \(await group.shouldPaint) for \(fuck) \(fu)")
            } else {
                Log.d("no \(paint_filename) paint_filename for \(file)")
            }
        }
        self.groups = groups
    }
}

fileprivate let file_manager = FileManager.default
