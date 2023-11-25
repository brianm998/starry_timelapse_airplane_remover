import Foundation
import CoreGraphics
import Cocoa

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// this class holds the logic for removing airplanes from a single frame

// the first pass is done upon init, finding and pruning outlier groups


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

protocol ImageAccess {
    // save image, will rescale and jpeg if necessary
    func save(_ image: PixelatedImage,
             as type: FrameImageType,
             atSize size: ImageDisplaySize,
             overwrite: Bool) async throws

    // load an image of some type and size
    func load(type imageType: FrameImageType,
             atSize size: ImageDisplaySize) async throws -> PixelatedImage?

    // where to load or save this type of image from
    func dirForImage(ofType type: FrameImageType,
                   atSize size: ImageDisplaySize) -> String?
}

public struct ImageAccessor: ImageAccess {
    let config: Config
    let baseDirName: String
    let baseFileName: String
    let imageSequence: ImageSequence

    init(config: Config, imageSequence: ImageSequence, baseFileName: String) {
        // the dirname (not full path) of where the main output files will sit
        self.config = config
        let _basename = "\(config.imageSequenceDirname)-star-v-\(config.starVersion)"
        self.baseDirName = _basename.replacingOccurrences(of: ".", with: "_")
        self.baseFileName = baseFileName
        self.imageSequence = imageSequence
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
    
    func load(type imageType: FrameImageType,
             atSize size: ImageDisplaySize) async throws -> PixelatedImage?
    {
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
                dataToSave = image.baseImage(ofSize: previewSize)?.jpegData
            case .thumbnail:
                dataToSave = image.baseImage(ofSize: thumbnailSize)?.jpegData
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
                return nil
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
           let fullResImage = try await load(type: type, atSize: size),
           let scaledImageData = fullResImage.baseImage(ofSize: smallerSize)
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

public class FrameAirplaneRemover: Equatable, Hashable {

    internal var state: FrameProcessingState = .unprocessed {
        willSet {
            if let frameStateChangeCallback = self.callbacks.frameStateChangeCallback {
                frameStateChangeCallback(self, newValue)
            }
        }
    }

    public func processingState() -> FrameProcessingState { return state }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(frameIndex)
    }
    
    func set(state: FrameProcessingState) { self.state = state }

    // XXX delete this XXX
    // XXX delete this XXX
    // XXX delete this XXX
    /*
    var previewSize: NSSize {
        let previewWidth = config.previewWidth
        let previewHeight = config.previewHeight
        return NSSize(width: previewWidth, height: previewHeight)
    }
    */
    // XXX delete this XXX
    // XXX delete this XXX
    // XXX delete this XXX
    
    public let width: Int
    public let height: Int
    public let bytesPerPixel: Int
    public let bytesPerRow: Int
    public let frameIndex: Int

    public let outlierOutputDirname: String?
//    public let previewOutputDirname: String?
//    public let processedPreviewOutputDirname: String?
//    public let thumbnailOutputDirname: String?
//    public let starAlignedSequenceDirname: String
//    public var starAlignedSequenceFilename: String {
//        "\(starAlignedSequenceDirname)/\(baseName)"
//    }
//    public let alignedSubtractedDirname: String
//    public var alignedSubtractedFilename: String {
//        "\(alignedSubtractedDirname)/\(baseName)"
//    }

//    public let validationImageDirname: String
//    public var validationImageFilename: String {
//        "\(validationImageDirname)/\(baseName)"
//    }

//    public let alignedSubtractedPreviewDirname: String
//    public var alignedSubtractedPreviewFilename: String {
//        "\(alignedSubtractedPreviewDirname)/\(baseName).jpg" // XXX tiff.jpg :(
//    }
    
//    public let validationImagePreviewDirname: String
//    public var validationImagePreviewFilename: String {
//        "\(validationImagePreviewDirname)/\(baseName).jpg" // XXX tiff.jpg :(
//    }
    
    // populated by pruning
    public var outlierGroups: OutlierGroups?

    private var didChange = false

    public func changesHandled() { didChange = false }
    
    public func markAsChanged() { didChange = true }

    public func hasChanges() -> Bool { return didChange }

    
    public let outputFilename: String

//    public let imageSequence: ImageSequence

    public let config: Config
    public let callbacks: Callbacks

    public let baseName: String

    // did we load our outliers from a file?
    internal var outliersLoadedFromFile = false
    /*
    public var previewFilename: String? {
        if let previewOutputDirname = previewOutputDirname {
            return "\(previewOutputDirname)/\(baseName).jpg" // XXX this makes it .tif.jpg
        }
        return nil
    }
    
    public var processedPreviewFilename: String? {
        if let processedPreviewOutputDirname = processedPreviewOutputDirname {
            return "\(processedPreviewOutputDirname)/\(baseName).jpg"
        }
        return nil
    }
    
    public var thumbnailFilename: String? {
        if let thumbnailOutputDirname = thumbnailOutputDirname {
            return "\(thumbnailOutputDirname)/\(baseName).jpg"
        }
        return nil
    }
     */

    let outlierGroupLoader: () async -> OutlierGroups?

    // doubly linked list
    var previousFrame: FrameAirplaneRemover?
    var nextFrame: FrameAirplaneRemover?

    func setPreviousFrame(_ frame: FrameAirplaneRemover) {
        previousFrame = frame
    }
    
    func setNextFrame(_ frame: FrameAirplaneRemover) {
        nextFrame = frame
    }
    
    let fullyProcess: Bool

    // if this is false, just write out outlier data
    let writeOutputFiles: Bool

    let imageAccessor: ImageAccess
    
    init(with config: Config,
         width: Int,
         height: Int,
         bytesPerPixel: Int,
         callbacks: Callbacks,
         imageSequence: ImageSequence,
         atIndex frameIndex: Int,
         outputFilename: String,
         baseName: String,       // source filename without path
         outlierOutputDirname: String?,
//         previewOutputDirname: String?,
//         processedPreviewOutputDirname: String?,
//         thumbnailOutputDirname: String?,
//         starAlignedSequenceDirname: String,
//         alignedSubtractedDirname: String,
//         alignedSubtractedPreviewDirname: String,
//         validationImageDirname: String,
//         validationImagePreviewDirname: String,
         outlierGroupLoader: @escaping () async -> OutlierGroups?,
         fullyProcess: Bool = true,
         writeOutputFiles: Bool = true) async throws
    {
        self.imageAccessor = ImageAccessor(config: config,
                                       imageSequence: imageSequence,
                                       baseFileName: baseName)
        self.fullyProcess = fullyProcess
        self.writeOutputFiles = writeOutputFiles
        self.config = config
        self.baseName = baseName
        self.callbacks = callbacks
        self.outlierGroupLoader = outlierGroupLoader
//        self.imageSequence = imageSequence
        self.frameIndex = frameIndex // frame index in the image sequence
        self.outputFilename = outputFilename
        self.outlierOutputDirname = outlierOutputDirname
//        self.previewOutputDirname = previewOutputDirname
//        self.processedPreviewOutputDirname = processedPreviewOutputDirname
//        self.thumbnailOutputDirname = thumbnailOutputDirname
//        self.starAlignedSequenceDirname = starAlignedSequenceDirname
//        self.alignedSubtractedDirname = alignedSubtractedDirname
//        self.alignedSubtractedPreviewDirname = alignedSubtractedPreviewDirname
//        self.validationImageDirname = validationImageDirname
//        self.validationImagePreviewDirname = validationImagePreviewDirname
        
        self.width = width
        self.height = height

        if ImageSequence.imageWidth == 0 {
            ImageSequence.imageWidth = width
        }
        if ImageSequence.imageHeight == 0 {
            ImageSequence.imageHeight = height
        }
        
        self.bytesPerPixel = bytesPerPixel
        self.bytesPerRow = width*bytesPerPixel

        // align a neighboring frame for detection

        self.state = .starAlignment
        // call directly in init becuase didSet() isn't called from here :P
        if let frameStateChangeCallback = callbacks.frameStateChangeCallback {
            frameStateChangeCallback(self, self.state)
        }
        
        Log.i("frame \(frameIndex) doing star alignment")
        let baseFilename = imageSequence.filenames[frameIndex]
        var otherFilename: String = ""
        if frameIndex == imageSequence.filenames.count-1 {
            // if we're at the end, take the previous frame
            otherFilename = imageSequence.filenames[imageSequence.filenames.count-2]
        } else {
            // otherwise, take the next frame
            otherFilename = imageSequence.filenames[frameIndex+1]
        }

        let alignmentFilename = otherFilename

        if let dirname = imageAccessor.dirForImage(ofType: .aligned, atSize: .original) {
            _ = StarAlignment.align(alignmentFilename,
                                    to: baseFilename,
                                    inDir: dirname)
        }
        
        // this takes a long time, and the gui does it later
        if fullyProcess {
            try await loadOutliers()
            Log.d("frame \(frameIndex) done detecting outlier groups")
            await self.writeOutliersBinary()
            Log.d("frame \(frameIndex) done writing outlier binaries")
        } else {
            Log.d("frame \(frameIndex) loaded without outlier groups")
        }

    }

/*
    public func pixelatedImage() async throws -> PixelatedImage? {
        let name = imageSequence.filenames[frameIndex]
        return try await imageSequence.getImage(withName: name).image()
    }

    public func baseImage() async throws -> NSImage? {
        let name = imageSequence.filenames[frameIndex]
        return try await imageSequence.getImage(withName: name).image().baseImage
    }
    public func baseSubtractedImage() async throws -> NSImage? {
        let name = self.alignedSubtractedFilename
        return try await imageSequence.getImage(withName: name).image().baseImage
    }

    public func baseValidationImage() async throws -> NSImage? {
        let name = self.validationImageFilename
        return try await imageSequence.getImage(withName: name).image().baseImage
    }
    
    public func baseOutputImage() async throws -> NSImage? {
        let name = self.outputFilename
        return try await imageSequence.getImage(withName: name).image().baseImage
    }
    
    public func baseImage(ofSize size: NSSize) async throws -> NSImage? {
        let name = imageSequence.filenames[frameIndex]
        return try await imageSequence.getImage(withName: name).image().baseImage(ofSize: size)
    }

    public func purgeCachedOutputFiles() async {
        Log.d("frame \(frameIndex) purging output files")
        await imageSequence.removeValue(forKey: self.outputFilename)
        Log.d("frame \(frameIndex) purged output files")
    }
    
*/


    // run after shouldPaint has been set for each group, 
    // does the final painting and then writes out the output files
    public func finish() async throws {
        Log.d("frame \(self.frameIndex) starting to finish")

        self.state = .writingBinaryOutliers

        // write out the outliers binary if it is not there
        // only overwrite the paint reason if it is there
        await self.writeOutliersBinary()
            
        self.state = .writingOutlierValues

        Log.d("frame \(self.frameIndex) finish 1")
        // write out the classifier feature data for this data point
        // XXX THIS MOFO IS SLOW
        try await self.writeOutlierValuesCSV()
            
        Log.d("frame \(self.frameIndex) finish 2")
        if !self.writeOutputFiles {
            self.state = .complete
            Log.d("frame \(self.frameIndex) not writing output files")
            return
        }
        
        self.state = .reloadingImages
        
        Log.i("frame \(self.frameIndex) finishing")

        guard let image = try await imageAccessor.load(type: .original, atSize: .original)
        else { throw "couldn't load original file for finishing" }
        
        try await imageAccessor.save(image, as: .original, atSize: .preview, overwrite: false)
        try await imageAccessor.save(image, as: .original, atSize: .thumbnail, overwrite: false)

        guard let otherFrame = try await imageAccessor.load(type: .aligned, atSize: .original)
        else { throw "couldn't load aligned file for finishing" }
        
        let format = image.imageData // make a copy
        switch format {
        case .eightBit(let arr):
            Log.e("8 bit not supported here now")
        case .sixteenBit(var outputData):
            self.state = .painting

            Log.d("frame \(self.frameIndex) painting over airplanes")

            try await self.paintOverAirplanes(toData: &outputData, otherFrame: otherFrame)

            Log.d("frame \(self.frameIndex) writing output files")
            self.state = .writingOutputFile

            Log.d("frame \(self.frameIndex) writing processed preview")
            let processedImage = image.updated(with: outputData)
            // write frame out as processed versions
            try await imageAccessor.save(processedImage, as: .processed,
                                      atSize: .original, overwrite: true)
            try await imageAccessor.save(processedImage, as: .processed,
                                      atSize: .preview, overwrite: true)

            if let outlierGroups = outlierGroups {
                let validationImage = outlierGroups.validationImage
                try await imageAccessor.save(validationImage, as: .validated,
                                         atSize: .original, overwrite: false)
                try await imageAccessor.save(validationImage, as: .validated,
                                         atSize: .preview, overwrite: false)
            }
        }
        self.state = .complete

        Log.i("frame \(self.frameIndex) complete")
    }
    
    public static func == (lhs: FrameAirplaneRemover, rhs: FrameAirplaneRemover) -> Bool {
        return lhs.frameIndex == rhs.frameIndex
    }    
}

