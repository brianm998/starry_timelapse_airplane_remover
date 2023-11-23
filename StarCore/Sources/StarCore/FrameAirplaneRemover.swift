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
    
    public let width: Int
    public let height: Int
    public let bytesPerPixel: Int
    public let bytesPerRow: Int
    public let frameIndex: Int

    public let outlierOutputDirname: String?
    public let previewOutputDirname: String?
    public let processedPreviewOutputDirname: String?
    public let thumbnailOutputDirname: String?
    public let starAlignedSequenceDirname: String
    public var starAlignedSequenceFilename: String {
        "\(starAlignedSequenceDirname)/\(baseName)"
    }
    public let alignedSubtractedDirname: String
    public var alignedSubtractedFilename: String {
        "\(alignedSubtractedDirname)/\(baseName)"
    }

    public let validationImageDirname: String
    public var validationImageFilename: String {
        "\(validationImageDirname)/\(baseName)"
    }

    public let alignedSubtractedPreviewDirname: String
    public var alignedSubtractedPreviewFilename: String {
        "\(alignedSubtractedPreviewDirname)/\(baseName).jpg" // XXX tiff.jpg :(
    }
    
    public let validationImagePreviewDirname: String
    public var validationImagePreviewFilename: String {
        "\(validationImagePreviewDirname)/\(baseName).jpg" // XXX tiff.jpg :(
    }
    
    // populated by pruning
    public var outlierGroups: OutlierGroups?

    private var didChange = false

    public func changesHandled() { didChange = false }
    
    public func markAsChanged() { didChange = true }

    public func hasChanges() -> Bool { return didChange }

    
    public let outputFilename: String

    public let imageSequence: ImageSequence

    public let config: Config
    public let callbacks: Callbacks

    public let baseName: String

    // did we load our outliers from a file?
    internal var outliersLoadedFromFile = false
    
    var previewSize: NSSize {
        let previewWidth = config.previewWidth
        let previewHeight = config.previewHeight
        return NSSize(width: previewWidth, height: previewHeight)
    }
    
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
         previewOutputDirname: String?,
         processedPreviewOutputDirname: String?,
         thumbnailOutputDirname: String?,
         starAlignedSequenceDirname: String,
         alignedSubtractedDirname: String,
         alignedSubtractedPreviewDirname: String,
         validationImageDirname: String,
         validationImagePreviewDirname: String,
         outlierGroupLoader: @escaping () async -> OutlierGroups?,
         fullyProcess: Bool = true,
         writeOutputFiles: Bool = true) async throws
    {
        self.fullyProcess = fullyProcess
        self.writeOutputFiles = writeOutputFiles
        self.config = config
        self.baseName = baseName
        self.callbacks = callbacks
        self.outlierGroupLoader = outlierGroupLoader
        self.imageSequence = imageSequence
        self.frameIndex = frameIndex // frame index in the image sequence
        self.outputFilename = outputFilename

        self.outlierOutputDirname = outlierOutputDirname
        self.previewOutputDirname = previewOutputDirname
        self.processedPreviewOutputDirname = processedPreviewOutputDirname
        self.thumbnailOutputDirname = thumbnailOutputDirname
        self.starAlignedSequenceDirname = starAlignedSequenceDirname
        self.alignedSubtractedDirname = alignedSubtractedDirname
        self.alignedSubtractedPreviewDirname = alignedSubtractedPreviewDirname
        self.validationImageDirname = validationImageDirname
        self.validationImagePreviewDirname = validationImagePreviewDirname
        
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
        
        _ = StarAlignment.align(alignmentFilename,
                                to: baseFilename,
                                inDir: starAlignedSequenceDirname)
        
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
        let image = try await imageSequence.getImage(withName: imageSequence.filenames[frameIndex]).image()
        
        self.writeUprocessedPreviews(image)

        // use star aligned image
        let otherFrame = try await imageSequence.getImage(withName: starAlignedSequenceFilename).image()

        let _data = image.rawImageData
        
        // copy the original image data as adjecent frames need
        // to access the original unmodified version
        guard let _mut_data = CFDataCreateMutableCopy(kCFAllocatorDefault,
                                                      CFDataGetLength(_data as CFData),
                                                      _data as CFData) as? Data
        else {
            Log.e("couldn't copy image data")
            fatalError("couldn't copy image data")
        }
        var outputData = _mut_data

        self.state = .painting

        Log.d("frame \(self.frameIndex) painting over airplanes")

        try await self.paintOverAirplanes(toData: &outputData,
                                          otherFrame: otherFrame)

        Log.d("frame \(self.frameIndex) writing output files")
        self.state = .writingOutputFile

        Log.d("frame \(self.frameIndex) writing processed preview")
        self.writeProcessedPreview(image, with: outputData)

        self.writeValidationImage()

        Log.d("frame \(self.frameIndex) writing full processed frame")
        // write frame out as a tiff file after processing it
        try image.writeTIFFEncoding(ofData: outputData,  toFilename: self.outputFilename)
        self.state = .complete

        Log.i("frame \(self.frameIndex) complete")
    }
    
    public static func == (lhs: FrameAirplaneRemover, rhs: FrameAirplaneRemover) -> Bool {
        return lhs.frameIndex == rhs.frameIndex
    }    
}

