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
    
    // populated by pruning
    public var outlierGroups: OutlierGroups?

    private var didChange = false

    public func changesHandled() { didChange = false }
    
    public func markAsChanged() { didChange = true }

    public func hasChanges() -> Bool { return didChange }

    public let outputFilename: String

    public let config: Config
    public let callbacks: Callbacks

    public let baseName: String

    // did we load our outliers from a file?
    internal var outliersLoadedFromFile = false

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

    public let imageAccessor: ImageAccess
    
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
        self.frameIndex = frameIndex // frame index in the image sequence
        self.outputFilename = outputFilename
        self.outlierOutputDirname = outlierOutputDirname
        
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

        if !imageAccessor.imageExists(ofType: .aligned, atSize: .original),
           let dirname = imageAccessor.dirForImage(ofType: .aligned, atSize: .original)
        {
            self.state = .starAlignment
            _ = StarAlignment.align(alignmentFilename,
                                    to: baseFilename,
                                    inDir: dirname)
        }

        // this takes a long time, and the gui does it later
        if fullyProcess {
            try await loadOutliers()
            Log.d("frame \(frameIndex) done detecting outlier groups")
            if !self.outliersLoadedFromFile {
                await self.writeOutliersBinary()
            }
            Log.d("frame \(frameIndex) done writing outlier binaries")
        } else {
            Log.d("frame \(frameIndex) loaded without outlier groups")
        }

    }

    var _paintMask: PaintMask?
    
    var paintMask: PaintMask {
        if let _paintMask = _paintMask { return _paintMask }

        let mask = PaintMask(innerWallSize: config.outlierGroupPaintBorderInnerWallPixels,
                             radius: config.outlierGroupPaintBorderPixels)
        _paintMask = mask
        return mask
    }

    // run after shouldPaint has been set for each group, 
    // does the final painting and then writes out the output files
    public func finish() async throws {
        Log.d("frame \(self.frameIndex) starting to finish")

        if didChange {
            self.state = .writingBinaryOutliers

            // write out the outliers binary if it is not there
            // only overwrite the paint reason if it is there
            await self.writeOutliersBinary()
        }
            
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

        guard let image = await imageAccessor.load(type: .original, atSize: .original)
        else { throw "couldn't load original file for finishing" }
        
        try await imageAccessor.save(image, as: .original, atSize: .preview, overwrite: false)
        try await imageAccessor.save(image, as: .original, atSize: .thumbnail, overwrite: false)

        guard let otherFrame = await imageAccessor.load(type: .aligned, atSize: .original)
        else { throw "couldn't load aligned file for finishing" }
        
        let format = image.imageData // make a copy
        switch format {
        case .eightBit(_):
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

