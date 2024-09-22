import Foundation
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

public enum FrameImageType: Sendable {
    case original       // original image
    case aligned        // aligned neighbor frame
    case subtracted     // result of subtracting the aligned neighbor from original frame
    case blobs          // full results of the initial blog detection
    case filter1        // 
    case filter2        // 
    case filter3        // 
    case filter4        // 
    case filter5        // 
    case filter6        // 
    case validated      // outlier group validation image
    case paintMask      // layer mask used in painting
    case processed      // final processed image
}

public protocol ImageAccess: Sendable {
    // save image, will rescale and jpeg if necessary
    func save(_ image: PixelatedImage,
              as type: FrameImageType,
              atSize size: ImageDisplaySize,
              overwrite: Bool) async throws

    // load an image of some type and size
    func load(type imageType: FrameImageType,
              atSize size: ImageDisplaySize) async -> PixelatedImage?

    func urlForImage(ofType imageType: FrameImageType,
                     atSize size: ImageDisplaySize) -> URL?
    
    // load an image of some type and size
    func loadNSImage(type imageType: FrameImageType,
                     atSize size: ImageDisplaySize) -> NSImage?
    
    // load an image of some type and size
    func loadImage(type imageType: FrameImageType,
                   atSize size: ImageDisplaySize) -> Image?
    
    // where to load or save this type of image from
    func dirForImage(ofType type: FrameImageType,
                     atSize size: ImageDisplaySize) -> String?

    func nameForImage(ofType type: FrameImageType,
                      atSize size: ImageDisplaySize) -> String?

    func imageExists(ofType type: FrameImageType,
                      atSize size: ImageDisplaySize) -> Bool
    
    func mkdirs() throws
}

// read and write access to different image types for a given frame
public struct ImageAccessor: ImageAccess, @unchecked Sendable {
    let config: Config
    let baseDirName: String
    let baseFileName: String
    let imageSequence: ImageSequence

    public init(config: Config, imageSequence: ImageSequence, baseFileName: String) {
        // the dirname (not full path) of where the main output files will sit
        self.config = config
        self.baseDirName = config.basename
        self.baseFileName = baseFileName
        self.imageSequence = imageSequence
        mkdirs()
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

    func mkdir(ofType type: FrameImageType,
               andSize size: ImageDisplaySize = .original) 
    {
        if let dirname = dirForImage(ofType: type, atSize: size) {
            StarCore.mkdir(dirname)
        }
    }
    
    public func mkdirs() {
        mkdir(ofType: .aligned)
        mkdir(ofType: .subtracted)
        mkdir(ofType: .blobs)
        mkdir(ofType: .filter1)
        mkdir(ofType: .filter2)
        mkdir(ofType: .filter3)
        mkdir(ofType: .filter4)
        mkdir(ofType: .filter5)
        mkdir(ofType: .filter6)
        mkdir(ofType: .paintMask)
        mkdir(ofType: .validated)
        mkdir(ofType: .processed)
        
        if config.writeFramePreviewFiles {
            mkdir(ofType: .original, andSize: .preview)
            mkdir(ofType: .aligned, andSize: .preview)
            mkdir(ofType: .subtracted, andSize: .preview)
            mkdir(ofType: .validated, andSize: .preview)
            mkdir(ofType: .blobs, andSize: .preview)
            mkdir(ofType: .filter1, andSize: .preview)
            mkdir(ofType: .filter2, andSize: .preview)
            mkdir(ofType: .filter3, andSize: .preview)
            mkdir(ofType: .filter4, andSize: .preview)
            mkdir(ofType: .filter5, andSize: .preview)
            mkdir(ofType: .filter6, andSize: .preview)
            mkdir(ofType: .paintMask, andSize: .preview)
        }
        if config.writeFrameThumbnailFiles {
            mkdir(ofType: .original, andSize: .thumbnail)
        }
        if config.writeFrameProcessedPreviewFiles {
            mkdir(ofType: .processed, andSize: .preview)
        }
    }

    public func loadImage(type imageType: FrameImageType,
                          atSize size: ImageDisplaySize) -> Image?
    {
        if let url = urlForImage(ofType: imageType, atSize: size) {
            if let image = NSImage(contentsOf: url) {
                return Image(nsImage: image)
            } else {
                Log.w("cannot create image from url \(url)")
            }
        } else {
            Log.w("cannot get url for image")
        }
        return nil
    }

    public func loadNSImage(type imageType: FrameImageType,
                            atSize size: ImageDisplaySize) -> NSImage?
    {
        if let url = urlForImage(ofType: imageType, atSize: size),
           let image = NSImage(contentsOf: url)
        {
            return image
        }
        return nil
    }

    public func urlForImage(ofType imageType: FrameImageType,
                            atSize size: ImageDisplaySize) -> URL?
    {
        if let filename = nameForImage(ofType: imageType, atSize: size) {
            if fileManager.fileExists(atPath: filename) {
                return URL(fileURLWithPath: filename)
            } else {
                Log.w("file does not exist at \(filename)")
            }
        } else {
            Log.w("no filename for type \(imageType) at size \(size)")
        }
        return nil
    }

    public func load(type imageType: FrameImageType,
                     atSize size: ImageDisplaySize) async -> PixelatedImage?
    {
        var numRetries = 4

        while numRetries > 0 {
            do {
                if let filename = nameForImage(ofType: imageType, atSize: size) {
                    if fileManager.fileExists(atPath: filename) {
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

    public func save(_ image: PixelatedImage,
                     as type: FrameImageType,
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
                if fileManager.fileExists(atPath: filename) {
                    if overwrite {
                        Log.i("overwriting already existing file \(filename)")
                        try fileManager.removeItem(atPath: filename)
                    } else {
                        Log.i("not overwriting already existing file \(filename)")
                        canCreate = false
                    }
                }

                if canCreate {
                    // write to file
                    fileManager.createFile(atPath: filename,
                                           contents: dataToSave,
                                           attributes: nil)
                }
            }
        } else {
            Log.w("no place to save image of type \(type) at size \(size)")
        }
    }

    public func dirForImage(ofType type: FrameImageType,
                         atSize size: ImageDisplaySize) -> String?
    {
        switch type {
        case .original:
            switch size {
            case .original:
                return "\(config.imageSequencePath)/\(config.imageSequenceDirname)"
            case .preview:
                return "\(config.outputPath)/\(baseDirName)-previews"
            case .thumbnail:
                return "\(config.outputPath)/\(baseDirName)-thumbnails"
            }
        case .aligned:
            switch size {
            case .original:
                return "\(config.outputPath)/\(config.imageSequenceDirname)-star-aligned"

            case .preview:
                return "\(config.outputPath)/\(config.imageSequenceDirname)-star-aligned-previews"
            case .thumbnail:
                return nil
            }
        case .subtracted:
            switch size {
            case .original:
                return "\(config.outputPath)/\(config.imageSequenceDirname)-star-aligned-subtracted"
            case .preview:
                return "\(config.outputPath)/\(config.imageSequenceDirname)-star-aligned-subtracted-previews"
            case .thumbnail:
                return nil
            }
        case .blobs:
            switch size {
            case .original:
                return "\(config.outputPath)/\(baseDirName)-blobs"
            case .preview:
                return "\(config.outputPath)/\(baseDirName)-blobs-preview"
            case .thumbnail:
                return nil
            }
        case .filter1:
            switch size {
            case .original:
                return "\(config.outputPath)/\(baseDirName)-blobs-filter1"
            case .preview:
                return "\(config.outputPath)/\(baseDirName)-blobs-filter1-preview"
            case .thumbnail:
                return nil
            }
        case .filter2:
            switch size {
            case .original:
                return "\(config.outputPath)/\(baseDirName)-blobs-filter2"
            case .preview:
                return "\(config.outputPath)/\(baseDirName)-blobs-filter2-preview"
            case .thumbnail:
                return nil
            }
        case .filter3:
            switch size {
            case .original:
                return "\(config.outputPath)/\(baseDirName)-blobs-filter3"
            case .preview:
                return "\(config.outputPath)/\(baseDirName)-blobs-filter3-preview"
            case .thumbnail:
                return nil
            }
        case .filter4:
            switch size {
            case .original:
                return "\(config.outputPath)/\(baseDirName)-blobs-filter4"
            case .preview:
                return "\(config.outputPath)/\(baseDirName)-blobs-filter4-preview"
            case .thumbnail:
                return nil
            }
        case .filter5:
            switch size {
            case .original:
                return "\(config.outputPath)/\(baseDirName)-blobs-filter5"
            case .preview:
                return "\(config.outputPath)/\(baseDirName)-blobs-filter5-preview"
            case .thumbnail:
                return nil
            }
        case .filter6:
            switch size {
            case .original:
                return "\(config.outputPath)/\(baseDirName)-blobs-filter6"
            case .preview:
                return "\(config.outputPath)/\(baseDirName)-blobs-filter6-preview"
            case .thumbnail:
                return nil
            }
        case .paintMask:
            switch size {
            case .original:
                return "\(config.outputPath)/\(baseDirName)-paintMask"
            case .preview:
                return "\(config.outputPath)/\(baseDirName)-paintMask-preview"
            case .thumbnail:
                return nil
            }
        case .validated:
            switch size {
            case .original:
                return "\(config.outputPath)/\(config.imageSequenceDirname)-star-validated-outlier-images"
            case .preview:
                return "\(config.outputPath)/\(config.imageSequenceDirname)-star-validated-outlier-images-previews"
            case .thumbnail:
                return nil
            }
        case .processed:
            switch size {
            case .original:
                return "\(config.outputPath)/\(baseDirName)"
            case .preview:
                return "\(config.outputPath)/\(baseDirName)-processed-previews"
            case .thumbnail:
                return nil
            }
        }
    }

    public func imageExists(ofType type: FrameImageType,
                            atSize size: ImageDisplaySize) -> Bool
    {
        if let filename = nameForImage(ofType: type, atSize: size) {
            return fileManager.fileExists(atPath: filename)
        }
        return false
    }
    
    
    public func nameForImage(ofType type: FrameImageType,
                             atSize size: ImageDisplaySize) -> String?
    {
        if let dir = dirForImage(ofType: type, atSize: size) {
            switch size {
            case .original:
                return "\(dir)/\(baseFileName)"
            case .preview:
                return "\(dir)/\(baseFileName).jpg"
            case .thumbnail:
                return "\(dir)/\(baseFileName).jpg"
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
    
    private func createMissingImage(ofType type: FrameImageType,
                                andSize size: ImageDisplaySize)
      async throws -> PixelatedImage?
    {
        if let filename = nameForImage(ofType: type, atSize: size),
           let smallerSize = sizeOf(size),
           let fullResImage = await load(type: type, atSize: .original),
           let scaledImageData = fullResImage.nsImage(ofSize: smallerSize)
        {
            let dataToSave = scaledImageData.jpegData
            
            if fileManager.fileExists(atPath: filename) {
                Log.i("overwriting already existing file \(filename)")
                try fileManager.removeItem(atPath: filename)
            }

            // write to file
            fileManager.createFile(atPath: filename,
                                contents: dataToSave,
                                attributes: nil)

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

nonisolated(unsafe) fileprivate let fileManager = FileManager.default
