/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import Cocoa
import logging

// holds all the outlier groups for a frame
// including the dustbin

public actor OutlierGroups {

    let height = Int(IMAGE_HEIGHT!)
    let width = Int(IMAGE_WIDTH!)
    
    public let frameIndex: Int
    // outliers which have been selected through the first round as looking acceptable
    public var members: [UInt16: OutlierGroup] // keyed by id

    // outliers which have failed the first round, but are here if that was wrong
    public var dustbin: [UInt16: OutlierGroup] // keyed by id

    public func add(_ member: OutlierGroup) {
        members[member.id] = member
    }

    public func add(_ newMembers: [OutlierGroup]) {
        for member in newMembers {
            self.members[member.id] = member
            self.dustbin.removeValue(forKey: member.id)
        }
    }

    public func get(with id: UInt16) -> OutlierGroup? { members[id] }
    
    public func dumpInDustbin(_ member: OutlierGroup) {
        dustbin[member.id] = member
    }

    public func dumpInDustbin(_ newMembers: [OutlierGroup]) {
        for member in newMembers {
            self.dustbin[member.id] = member
            self.members.removeValue(forKey: member.id)
        }
    }

    public func promoteFromDustbin(_ member: OutlierGroup) {
        members[member.id] = member
        dustbin.removeValue(forKey: member.id)
    }

    public func asyncHash(into hasher: inout Hasher) async {
        for (_, member) in members {
            hasher.combine(member)
        }
        for (_, member) in dustbin {
            hasher.combine(member)
        }
    }

    public func getMembers() -> [UInt16: OutlierGroup] { members }

    public func getDustbin() -> [UInt16: OutlierGroup] { dustbin }

    // image data from an image with non zero pixels set with an outlier id
    public var outlierImageData: [UInt16] = [] // outlier ids for frame, row major indexed
    public var outlierYAxisImageData: [UInt8]? // y axis of the outlierImage data

    public func outlierImageDataFunc() -> [UInt16] { // XXX rename this
        if outlierImageData.count == 0 {
            calculateOutlierImageData()
        }
        return outlierImageData
    } 
    
    public func set(outlierImageData: [UInt16]) {
        self.outlierImageData = outlierImageData
    }

    public func set(outlierYAxisImageData: [UInt8]) {
        self.outlierYAxisImageData = outlierYAxisImageData
    }

    public func calculateOutlierImageData() {
        self.outlierImageData = [UInt16](repeating: 0, count: width*height)
        for (id, group) in members {
            for pixel in group.pixelSet {
                let index = pixel.y*width+pixel.x
                outlierImageData[index] = id
            }
        }
        for (id, group) in dustbin {
            for pixel in group.pixelSet {
                let index = pixel.y*width+pixel.x
                outlierImageData[index] = id
            }
        }
    }
    
    public init(frameIndex: Int,
                members: [UInt16: OutlierGroup] = [:],
                dustbin: [UInt16: OutlierGroup] = [:])
    {
        self.frameIndex = frameIndex
        self.members = members
        self.dustbin = dustbin
        self.outlierImageData = [UInt16](repeating: 0, count: 0) // XXX ???
        self.outlierYAxisImageData = [UInt8](repeating: 0, count: 0) // XXX
    }

    public static func loadOutlierGroupPaintData(from filename: String) async throws -> [UInt16:PaintReason]? {
        if FileManager.default.fileExists(atPath: filename) {

            let decoder = JSONDecoder()
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(
              positiveInfinity: "inf",
              negativeInfinity: "-inf",
              nan: "nan")

            // look for OutlierGroupPaintData.json

            let paintfileurl = NSURL(fileURLWithPath: filename,
                                     isDirectory: false)

            let (paintData, _) = try await URLSession.shared.data(for: URLRequest(url: paintfileurl as URL))

            return try decoder.decode([UInt16:PaintReason].self, from: paintData)
        }
        return nil
    }

    public static let outlierGroupPaintJsonFilename = "OutlierGroupPaintData.json"

    // uses the newer binary blob format
    public init(at frameIndex: Int,
                fromOutlierDir outlierDir: String) async throws
    {
        self.frameIndex = frameIndex
        let blobBinaryLoader = BlobBinaryLoader()
        let blobs = try await blobBinaryLoader.load(from: outlierDir, with: frameIndex)
        let dustbinBlobs = try? await blobBinaryLoader.loadDustbin(from: outlierDir, with: frameIndex)
        let outlierGroupPaintDataFilename = "\(outlierDir)/\(OutlierGroups.outlierGroupPaintJsonFilename)"
        let outlierGroupPaintData = try await OutlierGroups.loadOutlierGroupPaintData(from: outlierGroupPaintDataFilename)
        self.members = [:]
        self.dustbin = [:]
        
        for (id, blob) in blobs {
            let outlierGroup = await blob.outlierGroup(at: frameIndex)
            if let outlierGroupPaintData,
               let shouldPaint = outlierGroupPaintData[outlierGroup.id]
            {
                await outlierGroup.shouldPaint(shouldPaint)
            }
            self.members[id] = outlierGroup
        }

        if let dustbinBlobs {
            for (id, blob) in dustbinBlobs {
                let outlierGroup = await blob.outlierGroup(at: frameIndex)
                self.dustbin[id] = outlierGroup
            }
        }
    }

    // returns outlier groups from this frame that overlap with the given group from another frame
    public func groups(overlapping group: OutlierGroup) async -> [OutlierGroup] {
        if outlierImageData.count == 0 { calculateOutlierImageData() }
        
        var ret: [UInt16: OutlierGroup] = [:]

        for pixel in group.pixelSet {
            let index = pixel.y * width + pixel.x
            let outlierId = outlierImageData[index]
            if outlierId != 0 {
                ret[outlierId] = members[outlierId]
            }
        }

        return Array(ret.values)
    }

    public func groups(nearby group: OutlierGroup,
                       within searchDistance: Double) -> [OutlierGroup]
    {
        if outlierImageData.count == 0 { calculateOutlierImageData() }

        var ret: [UInt16: OutlierGroup] = [:]

        let intSearchDistance = Int(searchDistance)
        
        var minX = group.bounds.min.x - intSearchDistance
        var minY = group.bounds.min.y - intSearchDistance
        var maxX = group.bounds.max.x + intSearchDistance
        var maxY = group.bounds.max.y + intSearchDistance

        if minX < 0 { minX = 0 }
        if minY < 0 { minY = 0 }
        if maxX >= width { maxX = width - 1 }
        if maxY >= height { maxY = height - 1 }

        for y in minY...maxY {
//            if let outlierYAxisImageData,
//               outlierYAxisImageData[y] == 0 { continue }
            
            for x in minX...maxX {
                let index = y * width + x
                let outlierId = outlierImageData[index]
                if outlierId != 0,
                   outlierId != group.id,
                   !ret.keys.contains(outlierId),
                   let outlier = members[outlierId]
                {
                    ret[outlierId] = outlier
                }
            }
        }

        return Array(ret.values)
    }

    public func applyRazor(in boundingBox: BoundingBox, includingDustbin: Bool) async -> Bool {
        var newBlobPixels: Set<SortablePixel> = []
        var newOutlierGroups: [OutlierGroup] = []
        var maxKey: UInt16 = 0
        // first apply razor to members
        for (key, group) in members {
            if key > maxKey { maxKey = key }
            if let overlap = boundingBox.overlap(with: group.bounds) {
                let blobToSlice = await group.blob()
                let newPixels = await blobToSlice.slice(with: overlap)
                newBlobPixels.formUnion(newPixels)
                members.removeValue(forKey: key)
                let newOutlierGroup = await blobToSlice.outlierGroup(at: frameIndex)
                newOutlierGroups.append(newOutlierGroup)
            }
        }

        // then apply it to the dustbin too, if requested
        if includingDustbin {
            for (key, group) in dustbin {
                if key > maxKey { maxKey = key }
                if let overlap = boundingBox.overlap(with: group.bounds) {
                    let blobToSlice = await group.blob()
                    let newPixels = await blobToSlice.slice(with: overlap)
                    newBlobPixels.formUnion(newPixels)
                    dustbin.removeValue(forKey: key)
                    let newOutlierGroup = await blobToSlice.outlierGroup(at: frameIndex)
                    newOutlierGroups.append(newOutlierGroup)
                }
            }
        }

        maxKey += 1
        for newOutlier in newOutlierGroups {
            members[newOutlier.id] = newOutlier
        }
        if newBlobPixels.count > 0 {
            let slicedOutlier = await Blob(newBlobPixels, id: maxKey, frameIndex: frameIndex).outlierGroup(at: frameIndex)
            members[slicedOutlier.id] = slicedOutlier
            return true
        } else {
            return false
        }
    }

    public func promoteDust(in gestureBounds: BoundingBox) -> [OutlierGroup] {
        var ret: [OutlierGroup] = []
        for (key, group) in dustbin {
            if gestureBounds.contains(group.bounds) {
                dustbin.removeValue(forKey: key)
                ret.append(group)
                members[key] = group
            }
        }
        return ret
    }
    
    public func deleteOutliers(in gestureBounds: BoundingBox) {
        for (key, group) in members {
            if gestureBounds.contains(group.bounds) {
                members.removeValue(forKey: key)
            }
        }
    }

    // hopefully faster version to just write out what we need
    public func writeOutliersBinary(to dirname: String) async throws {

        mkdir(dirname)

        // save members
        await self.writeBinary(outlierMap: self.members,
                         to: "\(dirname)/\(BlobBinarySaver.outlierBinaryFilename)")

        // save dustbin
        await self.writeBinary(outlierMap: self.dustbin,
                         to: "\(dirname)/\(BlobBinarySaver.dustbinBinaryFilename)")
    }

    private func writeBinary(outlierMap: [UInt16: OutlierGroup], to filename: String) async {
        var blobMap: [UInt16: Blob] = [:]

        for outlier in outlierMap.values {
            let blob = await outlier.blob()
            blobMap[blob.id] = blob
        }

        await BlobBinarySaver(blobMap: blobMap).save(to: filename)
    }
    
    // only writes the paint reasons now, outlier image is written elsewhere
    public func write(to dir: String) async throws {
        let frameDir = "\(dir)/\(frameIndex)"
        let outlierGroupPaintDataFilename = "\(frameDir)/OutlierGroupPaintData.json"
        Log.d("frame \(frameIndex) writing outlier group paint data to \(outlierGroupPaintDataFilename)")
        
        mkdir(frameDir)

        // data to save for paint reasons for all outliers in this frame
        var outlierGroupPaintData: [UInt16:PaintReason] = [:]

        Log.d("frame \(frameIndex) has \(members.count) members")
        
        for group in members.values {
            // collate paint reasons for each group
            if let shouldPaint = await group.shouldPaint() {
                //Log.d("frame \(frameIndex) group \(group.id) shouldPaint \(shouldPaint)")
                outlierGroupPaintData[group.id] = shouldPaint
            }
        }

        // write outlier paint reason json here 
        

        let encoder = JSONEncoder()
//            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
          positiveInfinity: "inf",
          negativeInfinity: "-inf",
          nan: "nan")

        if FileManager.default.fileExists(atPath: outlierGroupPaintDataFilename) {
            try FileManager.default.removeItem(atPath: outlierGroupPaintDataFilename)
        }
        let contents = try encoder.encode(outlierGroupPaintData)
        FileManager.default.createFile(atPath: outlierGroupPaintDataFilename,
                               contents: contents,
                               attributes: nil)
        
        Log.d("frame \(frameIndex) wrote outlier group paint data to \(outlierGroupPaintDataFilename): \(contents)")
    }

    // outputs an 8 bit monochrome image that contains a white
    // value for every pixel that was determined to be an outlier
    public func validationImage() async -> PixelatedImage {
        PixelatedImage(width: Int(IMAGE_WIDTH!),
                       height: Int(IMAGE_HEIGHT!),
                       grayscale8BitImageData: await self.validationImageData())
    }
    
    // outputs image data for an 8 bit monochrome image that contains a white
    // value for every pixel that was determined to be an outlier
    public func validationImageData() async -> [UInt8] {
        // create base image data array
        var baseData = [UInt8](repeating: 0, count: Int(IMAGE_WIDTH!*IMAGE_HEIGHT!))

        // write into this array from the pixels in this group
        for (_, group) in self.members {
            if let shouldPaint = await group.shouldPaint(),
               shouldPaint.willPaint
            {
                /*
                 // paint the group bounds for help debugging
                 
                 for x in group.bounds.min.x...group.bounds.max.x {
                 baseData[group.bounds.min.y*Int(IMAGE_WIDTH!)+x] = 0x8F
                 baseData[group.bounds.max.y*Int(IMAGE_WIDTH!)+x] = 0x8F
                 }

                 for y in group.bounds.min.y...group.bounds.max.y {
                 baseData[y*Int(IMAGE_WIDTH!)+group.bounds.min.x] = 0x8F
                 baseData[y*Int(IMAGE_WIDTH!)+group.bounds.max.x] = 0x8F
                 }
                 */
                //Log.d("group \(group.id) has bounds \(group.bounds)")

                for x in 0 ..< group.bounds.width {
                    for y in 0 ..< group.bounds.height {
                        if group.pixels[y*group.bounds.width+x] != 0 {
                            let imageXBase = x + group.bounds.min.x
                            let imageYBase = y + group.bounds.min.y

                            // add this padding for older data which appears
                            // to have one pixel gaps for some unknown reason 
                            let padding = 1
                            
                            for imageX in imageXBase - padding ... imageXBase + padding {
                                if imageX < 0 { continue }
                                if imageX >= Int(IMAGE_WIDTH!) { continue }
                                for imageY in imageYBase - padding ... imageYBase + padding {
                                    if imageY < 0 { continue }
                                    if imageY >= Int(IMAGE_HEIGHT!) { continue }
                                    baseData[imageY*Int(IMAGE_WIDTH!)+imageX] = 0xFF
                                }
                            }
                        }
                    }
                }
            }
        }
        return baseData
    }
}


