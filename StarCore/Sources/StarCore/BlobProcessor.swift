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

public enum BlobProcessingType {
    case initiate(() async throws -> ([UInt16], PixelatedImage)) // subtraction image and original image
    case create(([UInt16], PixelatedImage) async throws -> BlobMap)
    case save(FrameViewMode)
    case frameState(FrameProcessingState)
    case processWithOriginalImage((BlobMap,PixelatedImage) async throws -> BlobMap)
    case process((BlobMap) async throws -> BlobMap)
    case dimIsolatedBlobRemover(DimIsolatedBlobRemover.Args)
    case isolatedBlobRemover(IsolatedBlobRemover.Args)
    case disconnectedBlobRemover(DisconnectedBlobRemover.Args)
    case linearBlobConnector(LinearBlobConnector.Args)
    case blobLineTrim(BlobLineTrim.Args)
    case borderBrightnessLessThan(Double)
    case lineSplit(BlobLineSplitter.Args)
    case blobDupeCheck(String)
    case smallBlobRemover(SmallBlobRemover.Args)
}

// load and process all blobs for a frame, using a defined sequence of steps
public class BlobProcessor {

    weak var frame: FrameAirplaneRemover?
    fileprivate var steps: [BlobProcessingType] = []

    public init(frame: FrameAirplaneRemover) {
        self.frame = frame

        /*

         Next steps after moving border brightness outside of the FullFrameBlobber
         and into a new OutlierGroup classification feature:


         develop a working lineTrim() method for Blobs

         use things like line length, median distance from line, etc
         to figure out if line based trimming makes sense for each blob

         if the percentage of blobs anywhere the line is low, then don't touch it

         if there is a calculated line which goes very close to more than half
         of the pixels, then remove the farthest 10% that are more than X pixels
         from the line, then iterate again by re-calculating the line and trying again

         Keep track of all of these removed pixels, and try to see if there is another
         line to be found within.  Can help for cases with airplanes close to horizon



         
         use linear blob connector on larger blobs like before
         
         */

        

        
        /*
         Outlier Detection Logic is defined by the following set of steps

         starting with:
         
          - align neighboring frame
          - subtract aligned frame from this frame
          - sort pixels on subtracted frame by intensity
          - detect blobs from sorted pixels

          with lots of steps in the middle to refine the list of blobs

          ending with:
          
          - save image of final blobs before promotion to outlier groups
          - promote remaining blobs to outlier groups for further analysis
         */
        
        self.steps = [
          // align neighbor frame, subtract it, sort pixels
          .initiate(setup),
        
          // create the first blobs from subtraction image
          .create(findBlobs),

          // check to see if any pixel is in more than one blob
          //.blobDupeCheck("init"),

          .save(.blobs),          

          .frameState(.filter1),


          // find really close linear blobs
          .linearBlobConnector(.init(scanSize: 32, 
                                     blobsSmallerThan: 120,
                                     lineBorder: 12)),


          .save(.filter1),

          .frameState(.filter2),

          .borderBrightnessLessThan(0.4),

          .save(.filter2),

          .frameState(.filter3),
          
          // a first pass at cutting out individual blobs based upon size, brightness
          // or being too close to the bottom
          .process() { blobs in
              var ret: [UInt16: Blob] = [:]

              for (_, blob) in blobs {
                  // anything this small is noise
                  if await blob.size() <= constants.blobberMinBlobSize {
                      //Log.d("frame \(frame.frameIndex) dumping blob \(blob) of size \(await blob.size()) <= \(constants.blobberMinBlobSize)")
                      continue
                  }

                  // these blobs are just too dim
                  if await blob.medianIntensity() < constants.blobberMinBlobIntensity {
                      Log.d("frame \(frame.frameIndex) dumping blob \(blob) of median intensity \(await blob.medianIntensity()) <= \(constants.blobberMinBlobIntensity)")
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
          },
          .save(.filter3),
          
          .frameState(.filter4),
          // a first pass on dim isolated blob removal
          .dimIsolatedBlobRemover(.init(scanSize: 20,
                                        requiredNeighbors: 2,
                                        intensityFloor: 5000)),
          
          .save(.filter4),
          .frameState(.filter5),

          // remove isolated blobs
          .isolatedBlobRemover(.init(minNeighborSize: 4, scanSize: 24)),
          
          .save(.filter5),
          .frameState(.filter6),
          
          // remove smaller disconected blobs
          .disconnectedBlobRemover(.init(scanSize: 30,
                                         blobsSmallerThan: 18,
                                         requiredNeighbors: 2)),
          
          // find really close linear blobs
          .linearBlobConnector(.init(scanSize: 20,
                                     blobsSmallerThan: 120,
                                     lineBorder: 10)),

          .save(.filter6),

          .frameState(.filter7),

          // remove larger disconected blobs
          .disconnectedBlobRemover(.init(scanSize: 30,
                                         blobsSmallerThan: 50,
                                         blobsLargerThan: 18,
                                         requiredNeighbors: 2)),
          .save(.filter7),
          .frameState(.filter8),
          
          .isolatedBlobRemover(.init(scanSize: 12,
                                     requiredNeighbors: 1,
                                     minBlobSize: 24)),
        
          .save(.filter8),
          .frameState(.filter9),

          // try to do more line adjustment after removing some isolated blobs
          .linearBlobConnector(.init(scanSize: 20,
                                     blobsSmallerThan: 200)),


          .save(.filter9),
          .frameState(.filter10),
          
          
          // pass on getting rid of small dim blobs
          .smallBlobRemover(.init(minBlobSize: 24,
                                  intensityFloor: 5000)),


          .save(.filter10),
          .frameState(.filter11),

          .isolatedBlobRemover(.init(scanSize: 16,
                                     requiredNeighbors: 1,
                                     minBlobSize: 50)),

          .save(.filter11),
          .frameState(.filter12),

          // try to split up blobs with more than one line in them

          // this appears to be slow
          .lineSplit(.init(minAvgDistance: 5,
                           maxLineFillAmount: 0.5,
                           minBlobsize: 500,
                           maxLines: 8000,
                           maxDistance: 12,
                           minLineScore: 12,
                           minLineCount: 10)),


          // blob line trim
          .blobLineTrim(.init(minLineLength: 65,
                              minLineFillAmount: 0.9,
                              trimAmount: 16)),


          .save(.filter12),
          .frameState(.filter13),
          
          // reconnect some lines that may have been split up
          .linearBlobConnector(.init(scanSize: 40, 
                                     blobsSmallerThan: 180,
                                     lineBorder: 2)),
          
          // pass on getting rid of small but larger, dimmer blobs
          // XXX this needs to take into account distance from others, it's killing us
          //.smallBlobRemover(.init(minBlobSize: 50,
          //intensityFloor: 7500)),
          .dimIsolatedBlobRemover(.init(scanSize: 50,
                                        requiredNeighbors: 2,
                                        minBlobSize: 50,
                                        intensityFloor: 4500)),

          .save(.filter13),
          .frameState(.filter14),

          .isolatedBlobRemover(.init(scanSize: 40,
                                     requiredNeighbors: 2,
                                     minBlobSize: 8)),
        
          // pass on getting rid of small but larger, dimmer blobs
          //.smallBlobRemover(.init(minBlobSize: 10)),

          .save(.filter14),
          .frameState(.filter15),


          // a final pass at isolated removal
          .isolatedBlobRemover(.init(scanSize: 36,
                                     requiredNeighbors: 2,
                                     minBlobSize: 30)),
          
          
          // split up blobs based upon user input
          .process(applyUserSlices),

          .save(.filter15),
          .frameState(.filter16),
          
          // any really big blobs with lots of small bunches that are dim can go away
          .process() { blobs in
              var ret: [UInt16: Blob] = [:]

              for (_, blob) in blobs {
                  let blobSize = await blob.size()

                  if blobSize > 1000,
                     await blob.bunchCount() > 100,
                     await blob.medianBunchSize() < 10,
                     await blob.medianIntensity() < 6000
                  {
                      Log.d("frame \(frame.frameIndex) dumping blob \(blob) of size \(blobSize) bunch count \(await blob.bunchCount()) medianBunchSize \(await blob.medianBunchSize()) medianIntensity \(await blob.medianIntensity())")
                      // try processing this further by getting rid of dim blobs?
                      // for now just kick it out
                      await blob.removePixels(dimmerThan: 6000)
                      ret[blob.id] = blob
                  } else {
                      ret[blob.id] = blob
                  }
              }
              return ret
          },

          // check to see if any pixel is in more than one blob
          //.blobDupeCheck("end"),

          .save(.filter16),
        ]
    }

    // runs each step in sequence and returns the result
    public func run() async throws -> BlobMap {
        guard let frame else { throw "need frame" }
        var blobMap: BlobMap = [:]

        var subtractionArray: [UInt16]?
        var originalImage: PixelatedImage?

        /*

         refactor this to pass not a blop map to each step,
         but instead give the analyzer.

         avoid re-creating the analyzer's blob refs at each step,
         instead force each step to use the analyzer if it wants to modify
         the blob map in any way.

         Hopefully this will make things faster, right now the blob filter steps are slow

         actually, this step takes less than 0.2 seconds each time, never mind
         
         */
        
        for step in steps {
            switch step {
            case .initiate(let method):
                (subtractionArray, originalImage) = try await method()

            case .create(let method):
                blobMap = try await method(subtractionArray!, originalImage!)

            case .process(let method):
                blobMap = try await method(blobMap)

            case .processWithOriginalImage(let method):
                blobMap = try await method(blobMap, originalImage!)

            case .smallBlobRemover(let args): // no analyzer
                let remover = SmallBlobRemover(blobMap: blobMap,
                                               frameIndex: frame.frameIndex)

                await remover.process(args)
                blobMap = await remover.blobMap()
                
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

                
            case .borderBrightnessLessThan(let amount): // no analyzer
                var ret: [UInt16: Blob] = [:]
                for (_, blob) in blobMap {
                    let medianIntensity = await blob.medianIntensity()
                    if await originalImage!.borderBrightness(of: blob.pixels) < amount ||
                       medianIntensity > 10000 // XXX constant
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

    // slice up blobs as directed by the user
    fileprivate func applyUserSlices(_ blobMap: [UInt16:Blob]) async throws -> BlobMap {
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

    fileprivate func setup() async throws -> ([UInt16], PixelatedImage) {
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

    fileprivate func findBlobs(subtractionArray: [UInt16], originalImage: PixelatedImage) async throws -> BlobMap {
        guard let frame else { fatalError("need frame") } // XXX ???
        
        // detect blobs of difference in brightness in the subtraction array
        // airplanes show up as lines or dots in a line
        // because the image subtracted from this frame had the sky aligned,
        // the ground may get moved, and therefore may contain blobs as well.
        let blobber = FullFrameBlobber(config: await frame.configManager.config(),
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

public func nextIndex(from blobMap: [UInt16:Blob]) -> UInt16? {
    for i in 1..<UInt16.max {
        if blobMap[i] == nil {
            return i
        }
    }
    return nil
}
