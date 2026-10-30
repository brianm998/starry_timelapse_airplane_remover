import Foundation
import StarCore
import StarCppBridge
import StarDaemonMessages
import SwiftProtobuf
import logging

enum FrameHandlers {
    static func get(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_FrameRef(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let frame = await session.frame(at: Int(req.frameIndex)) else {
                await transport.sendError(id: id, message: "frame index out of range", code: 404); return
            }
            let groups = await frame.getOutlierGroups()
            let fi = await session.frameInfo(frame, outlierGroups: groups)
            try await transport.respond(id: id, payload: fi.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    static func getPreview(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_GetFramePreviewRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let frame = await session.frame(at: Int(req.frameIndex)) else {
                await transport.sendError(id: id, message: "frame index out of range", code: 404); return
            }

            let frameIdx = Int(req.frameIndex)
            let starViewMode = Mapping.frameViewMode(from: req.viewMode)

            // A frame of a video that is still being extracted has nothing to show yet.  That is an answer, not a failure: the client
            // draws its placeholder and asks Frame.GetEta how long it will be.
            if !frame.imageAccessor.imageSequence.source.isAvailable(frameIdx) {
                var notYet = Star_V1_ImageRef()
                notYet.notExtracted = true
                try await transport.respond(id: id, payload: notYet.serializedData()); return
            }

            // Generated on demand, like the macOS GUI, which never pre-generates previews on open
            // (it makes them via PreviewOp / ImageAccessor.makeMissingImage as views appear): a
            // freshly opened sequence has none on disk, and without this every Frame.GetPreview
            // would fail and the Kotlin client would show blank frames forever.  For .original this
            // always succeeds (the source frame exists); for processed/aligned types it only
            // succeeds once processing has written that full-resolution image.
            // An aligned view the default mode never wrote: the frame the client is looking at builds it from its homographies.
            if req.buildIfMissing { await PreviewFiles.buildAlignedImageIfNeeded(for: frame, mode: starViewMode) }

            let ref: Star_V1_ImageRef?
            switch req.size {
            case .original:
                ref = await PreviewFiles.fullSizeRef(for: frame, mode: starViewMode,
                                                     directory: "\(await session.scratchSessionDir)/fullres")
            case .thumbnail:
                ref = await PreviewFiles.ref(for: frame, mode: starViewMode, size: .thumbnail)
            default:
                ref = await PreviewFiles.ref(for: frame, mode: starViewMode)
            }
            guard let ref else {
                Log.d("Frame.GetPreview: frame \(frameIdx) mode \(starViewMode) unavailable (not generated yet)")
                await transport.sendError(id: id, message: "preview not yet generated: frame \(frameIdx) mode \(starViewMode)"); return
            }
            Log.d("Frame.GetPreview: frame \(frameIdx) mode \(starViewMode) serving \(ref.path)")
            try await transport.respond(id: id, payload: ref.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    /// `Frame.Prioritize`: the frame the user is looking at and the ones around it, so the extractor fetches them first.  Answers at once.
    static func prioritize(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_PrioritizeFramesRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            var nearby: [Int] = []
            for range in req.nearby where range.end > range.start {
                // A range is a neighbourhood, not a list of frames to extract one by one: bound it.
                nearby += Array(Int(range.start)..<min(Int(range.end), Int(range.start) + 256))
            }
            await session.prioritizeFrames(viewing: Int(req.viewing), nearby: nearby)
            try await transport.respond(id: id, payload: Star_V1_PrioritizeFramesResponse().serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    /// `Frame.GetEta`: how long until a frame that is not extracted yet is.
    static func eta(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_FrameEtaRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            try await transport.respond(id: id, payload: await session.frameEta(Int(req.frameIndex)).serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // Returns a 16-bit single-channel label image; pixel value = outlier group id (0 = none).
    // The Kotlin client uses this for click-to-toggle without round-trips.
    static func getOutlierLabelImage(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_FrameRef(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let frame = await session.frame(at: Int(req.frameIndex)) else {
                await transport.sendError(id: id, message: "frame index out of range", code: 404); return
            }
            await ensureOutliersLoaded(frame)
            guard let groups = await frame.getOutlierGroups() else {
                await transport.sendError(id: id, message: "outlier groups not yet loaded for frame \(req.frameIndex)"); return
            }

            let scratchDir = await session.scratchSessionDir
            let labelsDir = "\(scratchDir)/labels"
            try FileManager.default.createDirectory(atPath: labelsDir, withIntermediateDirectories: true)
            let labelPath = "\(labelsDir)/frame_\(req.frameIndex)_label.png"

            let w = frame.width, h = frame.height

            // The label image only changes when the set of groups does (their pixels never change
            // once found), so a click-heavy session asked for the same image over and over and
            // each time rebuilt and rewrote a frame-sized PNG. Keyed by what the groups are.
            let members = await groups.members
            let version = LabelImageCache.version(of: members.values.map { ($0.id, $0.bounds, $0.pixelSet.count) },
                                                  width: w, height: h)
            let cacheKey = "\(req.sessionID)/\(req.frameIndex)"
            if LabelImageCache.shared.isCurrent(key: cacheKey, version: version, path: labelPath) {
                var ref = Star_V1_ImageRef()
                ref.path = labelPath
                ref.width = Int32(w)
                ref.height = Int32(h)
                ref.format = "png"
                try await transport.respond(id: id, payload: ref.serializedData()); return
            }

            var buf = [UInt16](repeating: 0, count: w * h)

            for group in members.values {
                let gid = UInt16(group.id)
                let bb = group.bounds
                let pixels = group.pixels
                for py in bb.min.y..<bb.max.y {
                    for px in bb.min.x..<bb.max.x {
                        let lx = px - bb.min.x, ly = py - bb.min.y
                        let lidx = ly * bb.width + lx
                        guard lidx < pixels.count, pixels[lidx] > 0 else { continue }
                        let imgIdx = py * w + px
                        guard imgIdx < buf.count else { continue }
                        buf[imgIdx] = gid
                    }
                }
            }

            // Write via MatWrapper — headless, no AppKit needed.
            // CV_16UC1 = 2 in OpenCV type constants.
            // Atomically: the client reads this path as soon as the response arrives, and with
            // two requests for one frame in flight a plain write let it read a half-written file.
            let written = buf.withUnsafeMutableBytes { raw -> Bool in
                let mat = MatWrapper(
                    width: w, height: h,
                    cvType: 2, // CV_16UC1
                    bytesPerRow: w * 2,
                    data: raw.baseAddress!,
                    takeOwnership: false
                )
                return LabelImageCache.writeAtomically(mat, to: labelPath)
            }
            if written { LabelImageCache.shared.record(key: cacheKey, version: version) }

            var ref = Star_V1_ImageRef()
            ref.path = labelPath
            ref.width = Int32(w)
            ref.height = Int32(h)
            ref.format = "png"
            try await transport.respond(id: id, payload: ref.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // Returns an 8-bit single-channel mask of the frame's trashed outlier groups (255 where a trashed pixel is, 0 elsewhere): the
    // client draws it in yellow when the user is showing the trash.  One image rather than a view per group, since there can be
    // thousands (macOS `FrameViewModel.computeTrashImage`).
    static func getOutlierTrashImage(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_FrameRef(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let frame = await session.frame(at: Int(req.frameIndex)) else {
                await transport.sendError(id: id, message: "frame index out of range", code: 404); return
            }
            await ensureOutliersLoaded(frame)
            guard await frame.getOutlierGroups() != nil else {
                await transport.sendError(id: id, message: "outlier groups not yet loaded for frame \(req.frameIndex)"); return
            }

            let scratchDir = await session.scratchSessionDir
            let trashDir = "\(scratchDir)/trash"
            try FileManager.default.createDirectory(atPath: trashDir, withIntermediateDirectories: true)
            let path = "\(trashDir)/frame_\(req.frameIndex)_trash.png"

            let w = frame.width, h = frame.height
            var buf = [UInt8](repeating: 0, count: w * h)
            for group in await frame.outlierGroupTrashList() ?? [] {
                let bb = group.bounds
                let pixels = group.pixels
                for py in max(0, bb.min.y)..<min(h, bb.max.y) {
                    for px in max(0, bb.min.x)..<min(w, bb.max.x) {
                        let lidx = (py - bb.min.y) * bb.width + (px - bb.min.x)
                        guard lidx < pixels.count, pixels[lidx] > 0 else { continue }
                        buf[py * w + px] = 255
                    }
                }
            }
            buf.withUnsafeMutableBytes { raw in
                let mat = MatWrapper(width: w, height: h, cvType: 0 /* CV_8UC1 */, bytesPerRow: w,
                                     data: raw.baseAddress!, takeOwnership: false)
                mat.write(to: path)
            }

            var ref = Star_V1_ImageRef()
            ref.path = path
            ref.width = Int32(w)
            ref.height = Int32(h)
            ref.format = "png"
            try await transport.respond(id: id, payload: ref.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    static func setCleanMethod(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_SetFrameCleanMethodRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let frame = await session.frame(at: Int(req.frameIndex)) else {
                await transport.sendError(id: id, message: "frame index out of range", code: 404); return
            }
            let cm: CleanMethod
            switch req.cleanMethod {
            case .cleanSelective:     cm = .selective
            case .cleanAutomaticTrue: cm = .automatic(true)
            default:                  cm = .automatic(false)
            }
            await session.setCleanMethod(cm, of: frame)
            let groups = await frame.getOutlierGroups()
            let fi = await session.frameInfo(frame, outlierGroups: groups)
            try await transport.respond(id: id, payload: fi.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    /// `Frame.FindOutliers`: find a frame's outlier groups again, inline (see the proto).
    static func findOutliers(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_FindFrameOutliersRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let frame = await session.frame(at: Int(req.frameIndex)) else {
                await transport.sendError(id: id, message: "frame index out of range", code: 404); return
            }
            try await session.findOutliers(of: frame, startOver: req.startOver, type: Mapping.reprocessingType(req.reprocessingType))
            let groups = await frame.getOutlierGroups()
            let fi = await session.frameInfo(frame, outlierGroups: groups)
            try await transport.respond(id: id, payload: fi.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // A frame's own neighbour count: set, or taken away so the sequence's applies again.
    static func setNeighborOverride(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_SetNeighborOverrideRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let frame = await session.frame(at: Int(req.frameIndex)) else {
                await transport.sendError(id: id, message: "frame index out of range", code: 404); return
            }
            let kind: Session.NeighborKind
            switch req.kind {
            case .neighborAligned: kind = .aligned
            case .neighborStatic:  kind = .static
            default:
                await transport.sendError(id: id, message: "unknown neighbour kind", code: 400); return
            }
            let count: Int?
            switch req.change {
            case .count(let n) where n >= 1:
                count = Int(n)
            case .clear(true):
                count = nil
            default:
                await transport.sendError(id: id, message: "give a count of at least 1, or clear", code: 400); return
            }
            var resp = Star_V1_SetNeighborOverrideResponse()
            resp.processingStarted = await session.setNeighborOverride(of: frame, kind: kind, count: count)
            resp.frame = await session.frameInfo(frame, outlierGroups: await frame.getOutlierGroups())
            try await transport.respond(id: id, payload: resp.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }
}


/// The label image for a frame, kept as long as the frame's groups are the same ones.
final class LabelImageCache: @unchecked Sendable {
    static let shared = LabelImageCache()

    private let lock = NSLock()
    private var versions: [String: UInt64] = [:]

    /// A digest of the groups that decide the image: which ones exist, where they are and how big,
    /// and the frame's size. Their pixels never change after detection, so this is the image.
    static func version(of groups: [(UInt16, BoundingBox, Int)], width: Int, height: Int) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ value: Int) { hash ^= UInt64(truncatingIfNeeded: value); hash = hash &* 0x100000001b3 }
        mix(width); mix(height); mix(groups.count)
        // order-independent: members come out of a dictionary
        var sum: UInt64 = 0
        for (id, bounds, size) in groups {
            var h: UInt64 = 0x9e3779b97f4a7c15
            for value in [Int(id), bounds.min.x, bounds.min.y, bounds.max.x, bounds.max.y, size] {
                h ^= UInt64(truncatingIfNeeded: value); h = h &* 0x100000001b3
            }
            sum &+= h
        }
        mix(Int(truncatingIfNeeded: sum))
        return hash
    }

    func isCurrent(key: String, version: UInt64, path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return versions[key] == version && FileManager.default.fileExists(atPath: path)
    }

    func record(key: String, version: UInt64) {
        lock.lock(); versions[key] = version; lock.unlock()
    }

    /// Writes the image beside its destination, under a name the extension of which still says what
    /// format it is (OpenCV picks the encoder from it), then renames it into place.
    static func writeAtomically(_ mat: MatWrapper, to path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).tmp-\(UUID().uuidString).\(url.pathExtension)")
            .path
        mat.write(to: temp)
        guard FileManager.default.fileExists(atPath: temp) else { return false }
        if rename(temp, path) != 0 {
            try? FileManager.default.removeItem(atPath: temp)
            return false
        }
        return true
    }
}
