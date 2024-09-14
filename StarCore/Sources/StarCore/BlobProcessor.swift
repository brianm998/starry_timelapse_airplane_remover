import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/
public typealias BlobMap = [UInt16:Blob]

public enum BlobProcessingType {
    case create(() async throws -> BlobMap)
    case process((BlobMap) async throws -> BlobMap)
    case save(FrameImageType)
    case frameState(FrameProcessingState)
}

// load and process all blobs for a frame, using a defined sequence of steps
public class BlobProcessor {

    weak var frame: FrameAirplaneRemover?
    fileprivate var steps: [BlobProcessingType] = []
    
    public init(frame: FrameAirplaneRemover) {
        self.frame = frame
        
        /*
         Outlier Detection Logic:

          - align neighboring frame
          - subtract aligned frame from this frame
          - sort pixels on subtracted frame by intensity
          - detect blobs from sorted pixels
          - remove isolated dimmer blobs
          - remove small isolated blobs
          - filter out small dim blobs
          - remove more small dim blobs
          - final pass at more isolation removal
          - absorb linear blobs together
          - save image of final blobs before promotion to outlier groups
          - promote remaining blobs to outlier groups for further analysis
         */
        
        self.steps = [
          .create(findBlobs),
          .save(.blobs),
          .frameState(.isolatedBlobRemoval),
          .process(firstIsolatedDimProcess),
          .save(.filter1),
          .process(firstIsolatedProcess),
          .save(.filter2),
          .process(finalIsolatedRemover),
          .save(.filter3),
          .process(finalDimIsolatedRemover),
          .save(.filter4),
          .frameState(.isolatedBlobRemoval2),
          .process(smallerDisconnectedBlobRemover),
          .save(.filter5),
          .process(largerDisconnectedBlobRemover),
          .frameState(.linearBlobAbsorbtion),
          .process(linearBlobConnector), // run more than once?
          // another step to remove any remaining small blobs
          .process(funkyCompactMap),
          .save(.filter6),
        ]
    }

    public func run() async throws -> BlobMap {
        var blobMap: BlobMap = [:]
        for step in steps {
            switch step {
            case .create(let method):
                blobMap = try await method()

            case .process(let method):
                blobMap = try await method(blobMap)

            case .save(let imageType):
                if let frame {
                    if frame.config.writeOutlierGroupFiles {
                        // save image 
                        try await frame.saveImages(for: Array(blobMap.values), as: imageType)
                    }
                }

            case .frameState(let processingState):
                frame?.state = processingState

            }
        }
        return blobMap
    }

    // Mark - internals

    // use the subtraction and original image for this frame to find an initial set of blobs
    fileprivate func findBlobs() async throws -> BlobMap {
        guard let frame else { return [:] }
        let frameIndex = frame.frameIndex
        let imageAccessor = frame.imageAccessor
        
        var subtractionArray: [UInt16] = []
        var originalImageArray: [UInt16] = []
        var subtractionImage: PixelatedImage?
        do {
            // try to load the image subtraction from a pre-processed file

            if let image = await imageAccessor.load(type: .subtracted, atSize: .original) {
                Log.d("frame \(frameIndex) loaded subtraction image")
                subtractionImage = image
                switch image.imageData {
                case .sixteenBit(let array):
                    subtractionArray = array
                case .eightBit(_):
                    Log.e("frame \(frameIndex) eight bit images not supported here yet")
                }
                Log.d("frame \(frameIndex) loaded outlier amounts from subtraction image")

                try await imageAccessor.save(image, as: .subtracted,
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

        guard let originalImage = await imageAccessor.load(type: .original, atSize: .original)
        else { throw "couldn't load original file for finishing" }

        switch originalImage.imageData {
        case .sixteenBit(let array):
            originalImageArray = array
        case .eightBit(_):
            throw "8 bit images are not currently supported by Star, only 16 bit images"
        }
        
        frame.state = .assemblingPixels

        Log.d("frame \(frameIndex) running blobber")
                
        // detect blobs of difference in brightness in the subtraction array
        // airplanes show up as lines or does in a line
        // because the image subtracted from this frame had the sky aligned,
        // the ground may get moved, and therefore may contain blobs as well.
        let blobber = FullFrameBlobber(config: frame.config,
                                       imageWidth: frame.width,
                                       imageHeight: frame.height,
                                       subtractionPixelData: subtractionArray,
                                       originalPixelData: originalImageArray,
                                       originalBytesPerRow: originalImage.bytesPerRow,
                                       originalBytesPerPixel: originalImage.bytesPerPixel,
                                       frameIndex: frameIndex,
                                       neighborType: .eight)//.fourCardinal

        blobber.sortPixels()
        
        frame.state = .detectingBlobs
        
        // run the blobber
        blobber.process()

        Log.d("frame \(frameIndex) blobber done")

        return blobber.blobMap
    }

    fileprivate func firstIsolatedDimProcess(blobs: BlobMap) async throws -> BlobMap {
        guard let frame else { return [:] }
        let idibr = DimIsolatedBlobRemover(blobMap: blobs,
                                           width: frame.width,
                                           height: frame.height)
        
        idibr.process(scanSize: 20) // XXX constant

        return idibr.blobMap
    }
    
    fileprivate func firstIsolatedProcess(blobs: BlobMap) async throws -> BlobMap {
        guard let frame else { return [:] }
        let isolatedRemover = IsolatedBlobRemover(blobMap: blobs,
                                                  width: frame.width,
                                                  height: frame.height)

        isolatedRemover.process(minNeighborSize: 6, scanSize: 24)            

        Log.d("frame \(frame.frameIndex) first isolated remover returned \(isolatedRemover.blobMap.count) blobs")
        
        return isolatedRemover.blobMap
    }

    fileprivate func funkyCompactMap(blobs: BlobMap) async throws -> BlobMap {

        // weed out blobs that are too small and not bright enough
        // XXX this is eating a lot of blobs we want :(
        blobs.compactMapValues { blob in
            if blob.size < 20,
               blob.medianIntensity < 2000 // XXX constant
            {
                return nil
            } else if blob.size < 30,
                      blob.medianIntensity < 1000 // XXX constant
            {
                return nil 
            } else {
                // this blob is either bigger than the largest size tested for above,
                // or brighter than the medianIntensity set for its size group
                return blob
            }
        }
    }

    fileprivate func finalIsolatedRemover(blobs: BlobMap) async throws -> BlobMap {
        guard let frame else { return [:] }
        
        let finalIsolatedRemover = IsolatedBlobRemover(blobMap: blobs,
                                                       width: frame.width,
                                                       height: frame.height)

        iterate() { shouldRun in
            if shouldRun {
                finalIsolatedRemover.process(minNeighborSize: 6, scanSize: 24) // XXX constants
            }
            return finalIsolatedRemover.blobMap.count
        }
        return finalIsolatedRemover.blobMap
    }

    fileprivate func finalDimIsolatedRemover(blobs: BlobMap) async throws -> BlobMap {
        guard let frame else { return [:] }

        let dimIsolatedBlobRemover = DimIsolatedBlobRemover(blobMap: blobs,
                                                            width: frame.width,
                                                            height: frame.height)

        // XXX how about this one, how much does it suck?
        // not that much :)

        iterate() { shouldRun in
            if shouldRun {
                dimIsolatedBlobRemover.process(scanSize: 24) // XXX constant
            }

            return dimIsolatedBlobRemover.blobMap.count
        }

        return dimIsolatedBlobRemover.blobMap
    }

    // re-run something repeatedly
    fileprivate func iterate(closure: (Bool) -> Int, max: Int = 8) {

        var lastCount = closure(false)
        var shouldContinue = true
        var count = 0

        while shouldContinue {
            let thisCount = closure(true)
            if lastCount == thisCount { shouldContinue = false }
            lastCount = thisCount
            count += 1
            if count > max { shouldContinue = false }
        }
    }

    fileprivate func smallerDisconnectedBlobRemover(blobs: BlobMap) async throws -> BlobMap {
        guard let frame else { return [:] }

        let remover = DisconnectedBlobRemover(blobMap: blobs,
                                              width: frame.width,
                                              height: frame.height)

        remover.process(scanSize: 60,
                        blobsSmallerThan: 18,
                        requiredNeighbors: 2)

        return remover.blobMap
    }

    fileprivate func largerDisconnectedBlobRemover(blobs: BlobMap) async throws -> BlobMap {
        guard let frame else { return [:] }

        let remover = DisconnectedBlobRemover(blobMap: blobs,
                                              width: frame.width,
                                              height: frame.height)

        remover.process(scanSize: 60,
                        blobsSmallerThan: 50,
                        blobsLargerThan: 18,
                        requiredNeighbors: 2)

        return remover.blobMap
    }

    fileprivate func linearBlobConnector(blobs: BlobMap) async throws -> BlobMap {
        guard let frame else { return [:] }

        let connector = LinearBlobConnector(blobMap: blobs,
                                            width: frame.width,
                                            height: frame.height)

        connector.process(scanSize: 25,
                          blobsSmallerThan: 18)

        return connector.blobMap
    }
}
