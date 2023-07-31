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

    let height = IMAGE_HEIGHT!
    let width = IMAGE_WIDTH!
    
    // how many spatial groups in the X direction
    fileprivate var spatialXCount: Int

    // how many spatial groups in the Y direction
    fileprivate var spatialYCount: Int

    public let frameIndex: Int
    public var members: [String: OutlierGroup] // keyed by name

    // this is an x, y index of nearby groups
    private var spatialArr: [[[OutlierGroup]]]

    private func index(for group: OutlierGroup) -> (Int, Int) {
        let centerCoord = group.bounds.center

        return (Int(Double(centerCoord.x) / width) % spatialXCount,
                Int(Double(centerCoord.y) / height) % spatialYCount)
    }

    public func groups(nearby group: OutlierGroup) -> [OutlierGroup] {
        var ret: [OutlierGroup] = []

        let (XIndex, YIndex) = self.index(for: group)

        var XStartIndex = XIndex - 1
        var XEndIndex = XIndex + 1
        
        var YStartIndex = YIndex - 1
        var YEndIndex = YIndex + 1

        if XStartIndex < 0 { XStartIndex = 0 }
        if YStartIndex < 0 { YStartIndex = 0 }

        if XEndIndex >= self.spatialArr.count { XEndIndex = self.spatialArr.count - 1 }
        if YEndIndex >= self.spatialArr[0].count { YEndIndex = self.spatialArr[0].count - 1 }

        for x in XStartIndex...XEndIndex {
            for y in YStartIndex...YEndIndex {
                ret.append(contentsOf: self.spatialArr[x][y])
            }
        }

        return ret
    }
    /*

     need spatial 2d array of members
     function to assign x,y indices to any OutlierGroup
     function to return only indices within some range
     
     */
    
    public init(frameIndex: Int,
                members: [String: OutlierGroup])
    {
        self.frameIndex = frameIndex
        self.members = members
        self.spatialXCount = Int(width/OutlierGroup.maxNearbyGroupDistance)
        self.spatialYCount = Int(height/OutlierGroup.maxNearbyGroupDistance)
        self.spatialArr = [[[OutlierGroup]]](repeating: [[OutlierGroup]](repeating: [], count: spatialYCount), count: spatialXCount)
        // configure 2d spatial map here
        for group in members.values {
            let (XIndex, YIndex) = self.index(for: group)
            spatialArr[XIndex][YIndex].append(group)
        }
        Log.i("spatialXCount \(self.spatialXCount) spatialYCount \(self.spatialYCount) width \(width) height \(height) OutlierGroup.maxNearbyGroupDistance \(OutlierGroup.maxNearbyGroupDistance)")
    }
    
    public func write(to dir: String) async throws {
        Log.d("writing  \(self.members.count) outlier groups for frame \(self.frameIndex) to binary file")
        let frameDir = "\(dir)/\(frameIndex)"
        
        try mkdir(frameDir)

        for group in members.values {
            try await group.writeToFile(in: frameDir)
        }
        Log.d("wrote  \(self.members.count) outlier groups for frame \(self.frameIndex) to binary file")
    }
    
    public init(at frameIndex: Int,
                from dir: String) async throws
    {
        self.frameIndex = frameIndex

        var dataBinFiles: [String] = []
        
        let contents = try fileManager.contentsOfDirectory(atPath: dir)
        contents.forEach { file in
            if file.hasSuffix(OutlierGroup.dataBinSuffix) {
                dataBinFiles.append(file)
            }
        }
        self.members = try await withLimitedThrowingTaskGroup(of: OutlierGroup.self) { taskGroup in
          var groups: [String: OutlierGroup] = [:]
            for file in dataBinFiles {
                // load file into data
                try await taskGroup.addTask() {
                    let fileurl = NSURL(fileURLWithPath: "\(dir)/\(file)", isDirectory: false)
 
                    let (groupData, _) = try await URLSession.shared.data(for: URLRequest(url: fileurl as URL))
                    let fu: String = file
                    let fuck = String(fu.dropLast(OutlierGroup.dataBinSuffix.count+1))
                    //Log.d("trying to load group \(fuck)")
                    let group = OutlierGroup(withName: fuck,
                                             frameIndex: frameIndex,
                                             with:groupData)
                    
                    let paintFilename = String(file.dropLast(OutlierGroup.dataBinSuffix.count) + OutlierGroup.paintJsonSuffix)

                    if fileManager.fileExists(atPath: "\(dir)/\(paintFilename)") {
                        //Log.d("paintFilename \(paintFilename) exists for \(file) \(fuck)")
                        // XXX load this shit up too

                        let paintfileurl = NSURL(fileURLWithPath: "\(dir)/\(paintFilename)",
                                                 isDirectory: false)

                        let (paintData, _) = try await URLSession.shared.data(for: URLRequest(url: paintfileurl as URL))
                        
                        // XXX this is json, decode it
                        
                        let decoder = JSONDecoder()
                        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
                          positiveInfinity: "inf",
                          negativeInfinity: "-inf",
                          nan: "nan")
                        
                        await group.shouldPaint(try decoder.decode(PaintReason.self, from: paintData))

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
        self.spatialXCount = Int(width/OutlierGroup.maxNearbyGroupDistance)
        self.spatialYCount = Int(height/OutlierGroup.maxNearbyGroupDistance)
        self.spatialArr = [[[OutlierGroup]]](repeating: [[OutlierGroup]](repeating: [], count: spatialYCount), count: spatialXCount)
        // configure 2d spatial map here
        for group in members.values {
            let (XIndex, YIndex) = self.index(for: group)
            spatialArr[XIndex][YIndex].append(group)
        }
        Log.i("spatialXCount \(self.spatialXCount) spatialYCount \(self.spatialYCount)")
    }
}

fileprivate let fileManager = FileManager.default

