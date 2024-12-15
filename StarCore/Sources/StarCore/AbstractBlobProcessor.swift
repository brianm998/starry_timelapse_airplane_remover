import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/
public typealias BlobMap = [UInt16:Blob]

/*

 problems:

  - line split on real lines can split them when it shoudln't
 
 */

public enum BlobFunctionType {
    case trimWithConstants
    case applyUserSlices
    case removeReallyBigBlobsWithSmallDimBunches
}

public enum BlobProcessingType: Hashable {
    case save(FrameViewMode)
    case frameState(FrameProcessingState)
    case process(BlobFunctionType)
    case dimIsolatedBlobRemover(DimIsolatedBlobRemover.Args)
    case isolatedBlobRemover(IsolatedBlobRemover.Args)
    case disconnectedBlobRemover(DisconnectedBlobRemover.Args)
    case linearBlobConnector(LinearBlobConnector.Args)
    case blobLineTrim(BlobLineTrim.Args)
    case borderBrightnessLessThan(Double,UInt16)
    case lineSplit(BlobLineSplitter.Args)
    case blobDupeCheck(String)
    case smallBlobRemover(SmallBlobRemover.Args)
    case smallDimBlobRemover(SmallDimBlobRemover.Args)
}

// load and process all blobs for a frame, using a defined sequence of steps
public class AbstractBlobProcessor {

    internal weak var frame: FrameAirplaneRemover?
    public var steps: [BlobProcessingType] = []

    public init() { }

    // runs each step in sequence and returns the result
    public func process(frame: FrameAirplaneRemover) async throws -> BlobMap {
        self.frame = frame
        var blobMap: BlobMap = [:]

        // align neighbor frame, subtract it, sort pixels
        let (subtractionArray, originalImage) = try await self.setup()

        // create the first blobs from subtraction image
        blobMap = try await self.findBlobs(subtractionArray: subtractionArray,
                                           originalImage: originalImage)

        for step in steps {
            switch step {

            case .process(let functionType):
                switch functionType {
                case .trimWithConstants:
                    blobMap = try await trimWithConstants(blobMap)
                case .applyUserSlices:
                    blobMap = try await applyUserSlices(blobMap)
                case .removeReallyBigBlobsWithSmallDimBunches:
                    blobMap = try await removeReallyBigBlobsWithSmallDimBunches(blobMap)
                }
                
            case .smallBlobRemover(let args): // no analyzer
                let remover = SmallBlobRemover(blobMap: blobMap,
                                               frameIndex: frame.frameIndex)

                await remover.process(args)
                blobMap = await remover.blobMap()

            case .smallDimBlobRemover(let args): // no analyzer
                let remover = SmallDimBlobRemover(blobMap: blobMap,
                                                  frameIndex: frame.frameIndex)
                await remover.process(args)
                blobMap = remover.blobMap
                
            case .blobDupeCheck(let step): // uses analyzer
                let _ = await BlobDupeCheck(blobMap: blobMap,
                                            width: frame.width,
                                            height: frame.height,
                                            frameIndex: frame.frameIndex,
                                            step: step)
                
            case .lineSplit(let args): // no analyzer
                let splitter = BlobLineSplitter(blobMap: blobMap,
                                                frameIndex: frame.frameIndex)
                await splitter.process(args)
                blobMap = await splitter.blobMap()

                
            case .borderBrightnessLessThan(let amount, let medianItensityFloor): // no analyzer
                var ret: [UInt16: Blob] = [:]
                for (_, blob) in blobMap {
                    let medianIntensity = await blob.medianIntensity()
                    if await originalImage.borderBrightness(of: blob.pixels) < amount ||
                         medianIntensity > medianItensityFloor
                    {
                        ret[blob.id] = blob
                    }
                }
                blobMap = ret
                
                
            case .linearBlobConnector(let args): // uses analyzer
                let connector = await LinearBlobConnector(blobMap: blobMap,
                                                          width: frame.width,
                                                          height: frame.height,
                                                          frameIndex: frame.frameIndex)
                await connector.process(args)
                blobMap = await connector.blobMap()


            case .blobLineTrim(let args): // no analyzer
                let trimmer = BlobLineTrim(blobMap: blobMap, frameIndex: frame.frameIndex)
                blobMap = await trimmer.process(args)
                
            case .isolatedBlobRemover(let args): // uses analyzer
                let remover = await IsolatedBlobRemover(blobMap: blobMap,
                                                        width: frame.width,
                                                        height: frame.height,
                                                        frameIndex: frame.frameIndex)
                await iterate() { shouldRun in
                    if shouldRun {
                        await remover.process(args)
                    }
                    return await remover.blobMap().count
                }
                blobMap = await remover.blobMap()
                

            case .disconnectedBlobRemover(let args): // uses analyzer
                let remover = await DisconnectedBlobRemover(blobMap: blobMap,
                                                            width: frame.width,
                                                            height: frame.height,
                                                            frameIndex: frame.frameIndex)
                await remover.process(args)
                blobMap = await remover.blobMap()
                

            case .dimIsolatedBlobRemover(let args): // uses analyzer
                let remover = await DimIsolatedBlobRemover(blobMap: blobMap,
                                                           width: frame.width,
                                                           height: frame.height,
                                                           frameIndex: frame.frameIndex)
                await iterate() { shouldRun in
                    if shouldRun {
                        await remover.process(args)
                    }

                    return await remover.blobMap().count
                }
                blobMap = await remover.blobMap()
                
                
            case .save(let imageType):
                if await frame.configManager.config().writeOutlierGroupFiles {
                    // save image
                    let fuck = imageType
                    try await frame.saveImages(for: Array(blobMap.values), as: fuck)
                }

            case .frameState(let processingState):
                await frame.set(state: processingState)

            }
            Log.d("frame \(frame.frameIndex) now has \(blobMap.count) blobs")
        }
        self.steps = [] // steps can have retain cycles, allow deallocation by removing them here
        return blobMap
    }

    // Mark - internals

    internal func removeReallyBigBlobsWithSmallDimBunches(_ blobMap: [UInt16:Blob]) async throws -> BlobMap {
        var ret: [UInt16: Blob] = [:]

        for (_, blob) in blobMap {
            let blobSize = await blob.size()

            if blobSize > 1000,
               await blob.bunchCount() > 100,
               await blob.medianBunchSize() < 10,
               await blob.medianIntensity() < 6000
            {
                //Log.d("frame \(frame.frameIndex) dumping blob \(blob) of size \(blobSize) bunch count \(await blob.bunchCount()) medianBunchSize \(await blob.medianBunchSize()) medianIntensity \(await blob.medianIntensity())")
                // try processing this further by getting rid of dim blobs?
                // for now just kick it out
                await blob.removePixels(dimmerThan: 6000)
                ret[blob.id] = blob
            } else {
                ret[blob.id] = blob
            }
        }
        return ret
    }
    
    internal func trimWithConstants(_ blobMap: [UInt16:Blob]) async throws -> BlobMap {
        var ret: [UInt16: Blob] = [:]

        let blobberMinBlobSize = await constants.blobberMinBlobSize
        let blobberMinBlobIntensity = await constants.blobberMinBlobIntensity
        let blobberMinSmallBlobIntensity = await constants.blobberMinSmallBlobIntensity
        
        for (_, blob) in blobMap {
            // anything this small is noise

            let blobIntensity = await blob.medianIntensity()
            
            if await blob.size() <= blobberMinBlobSize {
                //Log.d("frame \(frame.frameIndex) dumping blob \(blob) of size \(await blob.size()) <= \(blobberMinBlobSize)")

                if let blobberMinSmallBlobIntensity {
                    if blobIntensity < blobberMinSmallBlobIntensity {
                        continue
                    } else {
                        // pass through smaller bright blobs
                    }
                } else {
                    continue
                }
            }

            if blobIntensity < blobberMinBlobIntensity {
                //Log.d("frame \(frame.frameIndex) dumping blob \(blob) of median intensity \(await blob.medianIntensity()) <= \(blobberMinBlobIntensity)")
                continue
            }
            
            // only keep smaller blobs if they are bright enough
            if !(await constants.blobberSmallBlobQualifier.allows(blob)) {
                //Log.d("frame \(frame.frameIndex) dumping blob \(blob)")
                continue
            }

            // this blob has passed these checks, keep it for now
            ret[blob.id] = blob
        }
        return ret
    }
    
    // slice up blobs as directed by the user
    internal func applyUserSlices(_ blobMap: [UInt16:Blob]) async throws -> BlobMap {
        guard let frame else { return [:] }

        var newBlobs: [UInt16:Blob] = blobMap
        
        var maxKey: UInt16 = 0
        
        for slice in await frame.getUserSlices() {
            var newBlobPixels: Set<SortablePixel> = []
            for (key, blob) in blobMap {
                if key > maxKey { maxKey = key }
                if let overlap = await slice.overlap(with: blob.boundingBox()) {
                    let newPixels = await blob.slice(with: overlap)
                    newBlobPixels.formUnion(newPixels)
                }
                newBlobs[blob.id] = blob
            }
            if newBlobPixels.count > 0 {
                maxKey += 1
                newBlobs[maxKey] = Blob(newBlobPixels,
                                        id: maxKey,
                                        frameIndex: frame.frameIndex) 
            }
        }
        
        return newBlobs
    }
    
    // use the subtraction and original image for this frame to find an initial set of blobs

    internal func setup() async throws -> ([UInt16], PixelatedImage) {
        guard let frame else { fatalError("need frame") } // XXX ???
        let frameIndex = frame.frameIndex
        let imageAccessor = frame.imageAccessor
      
        var subtractionArray: [UInt16] = []
        var subtractionImage: PixelatedImage?
        do {
            // try to load the image subtraction from a pre-processed file

            if let image = try await imageAccessor.load(frameIndex: frameIndex,
                                                        type: .subtraction,
                                                        atSize: .original)
            {
                Log.d("frame \(frameIndex) loaded subtraction image")
                subtractionImage = image
                switch image.imageData {
                case .sixteenBit(let array):
                    subtractionArray = array
                case .eightBit(_):
                    Log.e("frame \(frameIndex) eight bit images not supported here yet")
                }
                Log.d("frame \(frameIndex) loaded outlier amounts from subtraction image")

                try await imageAccessor.save(image,
                                             frameIndex: frameIndex,
                                             as: .subtraction,
                                             atSize: .preview, overwrite: false)
                Log.d("frame \(frameIndex) saved subtraction image preview") 
            }
        } catch {
            Log.i("frame \(frameIndex) couldn't load outlier amounts from subtraction image")
            // do the image subtraction here instead
        }
        Log.d("frame \(frameIndex)")
        if subtractionImage == nil {        
            Log.d("frame \(frameIndex) creating subtraction image") 
            let image = try await frame.subtractAlignedImageFromFrame()
            Log.d("frame \(frameIndex) created subtraction image") 
            subtractionImage = image
            switch image.imageData {
            case .eightBit(_):
                fatalError("NOT SUPPORTED YET")
            case .sixteenBit(let origImagePixels):
                subtractionArray = origImagePixels
            }
            Log.d("frame \(frameIndex) loaded subtractionArray with \(subtractionArray.count) items")
        }

        guard let originalImage = try await imageAccessor.load(frameIndex: frameIndex,
                                                               type: .original,
                                                               atSize: .original)
        else { throw "couldn't load original file for blobbing" }

        return (subtractionArray, originalImage)
    }

    internal func findBlobs(subtractionArray: [UInt16], originalImage: PixelatedImage) async throws -> BlobMap {
        guard let frame else { fatalError("need frame") } // XXX ???
        
        // detect blobs of difference in brightness in the subtraction array
        // airplanes show up as lines or dots in a line
        // because the image subtracted from this frame had the sky aligned,
        // the ground may get moved, and therefore may contain blobs as well.
        let blobber = await FullFrameBlobber(config: await frame.configManager.config(),
                                             imageWidth: frame.width,
                                             imageHeight: frame.height,
                                             subtractionPixelData: subtractionArray,
                                             originalImage: originalImage,
                                             frameIndex: frame.frameIndex,
                                             neighborType: .eight)//.fourCardinal

        blobber.sortPixels()
        
        await frame.set(state: .detectingBlobs)
        
        // run the blobber
        await blobber.process()
        
        Log.d("frame \(frame.frameIndex) blobber done")

        return blobber.blobMap
    }
    
    // re-run something repeatedly
    internal func iterate(closure: (Bool) async -> Int, max: Int = 8) async {

        var lastCount = await closure(false)
        var shouldContinue = true
        var count = 0

        while shouldContinue {
            let thisCount = await closure(true)
            if lastCount == thisCount { shouldContinue = false }
            lastCount = thisCount
            count += 1
            if count > max { shouldContinue = false }
        }
    }
}

public func nextIndex(from blobMap: [UInt16:Blob]) -> UInt16? {
    for i in 1..<UInt16.max {
        if blobMap[i] == nil {
            return i
        }
    }
    return nil
}
