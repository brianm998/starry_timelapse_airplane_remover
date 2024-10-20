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

 chnages:

 - initial check in FullFrameBlobber needs to update
   - losen the ones that are dumped immediately a lot
   - include this checked value as a classification feature for outliers that persist
 - final cruch can be too much
 - try blobbing close ones together sooner, with tigher params, looser ones later after pruning
 
 */

public enum BlobProcessingType {
    case create(() async throws -> BlobMap)
    case save(FrameImageType)
    case frameState(FrameProcessingState)
    case process((BlobMap) async throws -> BlobMap)
    case dimIsolatedBlobRemover(DimIsolatedBlobRemover.Args)
    case isolatedBlobRemover(IsolatedBlobRemover.Args)
    case disconnectedBlobRemover(DisconnectedBlobRemover.Args)
    case linearBlobConnector(LinearBlobConnector.Args)
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

          // align frame, subtract it, sort pixels, then initial blob detection
          .create(findBlobs),

          .save(.blobs),          




          .frameState(.isolatedBlobRemoval1),


          // find really close linear blobs
          // XXX does this really get rid of pixels on the line? (frame 72 fx3-2)
          // may have fixed that, let's see
          .linearBlobConnector(.init(scanSize: 24, 
                                     blobsSmallerThan: 80,
                                     lineBorder: 20)),

          .save(.filter1),
          
          // a first pass at cutting out individual blobs based upon size, brightness
          // or being too close to the bottom

          // XXX sometimes this gets rid of blobs from lines that we want :(
          // XXX maybe do linear analysis first?
          // XXX or use dim isolated blobber instead of this VVV
          .process() { blobs in
              var ret: [UInt16: Blob] = [:]

              for (_, blob) in blobs {
                  /* XXX checked before pixel creation as well
                  if let ignoreLowerPixels = frame.config.ignoreLowerPixels,
                     await blob.boundingBox().min.y + ignoreLowerPixels > frame.height
                  {
                      // too close to the bottom 
                      return nil
                  }
*/
                  // anything this small is noise
                  if await blob.size() <= constants.blobberMinBlobSize { continue }

                  // these blobs are just too dim
                  if await blob.medianIntensity() < constants.blobberMinBlobIntensity { continue }
                  
                  // only keep smaller blobs if they are bright enough
                  if !(await constants.blobberSmallBlobQualifier.allows(blob)) { continue }

                  // this blob has passed these checks, keep it for now
                  ret[blob.id] = blob
              }
              return ret
          },
          .save(.filter2),
          
          // a first pass on dim isolated blob removal
          .dimIsolatedBlobRemover(.init(scanSize: 50,
                                        requiredNeighbors: 2)),
          
          .frameState(.isolatedBlobRemoval2),


          // remove isolated blobs
          .isolatedBlobRemover(.init(minNeighborSize: 6, scanSize: 24)),
          
          .save(.filter3),
          .frameState(.isolatedBlobRemoval3),

          // remove smaller disconected blobs
          .disconnectedBlobRemover(.init(scanSize: 60,
                                         blobsSmallerThan: 18,
                                         requiredNeighbors: 2)),

          .frameState(.smallLinearBlobAbsorbtion),
          
          // find really close linear blobs
          .linearBlobConnector(.init(scanSize: 30,
                                     blobsSmallerThan: 120,
                                     lineBorder: 10)),

          .frameState(.isolatedBlobRemoval4),
          

          .save(.filter4),
  
          // remove larger disconected blobs
          .disconnectedBlobRemover(.init(scanSize: 60,
                                         blobsSmallerThan: 50,
                                         blobsLargerThan: 18,
                                         requiredNeighbors: 2)),
          .frameState(.largerLinearBlobAbsorbtion),


          .frameState(.finalCrunch),

          .isolatedBlobRemover(.init(scanSize: 12,
                                     requiredNeighbors: 1,
                                     minBlobSize: 24)),
        
          .save(.filter5),

          // try to do more line adjustment after removing some isolated blobs
          .linearBlobConnector(.init(scanSize: 20,
                                     blobsSmallerThan: 80)),


          .isolatedBlobRemover(.init(scanSize: 6,
                                     requiredNeighbors: 1,
                                     minBlobSize: 50)),
        
          .save(.filter6),

          // split up blobs 
          .process(applyUserSlices),
        ]
    }

    public func run() async throws -> BlobMap {
        guard let frame else { throw "need frame" }
        var blobMap: BlobMap = [:]
        for step in steps {
            switch step {
            case .create(let method):
                blobMap = try await method()

            case .process(let method):
                blobMap = try await method(blobMap)


            case .linearBlobConnector(let args):
                let connector = await LinearBlobConnector(blobMap: blobMap,
                                                          width: frame.width,
                                                          height: frame.height,
                                                          frameIndex: frame.frameIndex)
                await connector.process(args)
                blobMap = await connector.blobMap()


            case .isolatedBlobRemover(let args):
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
                

            case .disconnectedBlobRemover(let args):
                let remover = await DisconnectedBlobRemover(blobMap: blobMap,
                                                            width: frame.width,
                                                            height: frame.height,
                                                            frameIndex: frame.frameIndex)
                await remover.process(args)
                blobMap = await remover.blobMap()
                

            case .dimIsolatedBlobRemover(let args):
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
                if frame.config.writeOutlierGroupFiles {
                    // save image
                    let fuck = imageType
                    try await frame.saveImages(for: Array(blobMap.values), as: fuck)
                }

            case .frameState(let processingState):
                await frame.set(state: processingState)

            }
            Log.d("frame \(frame.frameIndex) now has \(blobMap.count) blobs")
        }
        return blobMap
    }

    // Mark - internals

    // slice up blobs as directed by the user
    fileprivate func applyUserSlices(_ blobMap: [UInt16:Blob]) async throws -> BlobMap {
        guard let frame else { return [:] }

        var newBlobs: [UInt16:Blob] = blobMap
        
        var maxKey: UInt16 = 0
        
        for slice in await frame.userSlices {
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
    fileprivate func findBlobs() async throws -> BlobMap {
        guard let frame else { return [:] }
        let frameIndex = frame.frameIndex
        let imageAccessor = frame.imageAccessor
        
        var subtractionArray: [UInt16] = []
        var originalImageArray: [UInt16] = []
        var subtractionImage: PixelatedImage?
        do {
            // try to load the image subtraction from a pre-processed file

            if let image = try await imageAccessor.load(type: .subtracted, atSize: .original) {
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

        guard let originalImage = try await imageAccessor.load(type: .original, atSize: .original)
        else { throw "couldn't load original file for finishing" }

        switch originalImage.imageData {
        case .sixteenBit(let array):
            originalImageArray = array
        case .eightBit(_):
            throw "8 bit images are not currently supported by Star, only 16 bit images"
        }
        
        await frame.set(state: .assemblingPixels)

        Log.d("frame \(frameIndex) running blobber")

        let rawOriginalImage = RawPixelData(pixels: originalImageArray,
                                            bytesPerRow: originalImage.bytesPerRow,
                                            bytesPerPixel: originalImage.bytesPerPixel,
                                            width: frame.width,
                                            height: frame.height)
        
        // detect blobs of difference in brightness in the subtraction array
        // airplanes show up as lines or dots in a line
        // because the image subtracted from this frame had the sky aligned,
        // the ground may get moved, and therefore may contain blobs as well.
        let blobber = FullFrameBlobber(config: frame.config,
                                       imageWidth: frame.width,
                                       imageHeight: frame.height,
                                       subtractionPixelData: subtractionArray,
                                       originalImage: rawOriginalImage,
                                       frameIndex: frameIndex,
                                       neighborType: .eight)//.fourCardinal

        blobber.sortPixels()
        
        await frame.set(state: .detectingBlobs)
        
        // run the blobber
        await blobber.process()

        Log.d("frame \(frameIndex) blobber done")

        return blobber.blobMap
    }
    
    // re-run something repeatedly
    fileprivate func iterate(closure: (Bool) async -> Int, max: Int = 8) async {

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
