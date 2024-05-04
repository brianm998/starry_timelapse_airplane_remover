import Foundation
import CoreGraphics
import logging
import Cocoa

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// logic for loading different kinds of images

public enum ImageDisplaySize {
    case original
    case preview
    case thumbnail
}

public enum FrameImageType {
    case original       // original image
    case aligned        // aligned neighbor frame
    case subtracted     // result of subtracting the aligned neighbor from original frame
    case blobs          // full results of the initial blog detection
    case khtb           // blobs that passed the BlobKHTAnalysis
    case houghLines     // hough lines used for kht analysis
    case absorbed       // blobs that passed the BlobAbsorber
    case rectified      // blobs that passed the BlobRectifier
    case validated      // outlier group validation image
    case paintMask      // layer mask used in painting
    case processed      // final processed image
}

public protocol ImageAccess {
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
struct ImageAccessor: ImageAccess {
    let config: Config
    let baseDirName: String
    let baseFileName: String
    let imageSequence: ImageSequence

    init(config: Config, imageSequence: ImageSequence, baseFileName: String) {
        // the dirname (not full path) of where the main output files will sit
        self.config = config
        let _basename = "\(config.imageSequenceDirname)-star-v-\(config.starVersion)-\(config.detectionType.rawValue)"
        self.baseDirName = _basename.replacingOccurrences(of: ".", with: "_")
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
    
    func mkdirs() {
        mkdir(ofType: .aligned)
        mkdir(ofType: .subtracted)
        mkdir(ofType: .blobs)
        mkdir(ofType: .khtb)
        mkdir(ofType: .absorbed)
        mkdir(ofType: .rectified)
        mkdir(ofType: .paintMask)
        mkdir(ofType: .houghLines)
        mkdir(ofType: .validated)
        mkdir(ofType: .processed)
        
        if config.writeFramePreviewFiles {
            mkdir(ofType: .original, andSize: .preview)
            mkdir(ofType: .aligned, andSize: .preview)
            mkdir(ofType: .subtracted, andSize: .preview)
            mkdir(ofType: .validated, andSize: .preview)
            mkdir(ofType: .blobs, andSize: .preview)
            mkdir(ofType: .khtb, andSize: .preview)
            mkdir(ofType: .absorbed, andSize: .preview)
            mkdir(ofType: .rectified, andSize: .preview)
            mkdir(ofType: .paintMask, andSize: .preview)
            mkdir(ofType: .houghLines, andSize: .preview)
        }
        if config.writeFrameThumbnailFiles {
            mkdir(ofType: .original, andSize: .thumbnail)
        }
        if config.writeFrameProcessedPreviewFiles {
            mkdir(ofType: .processed, andSize: .preview)
        }
    }

    func loadNSImage(type imageType: FrameImageType,
                     atSize size: ImageDisplaySize) -> NSImage?
    {
        if let url = urlForImage(ofType: imageType, atSize: size),
           let image = NSImage(contentsOf: url)
        {
            return image
        }
        return nil
    }

    func urlForImage(ofType imageType: FrameImageType,
                     atSize size: ImageDisplaySize) -> URL?
    {
        if let filename = nameForImage(ofType: imageType, atSize: size),
           fileManager.fileExists(atPath: filename)
        {
            return URL(fileURLWithPath: filename)
        }
        return nil
    }

    func load(type imageType: FrameImageType,
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

    func save(_ image: PixelatedImage,
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
        case .khtb:
            switch size {
            case .original:
                return "\(config.outputPath)/\(baseDirName)-khtb"
            case .preview:
                return "\(config.outputPath)/\(baseDirName)-khtb-preview"
            case .thumbnail:
                return nil
            }
        case .absorbed:
            switch size {
            case .original:
                return "\(config.outputPath)/\(baseDirName)-blobs-absorbed"
            case .preview:
                return "\(config.outputPath)/\(baseDirName)-blobs-absorbed-preview"
            case .thumbnail:
                return nil
            }
        case .rectified:
            switch size {
            case .original:
                return "\(config.outputPath)/\(baseDirName)-blobs-rectified"
            case .preview:
                return "\(config.outputPath)/\(baseDirName)-blobs-rectified-preview"
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
        case .houghLines:
            switch size {
            case .original:
                return "\(config.outputPath)/\(baseDirName)-kht"
            case .preview:
                return "\(config.outputPath)/\(baseDirName)-kht-preview"
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
fileprivate let fileManager = FileManager.default
