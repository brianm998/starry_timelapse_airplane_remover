import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/


/*

 problems:

  - even the excessive mode sometimes doesn't combine linear blobs
 
 */

public enum BlobProcessingType: Hashable,
                                Codable,
                                Equatable,
                                Identifiable
{
    public var id: Self { self }
    
    case save(FrameViewMode)
    case frameState(FrameProcessingState)
    case applyUserSlices
    case findBlobs(BlobFinder.Args)
    case linearBlobConnector(LinearBlobConnector.Args)
    case linearBlobExtender(LinearBlobExtender.Args)
    case blobLineTrim(BlobLineTrim.Args)
    case blobDupeCheck(String)
    case houghLineMatrixBlobConnector(HoughLineMatrixBlobConnector.Args)
    case compactBlobIds
}

// load and process all blobs for a frame, using a defined sequence of steps
public class AbstractBlobProcessor {

    internal weak var frame: FrameAirplaneRemover?
    public var steps: [BlobProcessingType] = []

    internal func shouldRunStep(atIndex index: Int) -> Bool { true }
    
    // runs each step in sequence and returns the result
    public func process(frame: FrameAirplaneRemover) async throws -> [UInt16:Blob] {
        self.frame = frame
        var blobMap: [UInt16:Blob] = [:]

        // align neighbor frame, subtract it, sort pixels
        let (subtractionArray, originalImage) = try await self.setup()

        for stepIndex in 0..<steps.count {
            let step = steps[stepIndex]

            if !shouldRunStep(atIndex: stepIndex) {
                print("shouldRunStep at index \(stepIndex) NO")
                continue
            }
            
            print("shouldRunStep at index \(stepIndex) YES")
            switch step {
                
            case .findBlobs(let args):
                blobMap = await BlobFinder().process(args,
                                                     subtractionArray: subtractionArray,
                                                     originalImage: originalImage,
                                                     frame: frame)
                
            case .applyUserSlices:
                blobMap = try await applyUserSlices(blobMap)
                
            case .blobDupeCheck(let step): // uses analyzer
                let _ = await BlobDupeCheck(blobMap: blobMap,
                                            width: frame.width,
                                            height: frame.height,
                                            frameIndex: frame.frameIndex,
                                            step: step)
                
            case .linearBlobConnector(let args): // uses analyzer
                let connector = await LinearBlobConnector(blobMap: blobMap,
                                                          width: frame.width,
                                                          height: frame.height,
                                                          frameIndex: frame.frameIndex)
                await connector.process(args)
                blobMap = await connector.blobMap()
                
                
            case .linearBlobExtender(let args): // uses analyzer
                let extender = await LinearBlobExtender(blobMap: blobMap,
                                                        width: frame.width,
                                                        height: frame.height,
                                                        frameIndex: frame.frameIndex)
                await extender.process(args)
                blobMap = await extender.blobMap()
                
                
            case .blobLineTrim(let args): // no analyzer
                let trimmer = BlobLineTrim(blobMap: blobMap, frameIndex: frame.frameIndex)
                blobMap = await trimmer.process(args)
                
                
            case .save(let imageType):
                if await frame.configManager.config().writeOutlierGroupFiles {
                    // save image
                    let fuck = imageType
                    try await frame.saveImages(for: Array(blobMap.values), as: fuck)
                }
                
            case .frameState(let processingState):
                await frame.set(state: processingState)
                
                
            case .houghLineMatrixBlobConnector(let args):
                let connector = await HoughLineMatrixBlobConnector(blobMap: blobMap,
                                                                   width: frame.width,
                                                                   height: frame.height,
                                                                   frameIndex: frame.frameIndex)
                await connector.process(args)
                blobMap = await connector.blobMap()
                
            case .compactBlobIds:
                blobMap = compactBlobIds(of: blobMap)
            }
            Log.d("frame \(frame.frameIndex) now has \(blobMap.count) blobs")
        }
        return blobMap
    }

    deinit {
        self.steps = [] // steps can have retain cycles, allow deallocation by removing them here
    }

    // Mark - internals

    // change only the ids of the blobs, so that they are all in a line from 1, onwards.
    // necessary becasuse of deleted blobs in the middle, helps to avoid UInt16 overflow
    internal func compactBlobIds(of blobMap: [UInt16:Blob]) -> [UInt16:Blob] {
        let array = Array(blobMap.values)
        Log.i("compactBlobIds \(array.count) blobs, \(UInt16.max-UInt16(array.count)) ids left in UInt16 space")
        var newBlobMap: [UInt16:Blob] = [:]
        for (index, blob) in array.enumerated() {
            let newId = UInt16(index+1) // can't use zero for blob ids
            blob.id = newId
            newBlobMap[newId] = blob
        }
        return newBlobMap
    }
    
    // slice up blobs as directed by the user
    internal func applyUserSlices(_ blobMap: [UInt16:Blob]) async throws -> [UInt16:Blob] {
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
