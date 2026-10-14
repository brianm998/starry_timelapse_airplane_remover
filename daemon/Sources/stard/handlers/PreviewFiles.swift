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
            return nil
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
