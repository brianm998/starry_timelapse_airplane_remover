import Foundation
import StarCppBridge
import logging
import Semaphore
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif
#if os(Windows)
// CreateHardLinkW + GetLastError live in WinSDK; the POSIX link(2) used on
// macOS/Linux is unavailable on Windows.
import WinSDK
#endif

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// logic for loading different kinds of images

public enum FrameReprocessingType: String, Codable, Equatable, CaseIterable, Sendable {
    case everything             // redo everything, delete all existing work files
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
    public let imageSequence: ImageSequence
    let imageSavedClosure: (
      @Sendable (
        PixelatedImage,
        Int,
        FrameViewMode,
        ImageDisplaySize
      ) -> Void)?

    /// Told the index of a frame whose horizon lines have changed: a horizon mask of any kind
    /// (`FrameViewMode.isHorizonMask`) written or deleted at full size, or a painted reference
    /// saved or cleared.  How the clients know to draw a frame's lines again — the consensus,
    /// for one, is written for the whole sequence long before most frames finish merging, and
    /// nothing else about those frames changes when it is.  Set before the accessor is handed
    /// to the frames, which take copies.
    public var horizonChangedClosure: (@Sendable (Int) -> Void)? = nil

    /// Say that `frameIndex`'s horizon lines have changed (`horizonChangedClosure`).
    public func horizonLinesChanged(frameIndex: Int) {
        horizonChangedClosure?(frameIndex)
    }

    public init(
      config: Config,
      imageSequence: ImageSequence,
      frameIndexToBaseNameMap: [Int: String],
      imageSavedClosure: (
        @Sendable (
          PixelatedImage,
          Int,
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

    var previewSize: CGSize {
        let previewWidth = config.previewWidth
        let previewHeight = config.previewHeight
        return CGSize(width: previewWidth, height: previewHeight)
    }

    var thumbnailSize: CGSize {
        let thumbnailWidth = config.thumbnailWidth
        let thumbnailHeight = config.thumbnailHeight
        return CGSize(width: thumbnailWidth, height: thumbnailHeight)
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
        StarCore.mkdir(config.dirForKeypointData)
        writeCleanupScript()
    }

    private func writeCleanupScript() {
        let tempDir = config.tempOutputPath
        let tempDirName = URL(fileURLWithPath: tempDir).lastPathComponent
        let outputDirName = URL(fileURLWithPath: config.outputSequenceDirname).lastPathComponent
        let script = """
            #!/bin/bash
            cd "$(dirname "$0")/.."
            rm -rf "\(tempDirName)"
            rm -rf "\(outputDirName)"
            """
        let scriptPath = "\(tempDir)/cleanup.sh"
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
              [.posixPermissions: 0o755],
              ofItemAtPath: scriptPath
            )
        } catch {
            Log.w("could not write cleanup.sh: \(error)")
        }
    }

    // load for display as SwiftUI Image
    #if canImport(SwiftUI) && canImport(AppKit)
    nonisolated public func loadImage(
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
    #endif

    public func urlForImage(frameIndex: Int,
                            ofType imageType: FrameViewMode,
                            atSize size: ImageDisplaySize) -> URL?
    {
        if let filename = nameForImage(frameIndex: frameIndex,
                                       ofType: imageType,
                                       atSize: size)
        {
            if FileManager.default.fileExists(atPath: filename) {
                let url = URL(fileURLWithPath: filename)
                // attempt to make this url cache with its modification time
                // so if the file changes, this url is now invalid
                
                if let modDate = try? FileManager.default.attributesOfItem(
                     atPath: filename
                   )[.modificationDate] as? Date {
                    //Log.d("appending modDate \(modDate)")
                    return url.appending(
                      queryItems: [
                        URLQueryItem(
                          name: "t",
                          value: "\(modDate.timeIntervalSince1970)"
                        )
                      ]
                    )
                    
                }
                return url
            } else {
                //Log.w("file does not exist at \(filename)") // XXX DOH!
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

    public func loadFinal(
      frameIndex: Int,
      type imageType: FrameViewMode,
      atSize size: ImageDisplaySize
    ) async throws -> PixelatedImage? {
        await self.loadInt(frameIndex: frameIndex, type: imageType, atSize: size)
    }

    public func load(
      frameIndex: Int,
      type imageType: FrameViewMode,
      atSize size: ImageDisplaySize
    ) async throws -> PixelatedImage? {
        await self.loadInt(frameIndex: frameIndex, type: imageType, atSize: size)
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
                       let image = await imageCache.loadImage(filename: filename)
                    {
                        Log.d("filename \(filename) exists, returning \(image.description)")
                        // Horizon masks must always be CV_8UC1 for OpenCV operations
                        if imageType.isHorizonMask {
                            return image.asHorizonMask ?? image
                        }
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
                                let result = imageType.isHorizonMask
                                    ? (image.asHorizonMask ?? image)
                                    : image
                                await imageCache.add(image: result, named: filename)
                                return result
                            }
                            return nil
                        }
                    }
                } else {
                    Log.w("load \(frameIndex) no filename for type \(imageType) at size \(size)")
                    return nil
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

    public func linkFinals(
      frameIndex: Int,
      as type: FrameViewMode,
      atSizes sizes: [ImageDisplaySize]
    ) async throws {
        for size in sizes {
            try await self.linkFinal(
              frameIndex: frameIndex,
              as: type,
              atSize: size
            )
        }
    }

    // ln or cp a processed type to .final
    public func linkFinal(
      frameIndex: Int,
      as type: FrameViewMode,
      atSize size: ImageDisplaySize
    ) async throws {
        if let fromName = nameForImage(
            frameIndex: frameIndex,
            ofType: type,
            atSize: size
           ),
           let toName = nameForImage(
            frameIndex: frameIndex,
            ofType: .final,
            atSize: size
           )
        {
            // Only the original is required output.  A preview is written when the
            // config asks for one — the cli leaves writeFramePreviewFiles and
            // writeFrameProcessedPreviewFiles false, and the gui forces only the
            // former — so there is often nothing to link from, and then neither the
            // hard link nor the copy fallback can succeed.  That is not a failure of
            // this frame, so skip it rather than throwing out through finishAuto into
            // MergeOp, which reported it per frame on every resume.  A missing
            // original is still an error, and still throws below.
            if size != .original,
               !FileManager.default.fileExists(atPath: fromName)
            {
                Log.d("frame \(frameIndex) has no \(type) at size \(size) to link to .final, skipping")
                return
            }
            do {
                try createHardLinkReplacingDestination(
                  from: fromName,
                  to: toName
                )
            } catch {
                Log.w("cannot hard link \(fromName) to \(toName), trying copy")
                try copyReplacingDestination(
                  from: fromName,
                  to: toName
                )
            }
            if size == .preview,
               let imageSavedClosure
            {
                // f-ing load the image here
                if let image = await self.loadInt(
                     frameIndex: frameIndex,
                     type: .final,
                     atSize: size
                   )
                {
                    imageSavedClosure(image, frameIndex, .final, size)
                }
            }
        } else {
            throw "cannot link: either name for \(type) or name for .final doesn't exist"
        }
    }
    
    // save using the file system monitor

    public func save(
      _ image: PixelatedImage,
      frameIndex: Int,
      as type: FrameViewMode,
      atSizes sizes: [ImageDisplaySize],
      overwrite: Bool
    ) async throws {
        for size in sizes {
            try await self.save(
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
        await self.saveInt(
          image,
          frameIndex: frameIndex,
          as: type,
          atSize: size,
          overwrite: overwrite
        )
    }
    
    // Every full-size write and every preview write goes through `IOWork`, which holds one
    // of the destination volume's streams for the write and does it off the cooperative
    // pool. This used to be `Task.detached`, which stays *on* the pool: a 196MB TIFF save
    // is seconds of blocked thread, and the pool has only core-count threads.
    private func saveInt(_ image: PixelatedImage,
                         frameIndex: Int,
                         as type: FrameViewMode,
                         atSize size: ImageDisplaySize,
                         overwrite: Bool) async
    {
        guard let filename = nameForImage(frameIndex: frameIndex,
                                          ofType: type,
                                          atSize: size)
        else {
            Log.w("no place to save image of type \(type) at size \(size)")
            return
        }

        switch size {
        case .original where type == .final:
            // The user's actual product. A failure here is recorded rather than
            // discarded — before the write path could report one, a full disk meant
            // star worked through the whole sequence, wrote nothing, and exited 0.
            let ok = await IOWork.run(path: filename, bytes: image.byteCount) {
                image.writeTIFFEncoding(toFilename: filename)
            }
            if !ok {
                await OutputWriteFailures.shared.record(path: filename,
                                                        frameIndex: frameIndex)
            }
        case .original where type.isRecomputableCache:
            // A cache of work that is recomputed when missing: uncompressed so the
            // reload takes the direct read, and no fsync — a torn one after a
            // crash fails to decode and `loadOrCreateAlignedImage` rebuilds it.
            let ok = await IOWork.run(path: filename, bytes: image.byteCount) {
                image.writeCacheTIFF(toFilename: filename)
            }
            if !ok {
                Log.w("frame \(frameIndex) failed to write intermediate image of type \(type) to \(filename)")
            }
        case .original:
            // Every other type saved at original size (autoProcessed, ...) is either
            // hard-linked into the output folder as the final frame or an intermediate
            // under tempOutputPath. A write failure there is worth a log line — it'll
            // just be recreated next run — but not the critical "disk full, your
            // render is at risk" alert that OutputWriteFailures raises.
            let ok = await IOWork.run(path: filename, bytes: image.byteCount) {
                image.writeTIFFEncoding(toFilename: filename)
            }
            if ok, type.isHorizonMask {
                horizonLinesChanged(frameIndex: frameIndex)
            }
            if !ok {
                Log.w("frame \(frameIndex) failed to write intermediate image of type \(type) to \(filename)")
            }
        default:
            // everything but originals gets downscaled and saved as a jpeg. The
            // downscale is CPU work (the CPU gate); only the write holds a stream.
            if let smallSize = sizeOf(size) {
                let downScaled = await NativeWork.run {
                    image.downScaleTo(width: UInt(smallSize.width),
                                      height: UInt(smallSize.height))
                }
                if let downScaled {
                    await IOWork.run(path: filename, bytes: downScaled.byteCount) {
                        downScaled.saveJpeg(withQuality: 60, filename: filename)
                    }
                    imageSavedClosure?(downScaled, frameIndex, type, size)
                }
            }
        }
    }

    public func nameForImage(
      frameIndex: Int,
      ofType type: FrameViewMode,
      atSize size: ImageDisplaySize
    ) -> String? {
        if type == .userHorizon {
            return nameForUserHorizonImage(frameIndex: frameIndex, atSize: size)
        }
        if let (dirname, filename) = dirAndNameForImage(frameIndex: frameIndex,
                                                        ofType: type,
                                                        atSize: size)
        {
            return "\(dirname)/\(filename)"
        }
        return nil
    }

    // Returns the path to the user-defined horizon mask for the given frame.
    // For original: checks per-frame file first, then falls back to reference.tiff.
    // For preview: returns a per-frame JPEG path in horizonReference-previews/.
    private func nameForUserHorizonImage(frameIndex: Int, atSize size: ImageDisplaySize) -> String? {
        guard let baseFileName = frameIndexToBaseNameMap[frameIndex] else { return nil }

        switch size {
        case .original:
            guard let dir = config.dirForImage(ofType: .userHorizon, atSize: .original)
            else { return nil }
            let perFramePath = "\(dir)/\(baseFileName)"
            if FileManager.default.fileExists(atPath: perFramePath) {
                return perFramePath
            }
            let globalPath = "\(dir)/reference.tiff"
            if FileManager.default.fileExists(atPath: globalPath) {
                return globalPath
            }
            return nil
        case .preview:
            guard let dir = config.dirForImage(ofType: .userHorizon, atSize: .preview)
            else { return nil }
            return "\(dir)/\(baseFileName).jpg"
        case .thumbnail:
            return nil
        }
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
                case .userHorizon:
                    return (dir, baseFileName)
                case .consensusHorizon:
                    return (dir, baseFileName)
                case .starAligned:
                    return (dir, baseFileName)
                case .failedStarAligned:
                    return (dir, baseFileName)
                case .failedEarthAligned:
                    // Was missing while its sky counterpart above was present, so this
                    // type had a directory in Config and no way to name a file in it.
                    // Nothing writes one yet either way — see the note in
                    // `FrameAlignmentProcessor.loadOrCreateAlignedImage` — but a type
                    // that cannot be named cannot be checked for, and the caller's
                    // existence test is what keeps that fallback quiet.
                    return (dir, baseFileName)
                case .earthAligned:
                    return (dir, baseFileName)
                case .original:
                    return (dir, baseFileName)
                case .final:
                    return (dir, baseFileName)
                case .autoProcessed:
                    return (dir, baseFileName)
                case .selectiveProcessed:
                    return (dir, baseFileName)
                case .autoSelectiveProcessed:
                    return (dir, baseFileName)
                case .validation:
                    return (dir, baseFileName)
                case .removeMask:
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

    private func sizeOf(_ size: ImageDisplaySize) -> CGSize? {
        switch size {
        case .original:
            return nil
        case .preview:
            return previewSize
        case .thumbnail:
            return thumbnailSize
        }
    }

    public func deleteImages(
      frameIndex: Int,
      ofType imageType: FrameViewMode,
      atSizes sizes: [ImageDisplaySize]
    ) {
        for size in sizes {
            try? deleteImage(
              frameIndex: frameIndex,
              ofType: imageType,
              atSize: size
            )
        }
    }
    
    public func deleteImages(
      frameIndex: Int,
      ofTypes imageTypes: [FrameViewMode],
      atSizes sizes: [ImageDisplaySize]
    ) {
        for imageType in imageTypes {
            deleteImages(
              frameIndex: frameIndex,
              ofType: imageType,
              atSizes: sizes
            )
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
            if imageType.isHorizonMask && size == .original {
                horizonLinesChanged(frameIndex: frameIndex)
            }
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

            case .userHorizon:
                break           // user-defined horizon masks are not auto-generated; preserve them

            case .consensusHorizon:
                // The image is only a drawing of the line beside it; the two go together, so
                // a line is never used for a frame whose view of it has gone.
                try? deleteImage(frameIndex: frameIndex, ofType: type, atSize: .original)
                try? deleteImage(frameIndex: frameIndex, ofType: type, atSize: .preview)
                HorizonConsensusStore.delete(frameIndex: frameIndex, config: config)

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
        
    public nonisolated func makeMissingImage(
      frameIndex: Int,
      ofType type: FrameViewMode,
      andSize size: ImageDisplaySize,
      semaphore: AsyncSemaphore? = nil
    ) async throws -> PixelatedImage? {
        Log.d("frame \(frameIndex) start with frame \(frameIndex)")
        if let filename = nameForImage(frameIndex: frameIndex,
                                       ofType: type,
                                       atSize: size),
           let smallerSize = sizeOf(size),
           let fullResImage = try await load(frameIndex: frameIndex,
                                             type: type,
                                             atSize: .original)
        {
            try ensureParentDirectoriesExist(for: filename)
            
            Log.d("frame \(frameIndex) loaded 1 for frame \(frameIndex)")

            semaphore?.signal()

            if let scaledImage = fullResImage.downScaleTo(
                 width: UInt(smallerSize.width),
                 height: UInt(smallerSize.height)
               )
            {
                Log.d("frame \(frameIndex) loaded 2 for frame \(frameIndex)")
                
                if FileManager.default.fileExists(atPath: filename) {
                    Log.i("overwriting already existing file \(filename)")
                    try FileManager.default.removeItem(atPath: filename)
                }

                // make it 8 bit with scaling

                if let eightBitVersion = scaledImage.ensureEightBit {
                    // write to file
                    eightBitVersion.saveJpeg(withQuality: 50, filename: filename)
                    Log.d("frame \(frameIndex) wrote preview to \(filename)")
                } else {
                    Log.w("frame \(frameIndex) Unable to create 8 bit version of scaled image")
                }
                
                return scaledImage
            }
        } else {
            semaphore?.signal()
        }
        Log.d("done with frame \(frameIndex)")
        return nil
    }
    
    /// Write an 8-bit JPEG copy of a frame's full-size image of `type` to `filename`, for a client that cannot read the file the
    /// pipeline wrote (a 16-bit TIFF).  The preview and thumbnail are made the same way, at their smaller sizes.  False if the
    /// frame has no such image yet.
    public nonisolated func writeFullSizeDisplayCopy(
      frameIndex: Int,
      ofType type: FrameViewMode,
      to filename: String,
      quality: UInt = 90
    ) async throws -> Bool {
        guard let fullResImage = try await load(frameIndex: frameIndex, type: type, atSize: .original),
              let eightBit = fullResImage.ensureEightBit
        else { return false }
        try ensureParentDirectoriesExist(for: filename)
        if FileManager.default.fileExists(atPath: filename) {
            try FileManager.default.removeItem(atPath: filename)
        }
        return eightBit.saveJpeg(withQuality: quality, filename: filename)
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

    public func writeMissingImages(
      _ closure: @Sendable @escaping (Int) async -> Void
    ) async throws {
        Log.d("write missing images")
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
            Log.i("found previews and thumbnails for end of sequence, did nothing")
        } else {
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            for frameIndex in farthestFirstOrder(range: 0..<imageSequenceSize) {
                    Log.d("frame \(frameIndex) checking for missing images")
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
                    Log.d("frame \(frameIndex) got names for missing images: \(previewFilename) \(thumbnailFilename)")

                    let previewExists = FileManager.default.fileExists(atPath: previewFilename)
                    let thumbnailExists = FileManager.default.fileExists(atPath: thumbnailFilename)
                    if !previewExists || !thumbnailExists {
                        Log.d("frame \(frameIndex) is missing images")
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
                             await closure(frameIndex)
                             //                            return
                        }
                    } else {
                        await closure(frameIndex)
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
        Log.d("frame \(frameIndex) writeMissingImages")
        if let fullResImage = try await load(
             frameIndex: frameIndex,
             type: .original,
             atSize: .original)
        {
            Log.d("frame \(frameIndex) writeMissingImages loaded full res image")
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
    
/// Puts a copy of `sourcePath` at `destinationPath`, replacing whatever is there.
///
/// The replacement is one step (see `replacingDestination`): a reader of
/// `destinationPath` finds the file that was there or the new one, never nothing.
func copyReplacingDestination(
  from sourcePath: String,
  to destinationPath: String
) throws {
    try replacingDestination(destinationPath) { temporaryPath in
        try FileManager.default.copyItem(
          atPath: sourcePath,
          toPath: temporaryPath
        )
    }
}

/// Makes `destinationPath` a hard link to `sourcePath`, replacing whatever is there.
///
/// The replacement is one step (see `replacingDestination`): a reader of
/// `destinationPath` finds the file that was there or the new one, never nothing.
func createHardLinkReplacingDestination(
  from sourcePath: String,
  to destinationPath: String
) throws {
    try replacingDestination(destinationPath) { temporaryPath in
        try createHardLink(from: sourcePath, to: temporaryPath)
    }
}

/// Puts a file at `destinationPath`, replacing whatever is there, without the path ever
/// being absent.
///
/// `place` creates the new file at the name it is given, which is beside the destination
/// (same directory, so same volume) and unique to this call.  Renaming that over the
/// destination is the only step another reader can see, and it replaces atomically on
/// every platform we support.
///
/// This used to remove the destination and then create the new file at its path, which
/// leaves a gap in which the path does not exist.  Callers replace files that other
/// frames are working with: on a static-tripod sequence each frame that builds the merged
/// horizon links it over every other frame's merged horizon, while those frames are doing
/// the same, and each one links *from* its own path.  A frame that got there in the gap
/// found nothing to link from, the link failed, the copy that followed failed the same
/// way, and the frame's merge ended with "couldn't be opened because there is no such
/// file" — on some runs and not others, depending on how the frames interleaved.
///
/// The temporary name never outlives the call.  After a rename that replaced the
/// destination it is already gone; it is the only thing left to remove when `place` or
/// the rename failed, and also when the destination was already the same file as the new
/// one, which `rename(2)` treats as a successful no-op and so leaves the temporary name
/// where it was.
private func replacingDestination(
  _ destinationPath: String,
  place: (_ temporaryPath: String) throws -> Void
) throws {
    let temporaryPath = uniqueTemporaryPath(beside: destinationPath)
    defer { try? FileManager.default.removeItem(atPath: temporaryPath) }

    try place(temporaryPath)
    try renameReplacingDestination(from: temporaryPath, to: destinationPath)
}

/// A name no other call will use, in the destination's directory, keeping its extension
/// last so that anything that tells files apart by extension still sees what it would
/// have seen — the same shape `writeMatAtomically` gives its temporary files.
private func uniqueTemporaryPath(beside destinationPath: String) -> String {
    let unique = UUID().uuidString
    let destination = destinationPath as NSString
    let pathExtension = destination.pathExtension
    if pathExtension.isEmpty {
        return "\(destinationPath).tmp.\(unique)"
    }
    return "\(destination.deletingPathExtension).tmp.\(unique).\(pathExtension)"
}

/// Renames `sourcePath` to `destinationPath`, replacing an existing destination in one
/// step.
///
/// POSIX rename(2) does that natively.  The Windows CRT's rename fails with EEXIST when
/// the destination exists, so there it is `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING`
/// — the same thing `std::filesystem::rename` does for `writeMatAtomically`.
private func renameReplacingDestination(
  from sourcePath: String,
  to destinationPath: String
) throws {
    #if os(Windows)
    let success: Bool = sourcePath.withCString(encodedAs: UTF16.self) { srcW in
        destinationPath.withCString(encodedAs: UTF16.self) { dstW in
            MoveFileExW(srcW, dstW, DWORD(MOVEFILE_REPLACE_EXISTING))
        }
    }
    if !success {
        let win32err = Int(GetLastError())
        throw NSError(
            domain: "Win32",
            code: win32err,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "MoveFileExW failed (GetLastError = \(win32err)) "
                    + "replacing '\(destinationPath)' with '\(sourcePath)'"
            ]
        )
    }
    #else
    if rename(sourcePath, destinationPath) != 0 {
        let error = errno
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(error),
            userInfo: [
                NSLocalizedDescriptionKey: String(cString: strerror(error))
            ]
        )
    }
    #endif
}

/// Creates `destinationPath` as a hard link to `sourcePath`, which must not exist yet.
private func createHardLink(
  from sourcePath: String,
  to destinationPath: String
) throws {
    // POSIX has link(2); Windows doesn't. Use Win32 CreateHardLinkW on
    // Windows (via WinSDK), which has the matching semantics: same volume,
    // file content shared, separate directory entry, no symlink follow.
    // Argument order is reversed (Windows takes new-name first, existing
    // file second; POSIX is the opposite).
    #if os(Windows)
    let success: Bool = destinationPath.withCString(encodedAs: UTF16.self) { dstW in
        sourcePath.withCString(encodedAs: UTF16.self) { srcW in
            CreateHardLinkW(dstW, srcW, nil)
        }
    }
    if !success {
        let win32err = Int(GetLastError())
        throw NSError(
            domain: "Win32",
            code: win32err,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "CreateHardLinkW failed (GetLastError = \(win32err)) "
                    + "creating '\(destinationPath)' -> '\(sourcePath)'"
            ]
        )
    }
    #else
    let result = link(sourcePath, destinationPath)
    if result != 0 {
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [
                NSLocalizedDescriptionKey: String(cString: strerror(errno))
            ]
        )
    }
    #endif
}

func farthestFirstOrder(range: Range<Int>) -> [Int] {
    let count = range.count
    guard count > 0 else { return [] }
    if count == 1 { return [range.lowerBound] }

    var result: [Int] = []
    result.reserveCapacity(count)

    // Each interval is inclusive
    struct Interval {
        let low: Int
        let high: Int
    }

    // Queue of intervals to process
    var queue: [Interval] = []
    queue.reserveCapacity(count)

    let low = range.lowerBound
    let high = range.upperBound - 1

    // Seed with first and last
    result.append(low)
    if high != low {
        result.append(high)
    }

    // Remaining interval after removing endpoints
    if low + 1 <= high - 1 {
        queue.append(Interval(low: low + 1, high: high - 1))
    }

    var index = 0
    while index < queue.count {
        let interval = queue[index]
        index += 1

        let mid = (interval.low + interval.high) / 2
        result.append(mid)

        // Left subinterval
        if interval.low <= mid - 1 {
            queue.append(Interval(low: interval.low, high: mid - 1))
        }

        // Right subinterval
        if mid + 1 <= interval.high {
            queue.append(Interval(low: mid + 1, high: interval.high))
        }
    }

    return result
}

/// Ensures that all parent directories for the given file path exist.
/// - Parameter filePath: A file path that may include directories.
/// - Throws: An error if directory creation fails.
public func ensureParentDirectoriesExist(for filePath: String) throws {
    let fileURL = URL(fileURLWithPath: filePath)
    
    // If the path ends with a "/", treat it as a directory.
    let directoryURL: URL
    if fileURL.hasDirectoryPath {
        directoryURL = fileURL
    } else {
        directoryURL = fileURL.deletingLastPathComponent()
    }
    
    guard !directoryURL.path.isEmpty else { return }

    try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: nil
    )
}
