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

            // Generated on demand, like the macOS GUI, which never pre-generates previews on open
            // (it makes them via PreviewOp / ImageAccessor.makeMissingImage as views appear): a
            // freshly opened sequence has none on disk, and without this every Frame.GetPreview
            // would fail and the Kotlin client would show blank frames forever.  For .original this
            // always succeeds (the source frame exists); for processed/aligned types it only
            // succeeds once processing has written that full-resolution image.
            guard let ref = await PreviewFiles.ref(for: frame, mode: starViewMode) else {
                Log.d("Frame.GetPreview: frame \(frameIdx) mode \(starViewMode) unavailable (not generated yet)")
                await transport.sendError(id: id, message: "preview not yet generated: frame \(frameIdx) mode \(starViewMode)"); return
            }
            Log.d("Frame.GetPreview: frame \(frameIdx) mode \(starViewMode) serving \(ref.path)")
            try await transport.respond(id: id, payload: ref.serializedData())
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
            var buf = [UInt16](repeating: 0, count: w * h)

            for group in await groups.members.values {
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
            buf.withUnsafeMutableBytes { raw in
                let mat = MatWrapper(
                    width: w, height: h,
                    cvType: 2, // CV_16UC1
                    bytesPerRow: w * 2,
                    data: raw.baseAddress!,
                    takeOwnership: false
                )
                mat.write(to: labelPath)
            }

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
            await frame.set(cleanMethod: cm)
            // The finished image depends on the method, so it has to be written again.
            await frame.markAsChanged()
            await session.frameEdited(frame)
            let groups = await frame.getOutlierGroups()
            let fi = await session.frameInfo(frame, outlierGroups: groups)
            try await transport.respond(id: id, payload: fi.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }
}
