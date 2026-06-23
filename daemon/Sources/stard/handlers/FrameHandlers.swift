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
            let fi = await Mapping.frameInfo(frame: frame, outlierGroups: groups)
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

            guard let previewPath = frame.imageAccessor.nameForImage(
                frameIndex: frameIdx,
                ofType: starViewMode,
                atSize: .preview
            ) else {
                await transport.sendError(id: id, message: "no preview path for frame \(frameIdx) mode \(starViewMode)"); return
            }

            guard FileManager.default.fileExists(atPath: previewPath) else {
                await transport.sendError(id: id, message: "preview not yet generated: \(previewPath)"); return
            }

            var ref = Star_V1_ImageRef()
            ref.path = previewPath
            ref.width = Int32(frame.width)
            ref.height = Int32(frame.height)
            ref.format = "jpg"
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
            let groups = await frame.getOutlierGroups()
            let fi = await Mapping.frameInfo(frame: frame, outlierGroups: groups)
            try await transport.respond(id: id, payload: fi.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }
}
