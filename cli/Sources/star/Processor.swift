import Foundation
import StarCore
import CoreGraphics
import logging
import Semaphore
import Cocoa

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
    }

    public var frameCount: Int {
        get async {
            await imageSequence.frameCount
        }
    }
    
    public func process() async throws {
        await frameGraphBuilder.set(configManager: configManager)

        let filenames = await imageSequence.filenames
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
              writeOutputFiles: true,
              imageAccessor: imageAccessor
            )
            Log.d("loaded frame at frameIndex \(frameIndex)")
            frames.append(frame)
        }

        await doublyLink(frames: frames)
        
        let semaphore = AsyncSemaphore(value: 0) 
        
        await frameGraphBuilder.build(
          frames: frames
        ) { errorList in
            if errorList.count == 0 {
                // success
                Log.d("success")
            } else {
                for error in errorList {
                    Log.e("ERROR: \(error)")
                }
            }
            semaphore.signal()
        } errorClosure: { errorString in
            // logged above
        }

        await semaphore.wait()
    }
}
