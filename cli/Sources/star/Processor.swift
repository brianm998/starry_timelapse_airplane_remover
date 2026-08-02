import Foundation
import StarCore
import logging
import Semaphore

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/


public class Processor {
    public let configManager: ConfigManager
    public let callbacks: Callbacks
    public let imageSequence: ImageSequence    // the sequence of images that we're processing
    
    public init(with configManager: ConfigManager,
                callbacks: Callbacks,
                maxResidentImages: Int? = nil
    ) async throws {
        self.configManager = configManager
        self.callbacks = callbacks
        
        let config = await configManager.config()

        let imageSequenceDirname = "\(config.imageSequencePath)/\(config.imageSequenceDirname)"
        //self.outputDirname = "\(config.outputPath)/\(basename)"
        self.imageSequence = try ImageSequence(
          dirname: imageSequenceDirname,
          supportedImageFileTypes: config.supportedImageFileTypes,
          maxImages: maxResidentImages
        )

        let imageInfo = try await imageSequence.getImageInfo()

        // still needed by the decision trees :(
        IMAGE_WIDTH = Double(imageInfo.imageWidth)
        IMAGE_HEIGHT = Double(imageInfo.imageHeight)

        // Everything else reads image sizes from the config, and the memory gating
        // is useless without them: FrameGraphBuilder.build computes rawImageBytes
        // from config.imageWidth/Height/BytesPerPixel, so leaving them at 0 makes
        // every op's estimatedMemoryBytes 0 (AsyncOperation skips reserve() entirely)
        // and drops the keypoint limiter back to numberOfFramesToProcessConcurrently.
        var updatedConfig = await configManager.config()
        updatedConfig.set(imageInfo: imageInfo)
        await configManager.update(updatedConfig)
    }

    public var frameCount: Int {
        get async {
            await imageSequence.frameCount
        }
    }
    
    /// - Parameter endIndex: the last frame index to write output for, inclusive; nil
    ///   processes the whole sequence.  Frames past it are still aligned where a
    ///   processed frame needs them as a neighbour — see `FrameGraphRange`.
    ///
    /// - Returns: the errors the frame graph collected, empty when everything succeeded.
    ///
    ///   Returned rather than thrown because these are per-frame failures in a run that may
    ///   have produced perfectly good output for every other frame; throwing would discard
    ///   that distinction and the partial results with it.  It is the caller's job to decide
    ///   what a non-empty list means — for the cli, it means a non-zero exit and keeping the
    ///   temp directory so the run can be resumed.
    ///
    ///   Before this returned anything, the errors were logged here and nowhere else, so a
    ///   run that failed on every frame still exited 0 and looked like a success to anything
    ///   scripting it.
    @discardableResult
    public func process(endIndex: Int? = nil) async throws -> [String] {
        await frameGraphBuilder.set(configManager: configManager)

        let filenames = await imageSequence.filenames

        // Failures are per-run, and the gui and daemon keep one process across several
        // sequences, so start from a clean slate rather than inheriting the last run's.
        await OutputWriteFailures.shared.reset()

        // Before any work: warn if this run plainly will not fit on the output volume.
        // Cheap (one stat per input file) and the alternative is finding out an hour in.
        // `ImageSequence.filenames` are already full paths.
        await DiskSpaceCheck.check(inputFiles: filenames,
                                   outputPath: await configManager.config().outputPath)
        var frameIndexToBaseNameMap: [Int: String] = [:]

        for (frameIndex, filename) in filenames.enumerated() {
            frameIndexToBaseNameMap[frameIndex] = removePath(fromString: filename)
        }

        let config = await configManager.config()
        let imageAccessor = ImageAccessor(
          config: config,
          imageSequence: imageSequence,
          frameIndexToBaseNameMap: frameIndexToBaseNameMap
        ) { [weak self] image, frameIndex, type, size in
            Task { @MainActor in
                Log.d("frame \(frameIndex) saved image of type \(type) at size \(size)")
//                self?.frames[frameIndex].saved(image: image, ofType: type, atSize: size)
            }
        }

        let imageInfo = try await imageSequence.getImageInfo()

        var frames: [FrameAirplaneRemover] = []
        
        await frameGraphBuilder.set(configManager: configManager)
        
        for (frameIndex, filename) in filenames.enumerated() {

            Log.d("add task at frameIndex \(frameIndex)")
            let basename = removePath(fromString: filename)
            let frame = try await FrameAirplaneRemover(
              with: configManager,
              initialConfig: config,
              width: imageInfo.imageWidth,
              height: imageInfo.imageHeight,
              componentsPerPixel: imageInfo.componentsPerPixel,
              callbacks: callbacks,
              imageSequence: imageSequence,
              atIndex: frameIndex,
              outputFilename: "\(config.outputPath)/\(config.basename)",
              baseName: basename,
              // false is --skip-output-files: finishAuto/finishSelective write the
              // outlier data and then return before rendering.  The gui passes a literal
              // true instead, since it has no such flag and exists to produce output.
              writeOutputFiles: config.writeOutputFiles,
              imageAccessor: imageAccessor
            )
            Log.d("loaded frame at frameIndex \(frameIndex)")
            frames.append(frame)
        }

        await doublyLink(frames: frames)
        
        let semaphore = AsyncSemaphore(value: 0)
        let collected = ArrayActor<String>([])

        await frameGraphBuilder.build(
          frames: frames,
          endIndex: endIndex
        ) { errorList in
            if errorList.count == 0 {
                // success
                Log.d("success")
            } else {
                for error in errorList {
                    Log.e("ERROR: \(error)")
                }
            }
            // Hand them back to the caller as well as logging them. The completion closure is
            // not async, so this hops through a Task and the signal has to happen after the
            // store — otherwise `process` can return before the errors have been recorded and
            // a failed run reports success, which is the exact bug being fixed.
            Task {
                for error in errorList { await collected.append(error) }
                semaphore.signal()
            }
        } errorClosure: { errorString in
            // logged above
        }

        await semaphore.wait()

        // Output frames star could not write count as run errors too. They come from a
        // different place than the frame graph's — the save path, not an operation — so they
        // have to be joined here rather than arriving in `errorList`.
        return await collected.elements() + OutputWriteFailures.shared.descriptions()
    }
}
