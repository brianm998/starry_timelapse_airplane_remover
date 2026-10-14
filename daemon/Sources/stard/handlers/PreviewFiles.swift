import Foundation
import StarCore
import StarDaemonMessages
import logging

/// The on-disk previews a client is shown.  StarCore writes a frame's full-size image of each type
/// when it processes the frame, and makes the smaller preview from it the first time something
/// asks for one (the macOS app does the same through `PreviewOp`).
enum PreviewFiles {
    /// How much older a preview may be than the image it was made from before it counts as stale:
    /// both are written by the same save, one after the other.
    private static let staleAfter: TimeInterval = 2

    /// A reference to `frame`'s preview of `mode`, made first if it is missing, or if it is older than the
    /// full-size image of that type (which is rewritten in place whenever the frame is processed again or
    /// rendered after an edit, so a preview made before that would show the old picture).  `nil` when
    /// there is nothing to show yet, e.g. the type has not been processed.
    static func ref(for frame: FrameAirplaneRemover, mode: FrameViewMode, size: ImageDisplaySize = .preview) async -> Star_V1_ImageRef? {
        let frameIndex = frame.frameIndex
        guard let previewPath = frame.imageAccessor.nameForImage(frameIndex: frameIndex, ofType: mode, atSize: size) else {
            // Not every kind of image has a thumbnail; the preview is the next size up.
            return size == .thumbnail ? await ref(for: frame, mode: mode, size: .preview) : nil
        }
        if isStale(previewPath, madeFrom: frame.imageAccessor.nameForImage(frameIndex: frameIndex, ofType: mode, atSize: .original)) {
            Log.d("preview: frame \(frameIndex) mode \(mode) missing or out of date at \(previewPath) — generating on demand")
            _ = try? await frame.imageAccessor.makeMissingImage(frameIndex: frameIndex, ofType: mode, andSize: size)
        }
        guard FileManager.default.fileExists(atPath: previewPath) else { return nil }
        var ref = Star_V1_ImageRef()
        ref.path = previewPath
        ref.width = Int32(frame.width)
        ref.height = Int32(frame.height)
        ref.format = "jpg"
        return ref
    }

    /// An 8-bit JPEG copy of `frame`'s full-size image of `mode`, in `directory`: what a client that cannot read the pipeline's own
    /// file (a 16-bit TIFF of tens of megapixels) shows when it is asked for the original size.  Made when missing or older than
    /// the image it copies, one at a time since each is a whole frame in memory; nil if the frame has no such image yet.
    static func fullSizeRef(for frame: FrameAirplaneRemover, mode: FrameViewMode, directory: String) async -> Star_V1_ImageRef? {
        let frameIndex = frame.frameIndex
        let source = frame.imageAccessor.nameForImage(frameIndex: frameIndex, ofType: mode, atSize: .original)
        guard let source, FileManager.default.fileExists(atPath: source) else { return nil }
        let path = "\(directory)/frame_\(frameIndex)_\(mode).jpg"
        if isStale(path, madeFrom: source) {
            Log.d("preview: frame \(frameIndex) mode \(mode) full-size copy missing or out of date at \(path) — making it")
            let made = await FullSizeGate.shared.run {
                (try? await frame.imageAccessor.writeFullSizeDisplayCopy(frameIndex: frameIndex, ofType: mode, to: path)) ?? false
            }
            guard made else { return nil }
        }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var ref = Star_V1_ImageRef()
        ref.path = path
        ref.width = Int32(frame.width)
        ref.height = Int32(frame.height)
        ref.format = "jpg"
        return ref
    }

    private static func isStale(_ previewPath: String, madeFrom originalPath: String?) -> Bool {
        guard let previewDate = modificationDate(previewPath) else { return true }
        guard let originalPath, let originalDate = modificationDate(originalPath) else {
            return false   // nothing it could be made from: keep what there is
        }
        return previewDate.addingTimeInterval(staleAfter) < originalDate
    }

    private static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

/// Lets one full-size copy be made at a time: each loads a whole frame (hundreds of megabytes), and the client asks for them as the
/// user scrubs.
actor FullSizeGate {
    static let shared = FullSizeGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ work: @Sendable () async -> T) async -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        let result = await work()
        busy = false
        if !waiters.isEmpty { waiters.removeFirst().resume() }
        return result
    }
}
