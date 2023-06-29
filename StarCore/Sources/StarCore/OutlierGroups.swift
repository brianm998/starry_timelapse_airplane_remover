/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import Cocoa

// this class holds all the outlier groups for a frame

public class OutlierGroups {
    
    public let frameIndex: Int
    public var members: [String: OutlierGroup] // keyed by name

    public init(frameIndex: Int,
                members: [String: OutlierGroup])
    {
        self.frameIndex = frameIndex
        self.members = members
    }
    
    public func write(to dir: String) async throws {
        Log.d("loaded frame \(self.frameIndex) with \(self.members.count) outlier groups from binary file")

        let frame_dir = "\(dir)/\(frameIndex)"
        
        try mkdir(frame_dir)

        for group in members.values {
            try await group.writeToFile(in: frame_dir)
        }
    }
    
    public init(at frameIndex: Int,
                from dir: String) async throws
    {
        self.frameIndex = frameIndex

        var data_bin_files: [String] = []
        
        let contents = try file_manager.contentsOfDirectory(atPath: dir)
        contents.forEach { file in
            if file.hasSuffix(OutlierGroup.data_bin_suffix) {
                data_bin_files.append(file)
            }
        }
        self.members = try await withLimitedThrowingTaskGroup(of: OutlierGroup.self) { taskGroup in
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
                                             frameIndex: frameIndex,
                                             with: group_data)
                    
                    let paint_filename = String(file.dropLast(OutlierGroup.data_bin_suffix.count) + OutlierGroup.paint_json_suffix)

                    if file_manager.fileExists(atPath: "\(dir)/\(paint_filename)") {
                        //Log.d("paint_filename \(paint_filename) exists for \(file) \(fuck)")
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

                        //Log.d("loaded group.shouldPaint \(group.shouldPaint) for \(group.name) \(fuck)")
                    }

                    /*
                     XXX this causes a failure on startup when there is no classification
                     for this outlier group yet
                     the crash is because of no loaded frame yet
                     else {
                        // classify it
                        
                        if let currentClassifier = currentClassifier {
                            Log.i("no classification for group \(group.name), applying the default classifier now")
                            let classificationScore = await currentClassifier.classification(of: group)
                            await group.shouldPaint(.fromClassifier(classificationScore))
                        }
                    }
                     */
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

