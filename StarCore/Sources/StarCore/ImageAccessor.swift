import Foundation
import CoreGraphics
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
    case original
    case aligned
    case subtracted
    case validated
    case processed
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

    // load an image of some type and size
    func loadNSImage(type imageType: FrameImageType,
                     atSize size: ImageDisplaySize) async -> NSImage?

    // where to load or save this type of image from
    func dirForImage(ofType type: FrameImageType,
                     atSize size: ImageDisplaySize) -> String?

    func mkdirs() throws
}

// read and write access to different image types for a given frame
struct ImageAccessor: ImageAccess {
    let config: Config
    let baseDirName: String
    let baseFileName: String
    let imageSequence: ImageSequence

    init(config: Config, imageSequence: ImageSequence, baseFileName: String) throws {
        // the dirname (not full path) of where the main output files will sit
        self.config = config
        let _basename = "\(config.imageSequenceDirname)-star-v-\(config.starVersion)"
        self.baseDirName = _basename.replacingOccurrences(of: ".", with: "_")
        self.baseFileName = baseFileName
        self.imageSequence = imageSequence
        try mkdirs()
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

    func mkdir(ofType type: FrameImageType, andSize size: ImageDisplaySize) throws {
        if let dirname = dirForImage(ofType: type, atSize: size) {
            try StarCore.mkdir(dirname)
        }
    }
    
    func mkdirs() throws {
        if config.writeFramePreviewFiles {
            try mkdir(ofType: .original, andSize: .preview)
        }
        if config.writeFrameThumbnailFiles {
            try mkdir(ofType: .original, andSize: .thumbnail)
        }

        try mkdir(ofType: .aligned, andSize: .original)
        if config.writeFramePreviewFiles {
            try mkdir(ofType: .aligned, andSize: .preview)
        }

        try mkdir(ofType: .subtracted, andSize: .original)
        if config.writeFramePreviewFiles {
            try mkdir(ofType: .subtracted, andSize: .preview)
        }

        try mkdir(ofType: .validated, andSize: .original)
        if config.writeFramePreviewFiles {
            try mkdir(ofType: .validated, andSize: .preview)
        }

        try mkdir(ofType: .processed, andSize: .original)
        if config.writeFrameProcessedPreviewFiles {
            try mkdir(ofType: .processed, andSize: .preview)
        }
    }

    func loadNSImage(type imageType: FrameImageType,
                     atSize size: ImageDisplaySize) async -> NSImage?
    {
        if let filename = nameForImage(ofType: imageType, atSize: size) {
            if fileManager.fileExists(atPath: filename),
               let image = NSImage(contentsOf: URL(fileURLWithPath: filename))
            {
                return image
            }
        }
        return nil
    }
    
    func load(type imageType: FrameImageType,
             atSize size: ImageDisplaySize) async -> PixelatedImage?
    {
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
        } catch {
            Log.e("couldn't load image of type \(imageType) at size \(size): \(error)")
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
                if fileManager.fileExists(atPath: filename) {
                    Log.i("overwriting already existing file \(filename)")
                    try fileManager.removeItem(atPath: filename)
                }

                // write to file
                fileManager.createFile(atPath: filename,
                                    contents: dataToSave,
                                    attributes: nil)
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
    
    private func nameForImage(ofType type: FrameImageType,
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
           let fullResImage = await load(type: type, atSize: size),
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
