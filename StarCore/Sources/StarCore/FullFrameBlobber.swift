import Foundation
import logging


/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/*
 A bright blob detector.

 Looks at an image and tries to identify separate blobs
 based upon local maximums of brightness, and changes in contrast from that.

 All pixels are sorted by brightness, and iterated over from the brightest,
 down to minIntensity.  All nearby pixels that fall within the minContrast threshold
 will be included in the blob.

 Directly adjcent blobs should be combined.

 Blobs dimmer on average than minIntensity are discarded.
 */
public class FullFrameBlobber {

    private let config: Config
    private let args: BlobFinder.Args

    // sorted by brightness
    public var sortedPixels: [SortablePixel] = []

    public let imageWidth: Int
    public let imageHeight: Int

    // only operate within this area
    public let bounds: BoundingBox?

    public let subtractionPixelData: [UInt16]

    public let frameIndex: Int

    // running blob bucket
    public var blobs: [Blob] = []

    // how we search for neighbors
    public let neighborType: NeighborType

    private var newBlobId: Int32 = 1 // start at one as zero means no blob

    // Row-major, one byte per pixel: 1 where the pixel is one the blobber can use at all — bright
    // enough to seed or join a blob, or a dim one close enough to the threshold to still be
    // reachable by contrast. Everything else is invisible to the neighbour search.
    //
    // This and `state` replace a `[[SortablePixel?]]` (24 bytes a pixel, touched column by
    // column) and an actor-held array of enum statuses (8 bytes a pixel), and the actor hop per
    // pixel that went with them: the blobber is now plain arrays and a loop.
    private var tracked: [UInt8] = []

    // Row-major status of every pixel: `unknown`, `background`, or the id of the blob it belongs
    // to. Both markers are negative because ids never are. Neither may be 0: production starts
    // the ids there (`FrameOutlierProcessor.findOutliers()`), and while 0 also meant unknown,
    // blob 0 could never claim a pixel, so its flood fill queued the same neighbours forever and
    // ran the process out of memory.
    private var state: [Int32] = []
    private static let unknown: Int32 = -2
    private static let background: Int32 = -1

    // The pixels of each blob as they are found, in the same order the old per-blob sets were
    // filled; the `Blob` actors are built from these once at the end.
    private var blobPixelIndices: [[Int32]] = []
    private var blobIds: [Int32] = []

    // neighbor search policies
    public enum NeighborType {
        case fourCardinal       // up and down, left and right, no corners
        case fourCorner         // diagnals only
        case eight              // the sum of the other two
    }

    // different directions from a pixel
    public enum NeighborDirection {
        case up
        case down
        case left
        case right
        case lowerRight
        case upperRight
        case lowerLeft
        case upperLeft
    }

    public init(config: Config,
                args: BlobFinder.Args,
                imageWidth: Int,
                imageHeight: Int,
                within bounds: BoundingBox? = nil,
                subtractionPixelData: [UInt16],
                frameIndex: Int,
                neighborType: NeighborType,
                startingBlobID: UInt16 = 1) async
    {
        // pixels that are local maximums, but have a value lower than this are ignored
        let minIntensity = args.minPixelIntensity
        self.config = config
        self.args = args
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.bounds = bounds
        self.subtractionPixelData = subtractionPixelData
        self.frameIndex = frameIndex
        self.neighborType = neighborType
        self.newBlobId = Int32(startingBlobID)

        guard subtractionPixelData.count == imageWidth*imageHeight else {
            fatalError("subtractionPixelData.count \(subtractionPixelData.count) is not imageWidth*imageHeight \(imageWidth*imageHeight)")
        }

        Log.v("frame \(frameIndex) blobbing image of size (\(imageWidth), \(imageHeight))")

        tracked = [UInt8](repeating: 0, count: imageWidth*imageHeight)
        state = [Int32](repeating: Self.unknown, count: imageWidth*imageHeight)

        let minContrast = args.startMinContrast

        var minX = 0
        var maxX = imageWidth

        var minY = 0
        var maxY = imageHeight

        let ignoreLowerPixels = config.ignoreLowerPixels
        maxY = imageHeight - ignoreLowerPixels
        if maxY < 0 { maxY = 0 }

        if let bounds {
            minX = bounds.min.x
            maxX = bounds.max.x
            minY = bounds.min.y
            maxY = bounds.max.y
            if minX < 0 { minX = 0 }
            if minY < 0 { minY = 0 }
            if maxX > imageWidth { maxX = imageWidth }
            if maxY > imageHeight { maxY = imageHeight }
        }

        // Swift runtime failure: Range requires lowerBound <= upperBound + 0 [inlined]
        guard minX < maxX,
              minY < maxY
        else { return }

        // Appended column by column (x outer, y inner) exactly as before: a stable sort keeps
        // that order among equal brightnesses, and the seeds are visited in it.
        for x in minX..<maxX {
            for y in minY..<maxY {
                let intensity = subtractionPixelData[y*imageWidth+x]

                if intensity > minIntensity {
                    // these pixels are both sorted and tracked
                    tracked[y*imageWidth+x] = 1
                    sortedPixels.append(SortablePixel(x: x, y: y, value: .sixteenBit(intensity)))
                } else {

                    // XXX check if this step is necessary

                    // these pixels are dimmer, and might be tracked
                    let diff = Double(abs(Int32(intensity) - Int32(minIntensity)))
                    let max = Double(max(intensity, minIntensity))

                    let contrast = diff / max * 100

                    // some pixels are too dim to even track
                    if contrast < minContrast {
                        tracked[y*imageWidth+x] = 1
                    }
                }
            }
        }
    }

    /// Brightest first, and among equal brightnesses in the order the pixels were collected.
    ///
    /// A counting sort on the 16-bit value. Stable by construction, which is what the
    /// comparison sort it replaces happened to be, and linear instead of n log n over what can
    /// be millions of pixels.
    public func sortPixels() {
        Log.d("frame \(frameIndex) sorting pixel values")
        guard sortedPixels.count > 1 else { return }

        var counts = [Int](repeating: 0, count: 65536 + 1)
        for pixel in sortedPixels { counts[Int(pixel.uInt32Value)] += 1 }

        // descending: the first slot belongs to the brightest value
        var offsets = [Int](repeating: 0, count: 65536)
        var running = 0
        for value in stride(from: 65535, through: 0, by: -1) {
            offsets[value] = running
            running += counts[value]
        }

        var sorted = sortedPixels  // same length; every slot is overwritten below
        for pixel in sortedPixels {
            let value = Int(pixel.uInt32Value)
            sorted[offsets[value]] = pixel
            offsets[value] += 1
        }
        sortedPixels = sorted
    }

    public func process() async {
        Log.d("frame \(frameIndex) detecting blobs")
        findBlobs()
        await buildBlobs()
        Log.i("frame \(frameIndex) found \(blobs.count)")
    }

    /// The whole blob search, synchronously, over plain arrays.
    private func findBlobs() {
        var neighborIndices = [Int](repeating: 0, count: 8)

        for pixel in sortedPixels {
            let index = pixel.y*imageWidth + pixel.x
            if state[index] != Self.unknown { continue }

            let value = subtractionPixelData[index]
            let count = collectNeighbors(of: pixel.x, pixel.y, into: &neighborIndices)

            var hasHigherNeighbor = false
            for i in 0..<count where subtractionPixelData[neighborIndices[i]] > value {
                hasHigherNeighbor = true
                break
            }

            if !hasHigherNeighbor {
                // no higher neighbors
                // a local maximum, this pixel is a blob seed

                if newBlobId < Int32.max {
                    expand(blobId: newBlobId, seed: index)
                    newBlobId += 1
                } else {
                    // we've got more than UInt16.max blob seeds, that's a lot
                    // don't create more blobs
                    Log.w("frame \(frameIndex) reached newBlobId \(newBlobId), cannot create new blobs")
                    break
                }
            } else {
                // but only if it's bright enough
                state[index] = Self.background
            }
        }
    }

    /// Grows one blob from its seed, as the old actor-based `expand` did.
    ///
    /// Two things here are easy to lose and both affect the result: a neighbour is pushed every
    /// time a pixel finds it still unknown, so it can be queued more than once; and the contrast
    /// threshold is read at the moment each neighbour is examined, from the blob's size *then*
    /// (distinct pixels added so far), so a pixel queued early can be refused when met again
    /// after the blob has grown and then be added anyway when it is popped.
    private func expand(blobId: Int32, seed firstSeedIndex: Int) {
        var pixelsOfBlob: [Int32] = []
        let firstSeedValue = UInt32(subtractionPixelData[firstSeedIndex])
        var stack: [Int] = [firstSeedIndex]
        var neighborIndices = [Int](repeating: 0, count: 8)

        while let seedIndex = stack.popLast() {
            // set this pixel to be part of this blob
            if state[seedIndex] != blobId {
                state[seedIndex] = blobId
                pixelsOfBlob.append(Int32(seedIndex))
            }

            let x = seedIndex % imageWidth, y = seedIndex / imageWidth
            let count = collectNeighbors(of: x, y, into: &neighborIndices)
            for i in 0..<count {
                let neighborIndex = neighborIndices[i]
                if state[neighborIndex] == Self.unknown {
                    // if unknown status, check contrast with initial seed pixel
                    let other = UInt32(subtractionPixelData[neighborIndex])
                    let diff = Double(abs(Int32(firstSeedValue) - Int32(other)))
                    let max = Double(max(firstSeedValue, other))
                    let firstSeedContrast = diff / max * 100

                    if firstSeedContrast < calculateMinContrast(for: pixelsOfBlob.count) {
                        stack.append(neighborIndex)
                    } else {
                        state[neighborIndex] = Self.background
                    }
                }
            }
        }

        blobIds.append(blobId)
        blobPixelIndices.append(pixelsOfBlob)
    }

    /// Builds the `Blob` actors from what the search found, in id order.
    private func buildBlobs() async {
        blobs.reserveCapacity(blobIds.count)
        for (blobIndex, id) in blobIds.enumerated() {
            var pixels = Set<SortablePixel>(minimumCapacity: blobPixelIndices[blobIndex].count)
            for pixelIndex in blobPixelIndices[blobIndex] {
                let i = Int(pixelIndex)
                pixels.insert(SortablePixel(x: i % imageWidth, y: i / imageWidth,
                                            value: .sixteenBit(subtractionPixelData[i])))
            }
            blobs.append(Blob(pixels, id: id, frameIndex: frameIndex))
        }
        blobIds = []
        blobPixelIndices = []
    }

    public var blobMap: [Int32:Blob] {
        var ret: [Int32:Blob] = [:]
        for blob in self.blobs { ret[blob.id] = blob }
        return ret
    }

    public func outputImage() async -> PixelatedImage? {
        await self.outputData().image
    }

    // used for writing out blob data for viewing
    public func outputData() async -> ImageBuffer<UInt16> {
        var ret = ImageBuffer<UInt16>(
          width: imageWidth,
          height: imageHeight,
          components: 1
        )

        let min:  UInt16 = 0x4FFF
        let max:  UInt16 = 0xFFFF
        let step: UInt16 = 0x1000

        var value: UInt16 = min

        for blob in blobs {
            //Log.v("writing out \(blob.size) pixel blob")
            for pixel in await blob.getPixels() {
                // maybe adjust by size?
                //ret[pixel.y*imageWidth+pixel.x] = 0xFFFF / 4 + (blob.intensity/4)*3
                ret[pixel.y*imageWidth+pixel.x] = value
            }
            if value >= max { value = min }
            value += step
        }
        return ret
    }

    private func calculateMinContrast(for blobSize: Int) -> Double {
        if blobSize < args.startContrastSize {
            return args.startMinContrast
        } else if blobSize >= args.endContrastSize {
            return args.endMinContrast
        } else {
            // between the start and end
            let sizeGap = Double(abs(args.endContrastSize - args.startContrastSize))
            let contrastGap = Double(abs(args.startMinContrast - args.endMinContrast))
            let gapAmount = Double(blobSize-args.startContrastSize)
            return args.startMinContrast - gapAmount/sizeGap*contrastGap
        }
    }

    /// The tracked neighbours of (x, y) in this blobber's search order, as row-major indices
    /// written into `out`; returns how many. Cardinal directions first (left, right, up, down),
    /// then the diagonals (upper left, upper right, lower left, lower right), as the old
    /// `neighborsInt` did. Pixels off the image, and pixels the blobber does not track, are
    /// skipped.
    private func collectNeighbors(of x: Int, _ y: Int, into out: inout [Int]) -> Int {
        var count = 0
        @inline(__always) func consider(_ dx: Int, _ dy: Int) {
            let nx = x + dx, ny = y + dy
            if nx < 0 || ny < 0 || nx >= imageWidth || ny >= imageHeight { return }
            let index = ny*imageWidth + nx
            if tracked[index] != 0 {
                out[count] = index
                count += 1
            }
        }
        switch neighborType {
        case .fourCardinal:
            consider(-1, 0); consider(1, 0); consider(0, -1); consider(0, 1)
        case .fourCorner:
            consider(-1, -1); consider(1, -1); consider(-1, 1); consider(1, 1)
        case .eight:
            consider(-1, 0); consider(1, 0); consider(0, -1); consider(0, 1)
            consider(-1, -1); consider(1, -1); consider(-1, 1); consider(1, 1)
        }
        return count
    }

    // for the NeighborType of this Blobber
    public func neighbors(of pixel: SortablePixel) -> [SortablePixel] {
        var indices = [Int](repeating: 0, count: 8)
        let count = collectNeighbors(of: pixel.x, pixel.y, into: &indices)
        return (0..<count).map { i in
            let index = indices[i]
            return SortablePixel(x: index % imageWidth, y: index / imageWidth,
                                 value: .sixteenBit(subtractionPixelData[index]))
        }
    }
}
