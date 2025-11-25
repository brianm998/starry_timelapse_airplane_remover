import Foundation
import kht_bridge
import CoreGraphics
import logging
import Cocoa
import SwiftUI
import Semaphore

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// logic for loading different kinds of images

public enum FrameReprocessingType: String, Codable, Equatable, CaseIterable, Sendable {
    case alignment              // redo both alignment and outliers
    case outliers               // redo only outliers
    case horizons               // redo individual horizons
    case allHorizons            // redo all individual horizons
    case none                   // don't redo anything that's already done
}

public enum ImageDisplaySize: Sendable {
    case original
    case preview
    case thumbnail
}

// read and write access to different image types for a given frame
public struct ImageAccessor: Sendable {
    let config: Config
    let frameIndexToBaseNameMap: [Int: String]
    let imageSequence: ImageSequence
    let imageSavedClosure: (@Sendable (Int, PixelatedImage, FrameViewMode, ImageDisplaySize) -> Void)?
    
    public init(
      config: Config,
      imageSequence: ImageSequence,
      frameIndexToBaseNameMap: [Int: String],
      imageSavedClosure: (@Sendable (Int,
                                     PixelatedImage,
                                     FrameViewMode,
                                     ImageDisplaySize
                          ) -> Void
      )? = nil
    ) {
        // the dirname (not full path) of where the main output files will sit
        self.config = config
        self.frameIndexToBaseNameMap = frameIndexToBaseNameMap
        self.imageSequence = imageSequence
        self.imageSavedClosure = imageSavedClosure
        mkdirs()                // XXX called more than needed
    }

    var previewSize: NSSize {
        let previewWidth = config.previewWidth
        let previewHeight = config.previewHeight
        return NSSize(width: previewWidth, height: previewHeight)
    }

    var thumbnailSize: NSSize {
        let thumbnailWidth = config.thumbnailWidth
        let thumbnailHeight = config.thumbnailHeight
        return NSSize(width: thumbnailWidth, height: thumbnailHeight)
    }

    func mkdir(ofType type: FrameViewMode,
               andSize size: ImageDisplaySize = .original) 
    {
        if let dirname = config.dirForImage(ofType: type, atSize: size) {
            StarCore.mkdir(dirname)
        }
    }

    public func dirForImage(ofType type: FrameViewMode, atSize size: ImageDisplaySize) -> String? {
        config.dirForImage(ofType: type, atSize: size)
    }

    private func mkdirs() {
        for dirname in config.allImageDirnames {
            StarCore.mkdir(dirname)
        }
    }

    // load for display as SwiftUI Image
    public func loadImage(
      frameIndex: Int,
      type imageType: FrameViewMode,
      atSize size: ImageDisplaySize
    ) async -> Image? {
        if let filename = nameForImage(
             frameIndex: frameIndex,
             ofType: imageType,
             atSize: size
           ),
           let image = PixelatedImage(filename: filename),
           let nsImage = image.nsImage
        {
            return Image(nsImage: nsImage)
        } else if let image = try? await makeMissingImage(
                    frameIndex: frameIndex,
                    ofType: imageType,
                    andSize: size),
                  let nsImage = image.nsImage
        {
            return Image(nsImage: nsImage)
        } else {
            Log.w("cannot load image of type \(imageType) at size \(size)")
        }
        return nil
    }

    public func urlForImage(frameIndex: Int,
                            ofType imageType: FrameViewMode,
                            atSize size: ImageDisplaySize) -> URL?
    {
        if let filename = nameForImage(frameIndex: frameIndex,
                                       ofType: imageType,
                                       atSize: size)
        {
            if FileManager.default.fileExists(atPath: filename) {
                return URL(fileURLWithPath: filename)
            } else {
                Log.w("file does not exist at \(filename)") // XXX DOH!
            }
        } else {
            Log.w("no filename for type \(imageType) at size \(size)")
        }
        return nil
    }

    public func imageExists(frameIndex: Int,
                            ofType imageType: FrameViewMode,
                            atSize size: ImageDisplaySize) -> Bool
    {
        if let filename = nameForImage(frameIndex: frameIndex,
                                       ofType: imageType,
                                       atSize: size),
           FileManager.default.fileExists(atPath: filename)
        {
            return true
        } else {
            return false
        }
    }

    // load using the file system monitor
    public func loadFinal(
      frameIndex: Int,
      type imageType: FrameViewMode,
      atSize size: ImageDisplaySize
    ) async throws -> PixelatedImage? {
        try await finalFileSystemMonitor.load() {
            await self.loadInt(frameIndex: frameIndex, type: imageType, atSize: size)
        }
    }

    // load using the file system monitor
    public func load(
      frameIndex: Int,
      type imageType: FrameViewMode,
      atSize size: ImageDisplaySize
    ) async throws -> PixelatedImage? {
        try await fileSystemMonitor.load() {
            await self.loadInt(frameIndex: frameIndex, type: imageType, atSize: size)
        }
    }

    public func loadInt(
      frameIndex: Int,
      type imageType: FrameViewMode,
      atSize size: ImageDisplaySize
    ) async -> PixelatedImage? {
        var numRetries = 4
        Log.d("load \(frameIndex) type \(imageType) atSize \(size)")
        while numRetries > 0 {
            do {
                if let filename = nameForImage(frameIndex: frameIndex,
                                               ofType: imageType,
                                               atSize: size)
                {
                    if FileManager.default.fileExists(atPath: filename),
                       let image = try? await imageCache.loadImage(filename: filename)
                    {
                        Log.d("filename \(filename) exists, returning \(image.description)")
                        return image
                    } else {
                        // no file
                        // if this is not a request for an original file, then try
                        // to load the original and rescale it 
                        switch size {
                        case .original:
                            Log.i("file at \(filename) does not exist :(")
                            return nil  // original does not exist, nothing to return
                        default:
                            if let image = try await createMissingImage(
                                 frameIndex: frameIndex,
                                 ofType: imageType,
                                 andSize: size
                               )
                            {
                                Log.d("created filename \(filename), returning \(image.description)")
                                return await imageCache.add(image: image, named: filename)
                            }
                            return nil
                        }
                    }
                } else {
                    Log.w("no filename for type \(imageType) at size \(size)")
                }
            } catch let error as NSError {
                if error.code == -1001 {
                    // The request timed out.
                    // keep trying here
                    numRetries -= 1
                    if numRetries > 0 {
                        Log.w("couldn't load image of type \(imageType) at size \(size): \(error) will try again \(numRetries) more times")
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    } else {
                        Log.e("couldn't load image of type \(imageType) at size \(size): \(error) will try again \(numRetries) more times")
                    }
                } else {
                    Log.e("couldn't load image of type \(imageType) at size \(size): \(error)")
                    numRetries = 0
                }
            } catch {
                numRetries = 0
                Log.e("couldn't load image of type \(imageType) at size \(size): \(error)")
            }
        }
        return nil
    }
    
    // save using the file system monitor
    public func saveFinal(_ image: PixelatedImage,
                          frameIndex: Int,
                          as type: FrameViewMode,
                          atSize size: ImageDisplaySize,
                          overwrite: Bool) async throws
    {
        try await finalFileSystemMonitor.save() {
            await self.saveInt(
              image,
              frameIndex: frameIndex,
              as: type,
              atSize: size,
              overwrite: overwrite
            )
        }
    }
            
    // save using the file system monitor
    public func save(_ image: PixelatedImage,
                     frameIndex: Int,
                     as type: FrameViewMode,
                     atSize size: ImageDisplaySize,
                     overwrite: Bool) async throws
    {
        try await fileSystemMonitor.save() {
            await self.saveInt(
              image,
              frameIndex: frameIndex,
              as: type,
              atSize: size,
              overwrite: overwrite
            )
        }
    }
    
    // make this use the file access guard
    private func saveInt(_ image: PixelatedImage,
                         frameIndex: Int,
                         as type: FrameViewMode,
                         atSize size: ImageDisplaySize,
                         overwrite: Bool) async 
    {
        await Task.detached(priority: .medium) {
            if let filename = nameForImage(frameIndex: frameIndex,
                                           ofType: type,
                                           atSize: size)
            {
                switch size {
                case .original:
                    image.writeTIFFEncoding(toFilename: filename)
                default:
                    // everything but originals gets downscaled and saved as a jpeg
                    if let smallSize = sizeOf(size),
                       let downScaled = image.downScaleTo(
                         width: UInt(smallSize.width),
                         height: UInt(smallSize.height)
                       )
                    {
                        downScaled.saveJpeg(withQuality: 60, filename: filename)
                    }
                    imageSavedClosure?(frameIndex, image, type, size)
                }
            } else {
                Log.w("no place to save image of type \(type) at size \(size)")
            }
        }.value
    }

    public func nameForImage(
      frameIndex: Int,
      ofType type: FrameViewMode,
      atSize size: ImageDisplaySize
    ) -> String? {
        if let (dirname, filename) = dirAndNameForImage(frameIndex: frameIndex,
                                                        ofType: type,
                                                        atSize: size)
        {
            return "\(dirname)/\(filename)"
        }
        return nil
    }

    public func dirAndNameForImage(
      frameIndex: Int,
      ofType type: FrameViewMode,
      atSize size: ImageDisplaySize
    ) -> (String, String)? {
        if let dir = config.dirForImage(ofType: type, atSize: size),
           let baseFileName = frameIndexToBaseNameMap[frameIndex]
        {
            switch size {
            case .original:
                switch type {
                case .subtraction:
                    return (dir, baseFileName)
                case .horizon:
                    return (dir, baseFileName)
                case .mergedHorizon:
                    return (dir, baseFileName)
                case .starAligned:
                    return (dir, baseFileName)
                case .earthAligned:
                    return (dir, baseFileName)
                case .original:
                    return (dir, baseFileName)
                case .processed:
                    return (dir, baseFileName)
                case .validation:
                    return (dir, baseFileName)
                default:
                    return nil  // no full frame images for these other types
                }
            case .preview:
                return (dir, "\(baseFileName).jpg")

            case .thumbnail:
                return (dir, "\(baseFileName).jpg")
            }
        }
        return nil
    }

    private func sizeOf(_ size: ImageDisplaySize) -> NSSize? {
        switch size {
        case .original:
            return nil
        case .preview:
            return previewSize
        case .thumbnail:
            return thumbnailSize
        }
    }

    public func deleteImage(
      frameIndex: Int,
      ofType imageType: FrameViewMode,
      atSize size: ImageDisplaySize
    ) throws {
        if let filename = nameForImage(frameIndex: frameIndex,
                                       ofType: imageType,
                                       atSize: size)
        {
            try FileManager.default.removeItem(atPath: filename)
        }
    }

    // XXX except for original
    public func deleteAllImages(
      frameIndex: Int,
      reprocessingType: FrameReprocessingType
    ) {
        for type in FrameViewMode.allCases {
            switch type {
            case .original:
                break           // don't delete the original images

            case .starAligned:
                if reprocessingType == .alignment {
                    try? deleteImage(frameIndex: frameIndex, ofType: type, atSize: .original)
                    try? deleteImage(frameIndex: frameIndex, ofType: type, atSize: .preview)
                }
                
            case .earthAligned:
                if reprocessingType == .alignment {
                    try? deleteImage(frameIndex: frameIndex, ofType: type, atSize: .original)
                    try? deleteImage(frameIndex: frameIndex, ofType: type, atSize: .preview)
                }
                
            case .subtraction:
                if reprocessingType == .alignment {
                    try? deleteImage(frameIndex: frameIndex, ofType: type, atSize: .original)
                    try? deleteImage(frameIndex: frameIndex, ofType: type, atSize: .preview)
                }

            default:
                try? deleteImage(frameIndex: frameIndex, ofType: type, atSize: .original)
                try? deleteImage(frameIndex: frameIndex, ofType: type, atSize: .preview)
            }
        }
    }
        
    public func makeMissingImage(
      frameIndex: Int,
      ofType type: FrameViewMode,
      andSize size: ImageDisplaySize,
      semaphore: AsyncSemaphore? = nil
    ) async throws -> PixelatedImage? {
        Log.d("start with frame \(frameIndex)")
        if let filename = nameForImage(frameIndex: frameIndex,
                                       ofType: type,
                                       atSize: size),
           let smallerSize = sizeOf(size),
           let fullResImage = try await load(frameIndex: frameIndex,
                                             type: type,
                                             atSize: .original)
        {
            Log.d("loaded 1 for frame \(frameIndex)")

            semaphore?.signal()

            if let scaledImage = fullResImage.downScaleTo(
                 width: UInt(smallerSize.width),
                 height: UInt(smallerSize.height)
               )
            {
                Log.d("loaded 2 for frame \(frameIndex)")
                
                if FileManager.default.fileExists(atPath: filename) {
                    Log.i("overwriting already existing file \(filename)")
                    try FileManager.default.removeItem(atPath: filename)
                }

                // make it 8 bit with scaling

                if let eightBitVersion = scaledImage.ensureEightBit {
                    // write to file
                    eightBitVersion.saveJpeg(withQuality: 50, filename: filename)
                } else {
                    Log.w("Unable to create 8 bit version of scaled image")
                }
                
                return scaledImage
            }
        } else {
            semaphore?.signal()
        }
        Log.d("done with frame \(frameIndex)")
        return nil
    }
    
    private func createMissingImage(
      frameIndex: Int,
      ofType type: FrameViewMode,
      andSize size: ImageDisplaySize
    ) async throws -> PixelatedImage? {
        if let scaledImage = try await makeMissingImage(
             frameIndex: frameIndex,
             ofType: type,
             andSize: size)
        {
            return scaledImage
        } else {
            return nil
        }
    }

    public func writeMissingImages(_ closure: @Sendable @escaping (Int) -> Void) async throws {
        let imageSequenceSize = imageSequence.filenames.count
        if self.imageExists(frameIndex: 0,
                            ofType: .original,
                            atSize: .preview),
           self.imageExists(frameIndex: imageSequenceSize-1,
                            ofType: .original,
                            atSize: .preview),
           self.imageExists(frameIndex: 0,
                            ofType: .original,
                            atSize: .thumbnail),
           self.imageExists(frameIndex: imageSequenceSize-1,
                            ofType: .original,
                            atSize: .thumbnail)
        {
            // nop
        } else {
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                for frameIndex in 0..<imageSequenceSize {
                    guard let filename = self.nameForImage(
                            frameIndex: frameIndex,
                            ofType: .original,
                            atSize: .original
                          ),
                          let previewFilename = self.nameForImage(
                            frameIndex: frameIndex,
                            ofType: .original,
                            atSize: .preview
                          ),
                          let thumbnailFilename = self.nameForImage(
                            frameIndex: frameIndex,
                            ofType: .original,
                            atSize: .thumbnail
                          )
                    else { continue }

                    let previewExists = FileManager.default.fileExists(atPath: previewFilename)
                    let thumbnailExists = FileManager.default.fileExists(atPath: thumbnailFilename)
                    if !previewExists || !thumbnailExists {
                        taskGroup.addTask() { [self] in
                            Log.d("making missing image for frame \(frameIndex)")
                            try await self.writeMissingImages(
                              frameIndex: frameIndex,
                              filename: filename,
                              previewFilename: previewFilename,
                              thumbnailFilename: thumbnailFilename,
                              previewExists: previewExists,
                              thumbnailExists: thumbnailExists
                            )
                            closure(frameIndex)
                            //                            return
                        }
                    } else {
                        closure(frameIndex)
                    }
                }
                try await taskGroup.waitForAll()
            }
        }
    }

    public func writeMissingImages(
      frameIndex: Int,
      filename: String,
      previewFilename: String,
      thumbnailFilename: String,
      previewExists: Bool,
      thumbnailExists: Bool
    ) async throws {
        if let fullResImage = try await load(
             frameIndex: frameIndex,
             type: .original,
             atSize: .original)
        {
            if !previewExists {
                if let previewSize = sizeOf(.preview)
                {
                    if let smallerImage = fullResImage.downScaleTo(
                         width: UInt(previewSize.width),
                         height: UInt(previewSize.height)
                       ),
                       let eightBitVersion = smallerImage.ensureEightBit
                    {
                        eightBitVersion.saveJpeg(
                          withQuality: 50,
                          filename: previewFilename
                        )
                    }
                }
            }

            if !thumbnailExists {
                if let thumbnailSize = sizeOf(.thumbnail)
                {
                    if let smallerImage = fullResImage.downScaleTo(
                         width: UInt(thumbnailSize.width),
                         height: UInt(thumbnailSize.height)
                       ),
                       let eightBitVersion = smallerImage.ensureEightBit
                    {
                        eightBitVersion.saveJpeg(
                          withQuality: 50,
                          filename: thumbnailFilename
                        )
                    }
                }
            }
        }
    }
}
    
