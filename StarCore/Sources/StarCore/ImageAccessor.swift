import Foundation
import kht_bridge
import ShellOut
import CoreGraphics
import logging
import Cocoa
import SwiftUI


/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// logic for loading different kinds of images

public enum ImageDisplaySize: Sendable {
    case original
    case preview
    case thumbnail
}


public protocol ImageAccess: Sendable {
    // does this image exist?
    func imageExists(ofType imageType: FrameViewMode,
                     atSize size: ImageDisplaySize) -> Bool

    // save image, will rescale and jpeg if necessary
    func save(_ image: PixelatedImage,
              as type: FrameViewMode,
              atSize size: ImageDisplaySize,
              overwrite: Bool) async throws

    // load an image of some type and size
    func load(type imageType: FrameViewMode,
              atSize size: ImageDisplaySize) async throws -> PixelatedImage?

    func saveFinal(_ image: PixelatedImage,
                   as type: FrameViewMode,
                   atSize size: ImageDisplaySize,
                   overwrite: Bool) async throws

    // load an image of some type and size
    func loadFinal(type imageType: FrameViewMode,
                   atSize size: ImageDisplaySize) async throws -> PixelatedImage?

    // load an image of some type and size for the GUI as a SwiftUI Image
    func loadImage(type imageType: FrameViewMode,
                   atSize size: ImageDisplaySize) async -> Image?

    // bypass loading restrictions
    func loadInt(type imageType: FrameViewMode,
                 atSize size: ImageDisplaySize) async -> PixelatedImage?

    func dirForImage(ofType type: FrameViewMode,
                     atSize size: ImageDisplaySize) -> String?

    func urlForImage(ofType imageType: FrameViewMode,
                     atSize size: ImageDisplaySize) -> URL?

    func writeMissingImage(ofType type: FrameViewMode,
                           andSize size: ImageDisplaySize) async throws

    func deleteImage(ofType imageType: FrameViewMode,
                     atSize size: ImageDisplaySize) throws

    func dirAndNameForImage(ofType type: FrameViewMode,
                            atSize size: ImageDisplaySize) -> (String, String)?
    
    func deleteAllImages()

}

// read and write access to different image types for a given frame
public struct ImageAccessor: ImageAccess, Sendable {
    let config: Config
    let baseFileName: String
    let imageSequence: ImageSequence
    let imageSavedClosure: (@Sendable (PixelatedImage, FrameViewMode, ImageDisplaySize) -> Void)?
    
    public init(config: Config,
                imageSequence: ImageSequence,
                baseFileName: String,
                imageSavedClosure: (@Sendable (PixelatedImage, FrameViewMode, ImageDisplaySize) -> Void)? = nil)
    {
        // the dirname (not full path) of where the main output files will sit
        self.config = config
        self.baseFileName = baseFileName
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

    public func loadImage(type imageType: FrameViewMode,
                          atSize size: ImageDisplaySize) async -> Image?
    {
        if let url = urlForImage(ofType: imageType, atSize: size),
           let image = NSImage(contentsOf: url)
        {
            return Image(nsImage: image)
        } else if let image = try? await makeMissingImage(ofType: imageType, andSize: size) {
            return Image(nsImage: image)
        } else {
            Log.w("cannot load image of type \(imageType) at size \(size)")
        }
        return nil
    }

    public func urlForImage(ofType imageType: FrameViewMode,
                            atSize size: ImageDisplaySize) -> URL?
    {
        if let filename = nameForImage(ofType: imageType, atSize: size) {
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

    public func imageExists(ofType imageType: FrameViewMode,
                            atSize size: ImageDisplaySize) -> Bool
    {
        if let filename = nameForImage(ofType: imageType, atSize: size),
           FileManager.default.fileExists(atPath: filename)
        {
            return true
        } else {
            return false
        }
    }

    // load using the file system monitor
    public func loadFinal(type imageType: FrameViewMode,
                          atSize size: ImageDisplaySize) async throws -> PixelatedImage?
    {
        try await finalFileSystemMonitor.load() { await self.loadInt(type: imageType, atSize: size) }
    }

    // load using the file system monitor
    public func load(type imageType: FrameViewMode,
                     atSize size: ImageDisplaySize) async throws -> PixelatedImage?
    {
        try await fileSystemMonitor.load() { await self.loadInt(type: imageType, atSize: size) }
    }

    public func loadInt(type imageType: FrameViewMode,
                         atSize size: ImageDisplaySize) async -> PixelatedImage?
    {
        var numRetries = 4

        while numRetries > 0 {
            do {
                if let filename = nameForImage(ofType: imageType, atSize: size) {
                    if FileManager.default.fileExists(atPath: filename) {
                        return try await imageSequence.getImage(withName: filename).image()
                        //return try await PixelatedImage(fromFile: filename)
                    } else {
                        // no file
                        // if this is not a request for an original file, then try
                        // to load the original and rescale it 
                        switch size {
                        case .original:
                            return nil  // original does not exist, nothing to return
                        default:
                            return try await createMissingImage(ofType: imageType, andSize: size)
                        }
                    }
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
                          as type: FrameViewMode,
                          atSize size: ImageDisplaySize,
                          overwrite: Bool) async throws
    {
        try await finalFileSystemMonitor.save() {
          try await self.saveInt(image,
                                 as: type,
                                 atSize: size,
                                 overwrite: overwrite)
        }
    }
            
    // save using the file system monitor
    public func save(_ image: PixelatedImage,
                     as type: FrameViewMode,
                     atSize size: ImageDisplaySize,
                     overwrite: Bool) async throws
    {
        try await fileSystemMonitor.save() {
          try await self.saveInt(image,
                                 as: type,
                                 atSize: size,
                                 overwrite: overwrite)
        }
    }
            
    // make this use the file access guard
    private func saveInt(_ image: PixelatedImage,
                         as type: FrameViewMode,
                         atSize size: ImageDisplaySize,
                         overwrite: Bool) async throws
    {
        if let filename = nameForImage(ofType: type, atSize: size) {
            var dataToSave: Data? = nil
            switch size {
            case .original:
                try image.writeTIFFEncoding(toFilename: filename)
            case .preview:
                dataToSave = image.nsImage(ofSize: previewSize)?.jpegData
            case .thumbnail:
                dataToSave = image.nsImage(ofSize: thumbnailSize)?.jpegData
            }
            if let dataToSave = dataToSave {
                // only used for previews and thumbnails
                var canCreate = true
                if FileManager.default.fileExists(atPath: filename) {
                    if overwrite {
                        Log.i("overwriting already existing file \(filename)")
                        try FileManager.default.removeItem(atPath: filename)
                    } else {
                        Log.i("not overwriting already existing file \(filename)")
                        canCreate = false
                    }
                }

                if canCreate {
                    // write to file
                    FileManager.default.createFile(atPath: filename,
                                                   contents: dataToSave,
                                                   attributes: nil)

                    // callback to tell what has changed
                    imageSavedClosure?(image, type, size)
                }
            }
        } else {
            Log.w("no place to save image of type \(type) at size \(size)")
        }
    }

    private func nameForImage(ofType type: FrameViewMode,
                                          atSize size: ImageDisplaySize) -> String?
    {
        if let (dirname, filename) = dirAndNameForImage(ofType: type, atSize: size) {
            return "\(dirname)/\(filename)"
        }
        return nil
    }

    public func dirAndNameForImage(ofType type: FrameViewMode,
                                                atSize size: ImageDisplaySize) -> (String, String)?
    {
        if let dir = config.dirForImage(ofType: type, atSize: size) {
            switch size {
            case .original:
                switch type {
                case .subtraction:
                    return (dir, baseFileName)
                case .aligned:
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

    public func deleteImage(ofType imageType: FrameViewMode,
                            atSize size: ImageDisplaySize) throws
    {
        if let filename = nameForImage(ofType: imageType, atSize: size) {
            try FileManager.default.removeItem(atPath: filename)
        }
    }

  public func deleteAllImages() {    // XXX except for original
        for type in FrameViewMode.allCases {
            switch type {
            case .original:
                break           // don't delete the orignal images

            default:
                try? deleteImage(ofType: type, atSize: .original)
                try? deleteImage(ofType: type, atSize: .preview)
            }
        }
    }
    
    public func writeMissingImage(ofType type: FrameViewMode,
                                  andSize size: ImageDisplaySize) async throws
    {
        _ = try await makeMissingImage(ofType: type, andSize: size)
    }
    
    public func makeMissingImage(ofType type: FrameViewMode,
                                  andSize size: ImageDisplaySize) async throws -> NSImage?
    {
        if let filename = nameForImage(ofType: type, atSize: size),
           let smallerSize = sizeOf(size),
           let fullResImage = try await load(type: type, atSize: .original),
           let scaledImageData = fullResImage.nsImage(ofSize: smallerSize)
        {
            let dataToSave = scaledImageData.jpegData
            
            if FileManager.default.fileExists(atPath: filename) {
                Log.i("overwriting already existing file \(filename)")
                try FileManager.default.removeItem(atPath: filename)
            }

            // write to file
            FileManager.default.createFile(atPath: filename,
                                           contents: dataToSave,
                                           attributes: nil)

            return scaledImageData
        }
        return nil
    }
    
    private func createMissingImage(ofType type: FrameViewMode,
                                    andSize size: ImageDisplaySize)
      async throws -> PixelatedImage?
    {
        if let scaledImageData = try await makeMissingImage(ofType: type, andSize: size) {
            if let cgImage = scaledImageData.cgImage(forProposedRect: nil,
                                                     context: nil,
                                                     hints: nil)
            {
                return PixelatedImage(cgImage)
            }
        }
        return nil
    }

    
}
