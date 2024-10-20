/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import Cocoa
import logging

// this class holds all the outlier groups for a frame


public actor OutlierGroups {

    let height = Int(IMAGE_HEIGHT!)
    let width = Int(IMAGE_WIDTH!)
    
    public let frameIndex: Int
    public var members: [UInt16: OutlierGroup] // keyed by name

    public func add(member: OutlierGroup) {
        members[member.id] = member
    }

    public func getMembers() -> [UInt16: OutlierGroup] { members }
    
    // image data from an image with non zero pixels set with an outlier id
    public var outlierImageData: [UInt16] = [] // outlier ids for frame, row major indexed
    public var outlierYAxisImageData: [UInt8]? // y axis of the outlierImage data

    public func outlierImageDataFunc() -> [UInt16] { outlierImageData } // XXX rename this
    
    public func set(outlierImageData: [UInt16]) {
        self.outlierImageData = outlierImageData
    }

    public func set(outlierYAxisImageData: [UInt8]) {
        self.outlierYAxisImageData = outlierYAxisImageData
    }
    
    public init(frameIndex: Int,
                members: [UInt16: OutlierGroup])
    {
        self.frameIndex = frameIndex
        self.members = members
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
    
    public init?(at frameIndex: Int,
                 withSubtractionArr subtractionArr: [UInt16],
                 fromOutlierDir outlierDir: String) async throws
    {
        //Log.d("start")
        self.frameIndex = frameIndex
        let outlierGroupPaintDataFilename = "\(outlierDir)/\(OutlierGroups.outlierGroupPaintJsonFilename)"
        let imageFilename = "\(outlierDir)/\(BlobImageSaver.outlierTiffFilename)"
        // XXX pick up y-axis if it exists
        let yAxisImageFilename = "\(outlierDir)/\(BlobImageSaver.outlierYAxisBinaryFilename)"
        let outlierGroupPaintData = try await OutlierGroups.loadOutlierGroupPaintData(from: outlierGroupPaintDataFilename)

        // XXX
        
        let _outlierGroupPaintData = outlierGroupPaintData

        self.members = [:]

        //Log.d("check 1")

        if FileManager.default.fileExists(atPath: yAxisImageFilename) {

            let fileurl = NSURL(fileURLWithPath: yAxisImageFilename, isDirectory: false)

            let (groupData, _) = try await URLSession.shared.data(for: URLRequest(url: fileurl as URL))
            self.outlierYAxisImageData = groupData.uInt8Array
            
        } else {
            //Log.w("no y axis :(")
        }
        
        //Log.d("check 2")
        if FileManager.default.fileExists(atPath: imageFilename),
           let outlierImage = try await PixelatedImage(fromFile: imageFilename)
        {
            guard outlierImage.width == width, // make sure the image is of the right size
                  outlierImage.height == height
            else { fatalError("outlierImage from \(imageFilename) of size [\(outlierImage.width), \(outlierImage.width)] doesn't match frame size [\(width), \(height)") }
            
            switch outlierImage.imageData {
            case .eightBit(_):
                Log.w("cannot process eight bit outlier image \(imageFilename)")
                return nil

            case .sixteenBit(let imageArr):
                //Log.d("check 3")

                self.outlierImageData = imageArr
                var blobMap: [UInt16: Blob] = [:]

                var coutinueCount = 0
                
                // load blobs from image
                for y in 0 ..< outlierImage.height {
                    if let outlierYAxisImageData,
                       outlierYAxisImageData[y] == 0
                    {
                        coutinueCount += 1
                        continue
                    }

                    for x in 0 ..< outlierImage.width {
                        let index = y*outlierImage.width + x
                        let blobId = imageArr[index]
                        if blobId != 0 {
                            let pixelValue = subtractionArr[index]
                            let pixel = SortablePixel(x: x, y: y, intensity: pixelValue)
                            if let blob = blobMap[blobId] {
                                // add this pixel to existing blob
                                await blob.add(pixel: pixel)
                            } else {
                                // start a new blob with this pixel
                                let blob = Blob(CodableBlob(pixel, id: blobId, frameIndex: frameIndex))
                                blobMap[blobId] = blob
                            }
                        }
                    }
                }

                //Log.d("check 4 coutinueCount \(coutinueCount)")
                // promote found blobs to outlier groups for further processing
                // apply should paint if loaded
                
                for blob in blobMap.values {
                    // make outlier group from this blob
                    let outlierGroup = await blob.outlierGroup(at: frameIndex)

                    if let _outlierGroupPaintData {
                        // the newer full frame json file

                        if let shouldPaint = _outlierGroupPaintData[outlierGroup.id] {
                            await outlierGroup.shouldPaint(shouldPaint)
                        } else {
                            //Log.i("frame \(frameIndex) could not find outlier group info for group \(outlierGroup.id) in outlierGroupPaintData")
                        }
                    }

                    self.members[outlierGroup.id] = outlierGroup
                }
                //Log.d("check 5")
            }
        } else {
            Log.d("FUCKED \(imageFilename)")
            return nil
        }
    }

    // returns outlier groups from this frame that overlap with the given group from another frame
    public func groups(overlapping group: OutlierGroup) async -> [OutlierGroup] {
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
            if let outlierYAxisImageData,
               outlierYAxisImageData[y] == 0 { continue }
            
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

    public func applyRazor(in boundingBox: BoundingBox) async -> Bool {
        var newBlobPixels: Set<SortablePixel> = []
        var newOutlierGroups: [OutlierGroup] = []
        var maxKey: UInt16 = 0
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

    public func deleteOutliers(in gestureBounds: BoundingBox) {
        for (key, group) in members {
            if gestureBounds.contains(group.bounds) {
                members.removeValue(forKey: key)
            }
        }
    }

    public func writeOutliersImage(to dirname: String) async throws {

        var blobMap: [UInt16: Blob] = [:]

        for outlier in members.values {
            let blob = await outlier.blob()
            blobMap[blob.id] = blob
        }

        let blobImageSaver: BlobImageSaver = await .init(blobMap: blobMap,
                                                         width: width,
                                                         height: height,
                                                         frameIndex: frameIndex)
        
        self.outlierImageData = await blobImageSaver.blobRefs
        self.outlierYAxisImageData = await blobImageSaver.yAxis

        mkdir(dirname)
        
        await blobImageSaver.save(to: dirname)
    }
    
    // only writes the paint reasons now, outlier image is written elsewhere
    public func write(to dir: String) async throws {
        Log.d("writing  \(self.members.count) outlier groups for frame \(self.frameIndex) to binary file")
        let frameDir = "\(dir)/\(frameIndex)"
        
        mkdir(frameDir)

        // data to save for paint reasons for all outliers in this frame
        var outlierGroupPaintData: [UInt16:PaintReason] = [:]
        
        for group in members.values {
            // collate paint reasons for each group
            if let shouldPaint = await group.shouldPaint() {
                outlierGroupPaintData[group.id] = shouldPaint
            }
        }

        // write outlier paint reason json here 
        
        let outlierGroupPaintDataFilename = "\(frameDir)/OutlierGroupPaintData.json"

        let encoder = JSONEncoder()
//            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
          positiveInfinity: "inf",
          negativeInfinity: "-inf",
          nan: "nan")

        if FileManager.default.fileExists(atPath: outlierGroupPaintDataFilename) {
            try FileManager.default.removeItem(atPath: outlierGroupPaintDataFilename)
        } 
        FileManager.default.createFile(atPath: outlierGroupPaintDataFilename,
                               contents: try encoder.encode(outlierGroupPaintData),
                               attributes: nil)
        
        Log.d("wrote  \(self.members.count) outlier groups for frame \(self.frameIndex) to binary file")
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


