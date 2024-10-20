import Foundation
import CoreGraphics
import logging
import Cocoa
import Combine

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// this class holds the logic for removing airplanes from a single frame

// the first pass is done upon init, finding and pruning outlier groups

@MainActor
@Observable
public class FrameObserver {
    public init() { }

    public var numberOfPositiveOutliers: Int? 
    public var numberOfNegativeOutliers: Int? 
    public var numberOfUndecidedOutliers: Int?

    // XXX stick more here, like state
    
    public func set(numberOfPositiveOutliers: Int) {
        self.numberOfPositiveOutliers = numberOfPositiveOutliers
    }

    public func set(numberOfNegativeOutliers: Int) {
        self.numberOfNegativeOutliers = numberOfNegativeOutliers
    }

    public func set(numberOfUndecidedOutliers: Int) {
        self.numberOfUndecidedOutliers = numberOfUndecidedOutliers
    }

    func set(numberOfPositiveOutliers: Int,
             numberOfNegativeOutliers: Int,
             numberOfUndecidedOutliers: Int)
    {
        self.numberOfPositiveOutliers = numberOfPositiveOutliers
        self.numberOfNegativeOutliers = numberOfNegativeOutliers
        self.numberOfUndecidedOutliers = numberOfUndecidedOutliers
    }

}


final public actor FrameAirplaneRemover: Equatable, Hashable {

    fileprivate var state: FrameProcessingState = .unprocessed 

    public var observer: FrameObserver?

    public func set(observer: FrameObserver) {
        self.observer = observer
    }
    
    public func set(state: FrameProcessingState) {
        Log.i("frame \(frameIndex) transitioning to state \(state)")
        self.state = state
        if let frameStateChangeCallback = self.callbacks.frameStateChangeCallback {
            frameStateChangeCallback(self, state)
        }
    }
    
    public func processingState() -> FrameProcessingState { return state }
    
    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(frameIndex)
    }
    
    nonisolated public let width: Int
    nonisolated public let height: Int
    nonisolated public let bytesPerPixel: Int
    nonisolated public let bytesPerRow: Int
    nonisolated public let frameIndex: Int

    nonisolated public let outlierOutputDirname: String
    
    // populated by pruning
    public var outlierGroups: OutlierGroups? 

    public func getOutlierGroups() -> OutlierGroups?  { outlierGroups }
    
    fileprivate var didChange = false

    public func changesHandled() { didChange = false }

    public func updateCombineSubjects() async {
        if let outliers = await outlierGroups?.getMembers() {
            var totalPositive: Int = 0
            var totalNegative: Int = 0
            var totalUnknown: Int = 0
            for (_, group) in outliers {
                if let shouldPaint = await group.shouldPaint() {
                    if shouldPaint.willPaint {
                        totalPositive += 1
                    } else {
                        totalNegative += 1
                    }
                } else {
                    totalUnknown += 1
                }
            }

            // update the observer here
          await observer?.set(numberOfPositiveOutliers: totalPositive,
                               numberOfNegativeOutliers: totalNegative,
                               numberOfUndecidedOutliers: totalUnknown)
        }
    }

    // when this happens, re-calculate and send to all the combine subjects
    public func markAsChanged() async {
        didChange = true
        //Task { await self.updateCombineSubjects() }
        await self.updateCombineSubjects()
    }

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

    func getPreviousFrame() -> FrameAirplaneRemover? { previousFrame }
    
    func setPreviousFrame(_ frame: FrameAirplaneRemover) {
        previousFrame = frame
    }

    func getNextFrame() -> FrameAirplaneRemover? { nextFrame }
    
    func setNextFrame(_ frame: FrameAirplaneRemover) {
        nextFrame = frame
    }
    
    let fullyProcess: Bool

    // if this is false, just write out outlier data
    let writeOutputFiles: Bool

    nonisolated public let imageAccessor: ImageAccess

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
                completion: (@Sendable () async -> Void)? = nil) async throws
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

        await self.loadUserSlices()
        
        await self.updateCombineSubjects()
    }

    private var otherFilename: String = ""
    private let baseFilename: String

    internal var userSlices: [BoundingBox] = []
    
    public var userSliceDirname: String {
        "\(config.outputPath)/\(config.imageSequenceDirname)-star-user-slices"
    }

    public var userSliceFilename: String {
        "\(self.userSliceDirname)/slices_\(frameIndex).json"
    }

    // lazy loaded aligned a neighboring frame
    public func starAlignedImage() async throws -> PixelatedImage? {
        
        let alignmentFilename = otherFilename

//        let accessor = imageAccessor
        
        if let alignedFrame = try await imageAccessor.load(type: .aligned, atSize: .original) {
            Log.d("frame \(frameIndex) loaded existing aligned frame")
            return alignedFrame
        } else {
            Log.d("frame \(frameIndex) creating aligned frame")
            if let dirname = imageAccessor.dirForImage(ofType: .aligned, atSize: .original) {
                Log.d("frame \(frameIndex) creating aligned frame in \(dirname)")
                self.set(state: .starAlignment)

                // call directly in init becuase didSet() isn't called from here :P
//                if let frameStateChangeCallback = callbacks.frameStateChangeCallback {
//                    frameStateChangeCallback(self, self.state)
//                }
                Log.d("frame \(frameIndex) alignedFilename start")
                
                let alignedFilename = try await StarAlignment.align(alignmentFilename,
                                                                    to: baseFilename,
                                                                    inDir: dirname)

                Log.d("frame \(frameIndex) alignedFilename \(String(describing: alignedFilename))")
                if let alignedFilename {
                    Log.d("frame \(frameIndex) got aligned filename \(alignedFilename)")
                    if let alignedFrame = try await imageAccessor.load(type: .aligned, atSize: .original) {
                        return alignedFrame
                    } else {
                        Log.e("frame \(frameIndex) could not load aligned frame")
                    }
                } else {
                    Log.e("frame \(frameIndex) COULD NOT ALIGN FRAME")
                }
            } else {
                Log.w("frame \(frameIndex) no dirname for aligned original images")
            }
        }
        return nil
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
        self.set(state: .finishing)
        if didChange {
            // write out the outliers binary if it is not there
            // only overwrite the paint reason if it is there
            await self.writeOutliersBinary()
        }

        if config.writeOutlierClassificationValues {
            // THIS MOFO IS SLOW
            self.set(state: .writingOutlierValues)

            Log.d("frame \(self.frameIndex) finish 1")
            // write out the classifier feature data for this data point
            try await self.writeOutlierValuesCSV()
        }

        Log.d("frame \(self.frameIndex) finish 2")
        if !self.writeOutputFiles {
            Log.d("frame \(self.frameIndex) not writing output files")
            self.set(state: .complete)
            if let completion { await completion() }
            return
        }
        
        Log.i("frame \(self.frameIndex) finishing")

        self.set(state: .loadingImages)

        var (image, otherFrame) = try await finalFileSystemMonitor.load() {
            await (imageAccessor.loadInt(type: .original, atSize: .original),
                   imageAccessor.loadInt(type: .aligned, atSize: .original))
        }

        guard let image = image//try await imageAccessor.loadFinal(type: .original, atSize: .original)
        else { throw "couldn't load original file for finishing" }
        
        if self.writeOutputFiles {
            self.set(state: .loadingImages1)
            try await imageAccessor.saveFinal(image, as: .original, atSize: .preview, overwrite: false)
            try await imageAccessor.saveFinal(image, as: .original, atSize: .thumbnail, overwrite: false)
        }

        
        if otherFrame == nil {
            // try creating the star aligned image if we can't load it
            Log.i("doing star alignment at finish")
            otherFrame = try await starAlignedImage()
        }

        
        guard let otherFrame else {
            throw "couldn't load aligned file for finishing"
        }
        
        let format = image.imageData // make a copy

        switch format {
        case .eightBit(_):
            Log.e("8 bit not supported here now")
        case .sixteenBit(var outputData):
            Log.d("frame \(self.frameIndex) painting over airplanes")

            try await self.paintOverAirplanes(image: image,
                                              toData: &outputData,
                                              otherFrame: otherFrame)

            Log.d("frame \(self.frameIndex) writing output files")
            self.set(state: .writingOutputFile)

            Log.d("frame \(self.frameIndex) updating image")
            let processedImage = image.updated(with: outputData)
            // write frame out as processed versions
            do {
                Log.d("frame \(self.frameIndex) processed file")
                try await imageAccessor.saveFinal(processedImage, as: .processed,
                                                  atSize: .original, overwrite: true)
                Log.d("frame \(self.frameIndex) writing processed preview")
                try await imageAccessor.saveFinal(processedImage, as: .processed,
                                                  atSize: .preview, overwrite: true)
            } catch {
                // XXX for some reason this error gets missed if we don't catch it here :(
                Log.d("frame \(self.frameIndex) ERROR \(error)")

            }
            if let outlierGroups {
                Log.d("frame \(self.frameIndex) getting validating image")
                let validationImage = await outlierGroups.validationImage()
                Log.d("frame \(self.frameIndex) writing validated image")
                try await imageAccessor.saveFinal(validationImage, as: .validated,
                                                  atSize: .original, overwrite: false)
                Log.d("frame \(self.frameIndex) writing validated preview")
                try await imageAccessor.saveFinal(validationImage, as: .validated,
                                                  atSize: .preview, overwrite: false)
            }
            Log.d("frame \(self.frameIndex) done writing toutut files")
        }
        self.set(state: .complete)
        if let completion { await completion() }

        
        Log.i("frame \(self.frameIndex) complete")
    }
    
    public static func == (lhs: FrameAirplaneRemover, rhs: FrameAirplaneRemover) -> Bool {
        return lhs.frameIndex == rhs.frameIndex
    }    
}

