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
    
    func set(state: FrameProcessingState) {
        Log.i("frame \(frameIndex) transitioning to state \(state)")
        self.state = state
    }
    
    public let width: Int
    public let height: Int
    public let bytesPerPixel: Int
    public let bytesPerRow: Int
    public let frameIndex: Int

    public let outlierOutputDirname: String
    
    // populated by pruning
    public var outlierGroups: OutlierGroups? 

    private var didChange = false

    public func changesHandled() { didChange = false }
    
    public func markAsChanged() { didChange = true }

    public func hasChanges() -> Bool { didChange }

    public let outputFilename: String

    public let config: Config
    public let callbacks: Callbacks

    public let baseName: String

    // did we load our outliers from a file?
    internal var outliersLoadedFromFile = false

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

    private let completion: (() async -> Void)?
    
    public init(with config: Config,
                width: Int,
                height: Int,
                bytesPerPixel: Int,
                callbacks: Callbacks,
                imageSequence: ImageSequence,
                atIndex frameIndex: Int,
                outputFilename: String,
                baseName: String,       // source filename without path
                outlierOutputDirname: String,
                fullyProcess: Bool = true,
                writeOutputFiles: Bool = true,
                completion: (() async -> Void)? = nil) async throws
    {
        self.imageAccessor = ImageAccessor(config: config,
                                           imageSequence: imageSequence,
                                           baseFileName: baseName)
        self.fullyProcess = fullyProcess
        self.writeOutputFiles = writeOutputFiles
        self.config = config
        self.baseName = baseName
        self.callbacks = callbacks
        self.frameIndex = frameIndex // frame index in the image sequence
        self.outputFilename = outputFilename
        self.outlierOutputDirname = outlierOutputDirname
        self.completion = completion
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

        // call directly in init becuase didSet() isn't called from here :P
       
        self.baseFilename = imageSequence.filenames[frameIndex]
        if frameIndex == imageSequence.filenames.count-1 {
            // if we're at the end, take the previous frame
            otherFilename = imageSequence.filenames[imageSequence.filenames.count-2]
        } else {
            // otherwise, take the next frame
            otherFilename = imageSequence.filenames[frameIndex+1]
        }

        if let frameStateChangeCallback = callbacks.frameStateChangeCallback {
            frameStateChangeCallback(self, self.state)
        }
    }

    private var otherFilename: String = ""
    private let baseFilename: String

    // XXX make this a lazy property 
    public func setupAlignment() async {

        // align a neighboring frame for detection
        let alignmentFilename = otherFilename

        let alignedFrame = await imageAccessor.load(type: .aligned, atSize: .original)

        if alignedFrame == nil {
            Log.d("frame \(frameIndex) creating aligned frame")
            if let dirname = imageAccessor.dirForImage(ofType: .aligned, atSize: .original) {
                Log.d("frame \(frameIndex) creating aligned frame in \(dirname)")
                self.state = .starAlignment

                // call directly in init becuase didSet() isn't called from here :P
//                if let frameStateChangeCallback = callbacks.frameStateChangeCallback {
//                    frameStateChangeCallback(self, self.state)
//                }
                Log.d("frame \(frameIndex) alignedFilename start")
                
                let alignedFilename = StarAlignment.align(alignmentFilename,
                                                          to: baseFilename,
                                                          inDir: dirname)

                Log.d("frame \(frameIndex) alignedFilename \(alignedFilename)")
                if let alignedFilename {
                    Log.d("frame \(frameIndex) got aligned filename \(alignedFilename)")
                } else {
                    Log.e("frame \(frameIndex) COULD NOT ALIGN FRAME")
                }
            } else {
                Log.w("frame \(frameIndex) no dirname for aligned original images")
            }
        } else {
            Log.d("frame \(frameIndex) loaded existing aligned frame")
        }
    }
    
    public func setupOutliers() async throws {
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
        if let _paintMask { return _paintMask }

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
            // write out the outliers binary if it is not there
            // only overwrite the paint reason if it is there
            await self.writeOutliersBinary()
        }

        if config.writeOutlierClassificationValues {
            // THIS MOFO IS SLOW
            self.state = .writingOutlierValues

            Log.d("frame \(self.frameIndex) finish 1")
            // write out the classifier feature data for this data point
            try await self.writeOutlierValuesCSV()
        }

        Log.d("frame \(self.frameIndex) finish 2")
        if !self.writeOutputFiles {
            Log.d("frame \(self.frameIndex) not writing output files")
            self.state = .complete
            if let completion { await completion() }
            return
        }
        
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

            if let outlierGroups {
                let validationImage = outlierGroups.validationImage
                try await imageAccessor.save(validationImage, as: .validated,
                                         atSize: .original, overwrite: false)
                try await imageAccessor.save(validationImage, as: .validated,
                                         atSize: .preview, overwrite: false)
            }
        }
        self.state = .complete
        if let completion { await completion() }

        
        Log.i("frame \(self.frameIndex) complete")
    }
    
    public static func == (lhs: FrameAirplaneRemover, rhs: FrameAirplaneRemover) -> Bool {
        return lhs.frameIndex == rhs.frameIndex
    }    
}

