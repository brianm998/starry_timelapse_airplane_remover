/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession, URLRequest live here on Linux
#endif
import logging

// holds all the outlier groups for a frame
// including the trash

public actor OutlierGroups {

    public let config: Config
    
    public let frameIndex: Int
    // outliers which have been selected through the first round as looking acceptable
    public var members: [UInt16: OutlierGroup] // keyed by id

    // outliers which have failed the first round, but are here if that was wrong
    public var trash: [UInt16: OutlierGroup] // keyed by id

    public func add(_ member: OutlierGroup) {
        members[member.id] = member
    }

    public func add(_ newMembers: [OutlierGroup]) {
        for member in newMembers {
            self.members[member.id] = member
            self.trash.removeValue(forKey: member.id)
        }
    }

    public var maxID: UInt16 {
        var ret: UInt16 = 0
        for (id, _) in members {
            if id > ret { ret = id }
        }
        return ret
    }
    
    // adds blobs as outlier groups within the bounds, and slices out
    // any pixels from existing outlier groups within the bounds
    public func add(blobs: [Int32:Blob], within bounds: BoundingBox) async {
        Log.i("frame \(frameIndex) adding \(blobs.count) blobs within bounds \(bounds)")
        for (id, _) in blobs.enumerated() {
            Log.i("frame \(frameIndex) adding blob id \(id)")
        }
        var maxID: UInt16 = 0

        var newMembers: [UInt16: OutlierGroup] = [:]
        var newTrash: [UInt16: OutlierGroup] = [:]

        // iterate through all existing outlier groups, 
        //  if they're inside the bounding box, discard them
        //  if they're overlapping the bounding box, remove offending pixels
        //  if they're outside the bounding box, keep them
        for (id, _) in members {
            if id > maxID { maxID = id }
        }
        Log.d("frame \(frameIndex) have maxID \(maxID)")
        for (id, group) in members {
            if let overlap = group.bounds.overlap(with: bounds) {
                if bounds.contains(group.bounds) {
                    // this outlier group is entirely within the bounds, dump it
                    Log.i("dumping group of size \(group.size) becasue it is entirely within bounds")
                } else {
                    Log.i("splitting group of size \(group.size) becasue it overlaps with bounds")
                    let blob = await group.blob()
                    await blob.removePixels(within: overlap)
                    newMembers[id] = await blob.outlierGroup(at: frameIndex, withId: id,
                                                          imageWidth: Double(config.imageWidth),
                                                          imageHeight: Double(config.imageHeight))
                }
            } else {
                // this outlier doesn't overlap at all, keep it
                newMembers[id] = group
            }
        }

        for (id, group) in trash {
            if id > maxID { maxID = id }

            if let overlap = group.bounds.overlap(with: bounds) {
                if bounds.contains(group.bounds) {
                    // this outlier group is entirely within the bounds, dump it
                } else {
                    let blob = await group.blob()
                    await blob.removePixels(within: overlap)
                    newTrash[id] = await blob.outlierGroup(at: frameIndex, withId: id,
                                                          imageWidth: Double(config.imageWidth),
                                                          imageHeight: Double(config.imageHeight))
                }
            } else {
                // this outlier doesn't overlap at all, keep it
                newTrash[id] = group
            }
        }

        //maxID += 1
        
        // add the new blobs as outlier groups
        for blob in blobs.values {
            maxID += 1
            let id = maxID
            newMembers[id] = await blob.outlierGroup(at: frameIndex, withId: id,
                                                          imageWidth: Double(config.imageWidth),
                                                          imageHeight: Double(config.imageHeight))
        }
        
        self.members = newMembers
        self.trash = newTrash
        Log.i("frame \(frameIndex) after adding \(blobs.count) blobs we have \(members.count) blobs")
    }
    
    public func get(with id: UInt16) -> OutlierGroup? { members[id] }
    
    public func dumpInTrash(_ member: OutlierGroup) {
        trash[member.id] = member
    }

    public func dumpInTrash(_ newMembers: [OutlierGroup]) {
        for member in newMembers {
            self.trash[member.id] = member
            self.members.removeValue(forKey: member.id)
        }
    }

    public func promoteFromTrash(_ member: OutlierGroup) {
        members[member.id] = member
        trash.removeValue(forKey: member.id)
    }

    public func asyncHash(into hasher: inout Hasher) async {
        for (_, member) in members {
            hasher.combine(member)
        }
        for (_, member) in trash {
            hasher.combine(member)
        }
    }

    public func getMembers() -> [UInt16: OutlierGroup] { members }

    public func getTrash() -> [UInt16: OutlierGroup] { trash }

    // image data from an image with non zero pixels set with an outlier id
    public var outlierImageData: [UInt16] = [] // outlier ids for frame, row major indexed

    public func outlierImageDataFunc() -> [UInt16] { // XXX rename this
        if outlierImageData.count == 0 {
            calculateOutlierImageData()
        }
        return outlierImageData
    }

    /// Drop the cached outlier-id image.
    ///
    /// This is a cache, not state: `outlierImageDataFunc()` rebuilds it from `members`
    /// and `trash`, which are untouched here, so dropping it loses nothing. Callers that
    /// already hold the array keep their own copy — Swift arrays are values, so this
    /// cannot pull the ground out from under a reader mid-use.
    ///
    /// Worth dropping because at 42MP it is `imageWidth * imageHeight * 2` = ~80MB per
    /// frame, retained for the life of the frame, and the MemoryMonitor never hears
    /// about it.
    public func releaseOutlierImageData() {
        guard !outlierImageData.isEmpty else { return }
        outlierImageData = []
    }
    
    public func set(outlierImageData: [UInt16]) {
        self.outlierImageData = outlierImageData
    }

    public func calculateOutlierImageData() {
        self.outlierImageData = [UInt16](repeating: 0, count: config.imageWidth*config.imageHeight)
        for (id, group) in members {
            for pixel in group.pixelSet {
                let index = pixel.y*config.imageWidth+pixel.x
                if index >= 0,
                   index < outlierImageData.count
                {
                    outlierImageData[index] = id
                }
            }
        }
        for (id, group) in trash {
            for pixel in group.pixelSet {
                let index = pixel.y*config.imageWidth+pixel.x
                if index >= 0,
                   index < outlierImageData.count
                {
                    outlierImageData[index] = id
                }
            }
        }
    }
    
    public init(
      frameIndex: Int,
      members: [UInt16: OutlierGroup] = [:],
      trash: [UInt16: OutlierGroup] = [:],
      config: Config
    ) {
        self.config = config
        self.frameIndex = frameIndex
        self.members = members
        self.trash = trash
        self.outlierImageData = []
    }

    public static func loadOutlierGroupPaintData(from filename: String) async throws -> [UInt16:RemoveReason]? {
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

            return try decoder.decode([UInt16:RemoveReason].self, from: paintData)
        }
        return nil
    }

    public static let outlierGroupPaintJsonFilename = "OutlierGroupPaintData.json"

    public func clear() {
        self.members = [:]
        self.trash = [:]
    }

    // uses the newer binary blob format
    public init(
      at frameIndex: Int,
      fromOutlierDir outlierDir: String,
      config: Config
    ) async throws {
        self.frameIndex = frameIndex
        self.config = config
        let blobBinaryLoader = BlobBinaryLoader()
        let blobs = try await blobBinaryLoader.load(from: outlierDir, with: frameIndex)
        Log.i("frame \(frameIndex) loaded \(blobs.count) blobs")
        let trashBlobs = try? await blobBinaryLoader.loadTrash(from: outlierDir, with: frameIndex)
        let outlierGroupPaintDataFilename = "\(outlierDir)/\(OutlierGroups.outlierGroupPaintJsonFilename)"
        let outlierGroupPaintData = try await OutlierGroups.loadOutlierGroupPaintData(from: outlierGroupPaintDataFilename)
        self.members = [:]
        self.trash = [:]
        
        for (_, blob) in blobs {
            let outlierGroup = await blob.outlierGroup(at: frameIndex,
                                                       imageWidth: Double(config.imageWidth),
                                                       imageHeight: Double(config.imageHeight))
            if let outlierGroupPaintData,
               let shouldRemove = outlierGroupPaintData[outlierGroup.id]
            {
                _ = await outlierGroup.shouldRemove(shouldRemove)
            }
            self.members[outlierGroup.id] = outlierGroup
        }

        if let trashBlobs {
            for (_, blob) in trashBlobs {
                let outlierGroup = await blob.outlierGroup(at: frameIndex,
                                                       imageWidth: Double(config.imageWidth),
                                                       imageHeight: Double(config.imageHeight))
                self.trash[outlierGroup.id] = outlierGroup
            }
        }
    }

    // returns outlier groups from this frame that overlap with the given group from another frame
    public func groups(overlapping group: OutlierGroup) async -> [OutlierGroup] {
        if outlierImageData.count == 0 { calculateOutlierImageData() }
        
        var ret: [UInt16: OutlierGroup] = [:]

        for pixel in group.pixelSet {
            let index = pixel.y * config.imageWidth + pixel.x
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
        if maxX >= config.imageWidth { maxX = config.imageWidth - 1 }
        if maxY >= config.imageHeight { maxY = config.imageHeight - 1 }

        if minY <= maxY {
            for y in minY...maxY {
                for x in minX...maxX {
                    let index = y * config.imageWidth + x
                    let outlierId = outlierImageData[index]
                    if outlierId != 0,
                       outlierId != group.id,
                       !ret.keys.contains(outlierId),
                       let outlier = members[outlierId],
                       group.bounds.centerDistance(to: outlier.bounds) < searchDistance
                    {
                        ret[outlierId] = outlier
                    }
                }
            }
        }

        return Array(ret.values)
    }

    public func applyRazor(in boundingBox: BoundingBox, includingTrash: Bool) async -> Bool {
        var newBlobPixels: Set<SortablePixel> = []
        var newOutlierGroups: [OutlierGroup] = []
        var maxKey: UInt16 = 1
        // first apply razor to members
        for (key, group) in members {
            if key > maxKey { maxKey = key }
            if let overlap = boundingBox.overlap(with: group.bounds) {
                let blobToSlice = await group.blob()
                let newPixels = await blobToSlice.slice(with: overlap)
                newBlobPixels.formUnion(newPixels)
                members.removeValue(forKey: key)
                let newOutlierGroup = await blobToSlice.outlierGroup(at: frameIndex,
                                                       imageWidth: Double(config.imageWidth),
                                                       imageHeight: Double(config.imageHeight))
                newOutlierGroups.append(newOutlierGroup)
            }
        }

        // then apply it to the trash too, if requested
        if includingTrash {
            for (key, group) in trash {
                if key > maxKey { maxKey = key }
                if let overlap = boundingBox.overlap(with: group.bounds) {
                    let blobToSlice = await group.blob()
                    let newPixels = await blobToSlice.slice(with: overlap)
                    newBlobPixels.formUnion(newPixels)
                    trash.removeValue(forKey: key)
                    let newOutlierGroup = await blobToSlice.outlierGroup(at: frameIndex,
                                                       imageWidth: Double(config.imageWidth),
                                                       imageHeight: Double(config.imageHeight))
                    newOutlierGroups.append(newOutlierGroup)
                }
            }
        }

        maxKey += 1
        for newOutlier in newOutlierGroups {
            members[newOutlier.id] = newOutlier
        }
        if newBlobPixels.count > 0 {
            let slicedOutlier = await Blob(newBlobPixels, id: Int32(maxKey), frameIndex: frameIndex).outlierGroup(at: frameIndex,
                                                       imageWidth: Double(config.imageWidth),
                                                       imageHeight: Double(config.imageHeight))
            members[slicedOutlier.id] = slicedOutlier
            return true
        } else {
            return false
        }
    }

    public func promoteDust(in gestureBounds: BoundingBox) -> [OutlierGroup] {
        var ret: [OutlierGroup] = []
        for (key, group) in trash {
            if gestureBounds.contains(group.bounds) {
                trash.removeValue(forKey: key)
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
        Log.d("frame \(frameIndex) writing \(self.members.count) outliers to file")
        mkdir(dirname)

        // save members
        await self.writeBinary(
          outlierMap: self.members,
          to: "\(dirname)/\(BlobBinarySaver.outlierBinaryFilename)"
        )

        // save trash
        await self.writeBinary(
          outlierMap: self.trash,
          to: "\(dirname)/\(BlobBinarySaver.trashBinaryFilename)"
        )
    }

    // removes outliers.bin and dust.bin from outliers dir for this frame
    /// Remove a frame's stored outlier groups, and its trash, from disk.
    ///
    /// `static` because deleting them cannot be allowed to depend on having loaded them.
    /// This was an instance method, reached through `outlierGroups?` — so a frame whose
    /// outliers had never been read deleted nothing at all and kept its file, which the
    /// next run then loaded and reused.  Nothing in here ever touched `self`.
    public static func removeOutliersBinary(from dirname: String) throws {

        let outlierBinaryFilename = "\(dirname)/\(BlobBinarySaver.outlierBinaryFilename)"
        if FileManager.default.fileExists(atPath: outlierBinaryFilename) {
            try FileManager.default.removeItem(atPath: outlierBinaryFilename)
        }

        let trashFilename = "\(dirname)/\(BlobBinarySaver.trashBinaryFilename)"
        if FileManager.default.fileExists(atPath: trashFilename) {
            try FileManager.default.removeItem(atPath: trashFilename)
        }
    }

    private func writeBinary(outlierMap: [UInt16: OutlierGroup], to filename: String) async {
        Log.i("frame \(frameIndex) writing \(outlierMap.count) outliers to file");
        var blobMap: [Int32: Blob] = [:]

        for outlier in outlierMap.values {
            let blob = await outlier.blob()
            if blobMap[blob.id] != nil {
                Log.e("frame \(frameIndex) found duplicate blobId \(blob.id)")
            }
            blobMap[blob.id] = blob
        }
        Log.i("frame \(frameIndex) writing \(blobMap.count) outliers to file");

        await BlobBinarySaver(blobMap: blobMap).save(to: filename)
    }
    
    // only writes the paint reasons now, outlier image is written elsewhere
    public func write(to dir: String) async throws {
        let frameDir = "\(dir)/\(frameIndex)"
        let outlierGroupPaintDataFilename = "\(frameDir)/OutlierGroupPaintData.json"
        Log.d("frame \(frameIndex) writing outlier group paint data to \(outlierGroupPaintDataFilename)")
        
        mkdir(frameDir)

        // data to save for paint reasons for all outliers in this frame
        var outlierGroupPaintData: [UInt16:RemoveReason] = [:]

        Log.d("frame \(frameIndex) has \(members.count) members")
        
        for group in members.values {
            // collate paint reasons for each group
            if let shouldRemove = await group.shouldRemove() {
                //Log.d("frame \(frameIndex) group \(group.id) shouldRemove \(shouldRemove)")
                outlierGroupPaintData[group.id] = shouldRemove
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
        _ = FileManager.default.createFile(
          atPath: outlierGroupPaintDataFilename,
          contents: contents,
          attributes: nil
        )
        
        Log.d("frame \(frameIndex) wrote outlier group paint data to \(outlierGroupPaintDataFilename): \(contents)")
    }

    // outputs an 8 bit monochrome image that contains a white
    // value for every pixel that was determined to be an outlier
    public func validationImage() async -> PixelatedImage? {
        await self.validationImageData().image
    }
    
    // outputs image data for an 8 bit monochrome image that contains a white
    // value for every pixel that was determined to be an outlier
    public func validationImageData() async -> ImageBuffer<UInt8> {
        // create base image data array
        var baseData = ImageBuffer<UInt8>(
          width: Int(config.imageWidth),
          height: Int(config.imageHeight)
        )

        // write into this array from the pixels in this group
        for (_, group) in self.members {
            if let shouldRemove = await group.shouldRemove(),
               shouldRemove.willRemove
            {
                /*
                 // paint the group bounds for help debugging
                 
                 for x in group.bounds.min.x...group.bounds.max.x {
                 baseData[group.bounds.min.y*config.imageWidth+x] = 0x8F
                 baseData[group.bounds.max.y*config.imageWidth+x] = 0x8F
                 }

                 for y in group.bounds.min.y...group.bounds.max.y {
                 baseData[y*config.imageWidth+group.bounds.min.x] = 0x8F
                 baseData[y*config.imageWidth+group.bounds.max.x] = 0x8F
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
                                if imageX >= Int(config.imageWidth) { continue }
                                for imageY in imageYBase - padding ... imageYBase + padding {
                                    if imageY < 0 { continue }
                                    if imageY >= Int(config.imageHeight) { continue }
                                    baseData[imageY*Int(config.imageWidth)+imageX] = 0xFF
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


