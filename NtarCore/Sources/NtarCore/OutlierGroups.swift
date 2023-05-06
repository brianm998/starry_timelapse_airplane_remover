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
public class OutlierGroups {
    
    public let frame_index: Int
    public var groups: [String: OutlierGroup] // keyed by name

    public init(frame_index: Int,
                groups: [String: OutlierGroup])
    {
        self.frame_index = frame_index
        self.groups = groups
    }
    
    public func write(to dir: String) async throws {
        Log.d("loaded frame \(self.frame_index) with \(self.groups.count) outlier groups from binary file")

        let frame_dir = "\(dir)/\(frame_index)"
        
        try mkdir(frame_dir)

        for group in groups.values {
            try await group.writeToFile(in: frame_dir)
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
        self.groups = try await withLimitedThrowingTaskGroup(of: OutlierGroup.self) { taskGroup in
            var groups: [String: OutlierGroup] = [:]
            for file in data_bin_files {
                // load file into data
                try await taskGroup.addTask() {
                    let fileurl = NSURL(fileURLWithPath: "\(dir)/\(file)", isDirectory: false)

                    let (group_data, _) = try await URLSession.shared.data(for: URLRequest(url: fileurl as URL))
                    let fu: String = file
                    let fuck = String(fu.dropLast(OutlierGroup.data_bin_suffix.count+1))
                    //Log.d("trying to load group \(fuck)")
                    let group = OutlierGroup(withName: fuck,
                                             frameIndex: frame_index,
                                             with: group_data)
                    
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
                    return group
                }
            }
            try await taskGroup.forEach() { group in
                groups[group.name] = group
            }
            return groups
        }
    }
}

fileprivate let file_manager = FileManager.default
