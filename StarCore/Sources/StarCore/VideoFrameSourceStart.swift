import Foundation
import logging

extension VideoFrameSource {

    /// `<video dir>/<sanitized video name>/`, where a video's frames go (the gui, the daemon and the cli all use it).
    ///
    /// With `parentFolder` the frames go in `<parentFolder>/<sanitized video name>/` instead, for a user who has pointed the working
    /// files at another volume.
    ///
    /// Sanitizes only the new folder's name.  Sanitizing the whole path turned a Windows path like C:\Users\me\Desktop\x.mp4 into the
    /// relative path C__Users_me_Desktop_x, which ffmpeg then failed to write to (EIO, -5).
    public static func outputFolder(forVideoAt videoPath: String, in parentFolder: String? = nil) -> String {
        let url = URL(fileURLWithPath: videoPath)
        let parent = parentFolder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? url.deletingLastPathComponent()
        return parent
          .appendingPathComponent(url.deletingPathExtension().lastPathComponent.sanitized)
          .path
    }

    /// Sets up the extraction of a video's frames and starts it, returning at once: the frames arrive in the background.
    ///
    /// `requireExactCount`: the frame count is read exactly (the header's own, else a packet count) rather than estimated from the
    /// duration, so that it never changes under a client that has already sized its frame arrays to it.
    public static func make(
      videoPath: String,
      format: FrameDecodeFormat = .tiff16,
      settings: FrameExtractionSettings = .default,
      requireExactCount: Bool = true,
      framesParentFolder: String? = nil
    ) async throws -> VideoFrameSource {
        let folder = outputFolder(forVideoAt: videoPath, in: framesParentFolder)
        let fileManager = FileManager.default
        let createdOutputFolder = !fileManager.fileExists(atPath: folder)

        // Probing can be a probe that cannot be interrupted, so the work is done off the cooperative pool, in one task whose result
        // is awaited; the first place a caller that gave up on the video is noticed is after it.
        let prepared = await Task.detached { () -> Prepared in
            prepare(videoPath: videoPath, folder: folder, format: format, settings: settings, requireExactCount: requireExactCount)
        }.value
        try Task.checkCancellation()

        var existing = IndexSet()
        var usedFormat = format
        var digits = prepared.digits
        var accessKind = prepared.accessKind
        var count = prepared.frameCount
        var exact = prepared.countIsExact

        if let sidecar = FrameExtractionSidecar.read(inFolder: folder) {
            // Frames of this video are already there (an extraction that was interrupted, or finished): carry on from them.
            guard sidecar.matchesVideo(), sidecar.videoPath == videoPath else {
                throw FrameSourceError("\(folder) holds the frames of a different version of this video")
            }
            usedFormat = sidecar.format
            digits = sidecar.digits
            accessKind = sidecar.accessKind
            if sidecar.countIsExact || !exact { count = sidecar.frameCount; exact = sidecar.countIsExact }
            existing = existingFrames(inFolder: folder, count: count, digits: digits, fileExtension: usedFormat.fileExtension)
        } else if fileManager.fileExists(atPath: folder), containsFrames(folder) {
            throw FrameSourceError("\(folder) already holds image files that were not extracted from this video")
        }

        guard count > 0 else { throw FrameSourceError("could not tell how many frames \((videoPath as NSString).lastPathComponent) has") }
        try? fileManager.createDirectory(atPath: folder, withIntermediateDirectories: true)

        let source = VideoFrameSource(
          videoPath: videoPath,
          outputFolder: folder,
          format: usedFormat,
          frameCount: count,
          countIsExact: exact,
          accessKind: accessKind,
          times: prepared.times,
          settings: settings,
          digits: digits,
          existingFrames: existing,
          createdOutputFolder: createdOutputFolder)
        Log.i("extracting \(count) frames of \(videoPath) (\(accessKind), \(exact ? "exact" : "estimated") count, " +
              "\(existing.count) already there) into \(folder)")
        source.start()
        return source
    }

    private struct Prepared: Sendable {
        var frameCount: Int
        var countIsExact: Bool
        var accessKind: FrameAccessKind
        var times: VideoFrameTimes?
        var digits: Int
    }

    private static func prepare(
      videoPath: String, folder: String, format: FrameDecodeFormat,
      settings: FrameExtractionSettings, requireExactCount: Bool
    ) -> Prepared {
        let probe = VideoProbe.probe(videoAt: videoPath)
        let wantsJumps = settings.maxJumpWorkers > 0 || settings.maxLongGOPJumpWorkers > 0

        var count = probe?.frameCount ?? 0
        var exact = probe?.frameCountIsExact ?? false
        var times: VideoFrameTimes?
        // A table of when each frame is shown, for a jump to seek by.  It is also the exact count: one entry per frame.
        if wantsJumps || (requireExactCount && !exact) {
            times = VideoFrameTimes.read(videoAt: videoPath, expectedFrames: exact ? count : nil)
            if let times, !exact {
                count = times.count
                exact = true
            }
        }
        if count == 0 || (requireExactCount && !exact) {
            // A packet count (demuxes without decoding), then a decode of everything; the estimate stands if neither answers.
            if let counted = videoPacketCount(of: videoPath, ffprobePath: ToolPaths.ffprobe) {
                count = counted
                exact = true
            } else if count == 0 {
                count = videoFrameCount(of: videoPath, ffprobePath: ToolPaths.ffprobe)
            }
        }
        // No table is no jumps: a table that is wrong would write the wrong picture under a name, and even spacing is only
        // right for a constant-rate video, which the table's own mismatch with the count is the sign that this is not.
        let kind = VideoAccess.accessKind(videoAt: videoPath, codecName: probe?.codecName)
        return Prepared(frameCount: count, countIsExact: exact, accessKind: kind, times: times,
                        digits: FrameNaming.digits(forFrameCount: count))
    }

    private static func containsFrames(_ folder: String) -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return contents.contains { $0.hasPrefix("image_") && ($0.hasSuffix(".tiff") || $0.hasSuffix(".jpg")) }
    }

    /// The frames a folder already holds, by their final names (a file with its final name is complete: see the class comment).
    static func existingFrames(inFolder folder: String, count: Int, digits: Int, fileExtension: String) -> IndexSet {
        let contents = Set((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
        var found = IndexSet()
        for index in 0..<count
        where contents.contains(FrameNaming.fileName(forFrame: index, digits: digits, fileExtension: fileExtension)) {
            found.insert(index)
        }
        return found
    }
}

/// Opens the frames of a sequence from whatever its folder says it is.
public enum FrameSourceFactory {

    /// A folder with an `extraction.json` that is not `complete` is a video still (or no longer) being extracted: it gets a
    /// `VideoFrameSource` that carries on from the frames that are there.  Everything else is an image sequence, exactly as before.
    /// When the video is gone or has changed, what is there is opened as it is (and the caller can look at the sidecar to say so);
    /// frames are never deleted.
    public static func open(
      directory: String,
      supportedImageFileTypes: [String],
      settings: FrameExtractionSettings = .default
    ) async throws -> FrameSource {
        if let sidecar = FrameExtractionSidecar.read(inFolder: directory), !sidecar.complete {
            if sidecar.matchesVideo(), ToolPaths.isAvailable {
                return try await VideoFrameSource.make(videoPath: sidecar.videoPath, format: sidecar.format, settings: settings)
            }
            Log.w("\(directory) holds part of a video that is no longer there or has changed; opening the frames that are")
        }
        return try DirectoryFrameSource(dirname: directory, supportedImageFileTypes: supportedImageFileTypes)
    }

    /// Whether `directory` holds the frames of a video that was not fully extracted, and the video it was extracted from is not
    /// available to carry on from.
    public static func isIncompleteAndUnresumable(directory: String) -> Bool {
        guard let sidecar = FrameExtractionSidecar.read(inFolder: directory), !sidecar.complete else { return false }
        return !sidecar.matchesVideo()
    }
}
