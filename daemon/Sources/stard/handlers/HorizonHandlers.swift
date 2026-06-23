import Foundation
import StarCore
import StarDaemonMessages
import SwiftProtobuf
import logging

// Reference-horizon painting: accept a painted horizon line, store it as StarCore's reference mask,
// read the current one back (for re-painting), clear it, and reprocess with it.
enum HorizonHandlers {

    static func setReference(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_SetReferenceHorizonRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let frame = await session.frame(at: Int(req.frameIndex)) else {
                await transport.sendError(id: id, message: "frame index out of range", code: 404); return
            }

            switch req.source {
            case .columns(let cols):
                // -1 sentinel → nil (unpainted/all-sky). StarCore scales view→image + interpolates.
                let ys: [Int?] = cols.horizonY.map { $0 < 0 ? nil : Int($0) }
                try await frame.saveHorizonReferenceMask(
                    paintedYPerColumn: ys,
                    viewWidth: Int(cols.spaceWidth),
                    viewHeight: Int(cols.spaceHeight))
            case .maskPath:
                await transport.sendError(id: id, message: "mask_path source not supported; send HorizonColumns"); return
            case .none:
                await transport.sendError(id: id, message: "no horizon source provided"); return
            }

            let config = await session.config()
            if req.setStaticReference && !config.tripodHeadWasMoving {
                await session.setStaticReferenceHorizon(true)
            }
            let finalConfig = await session.config()

            var resp = Star_V1_SetReferenceHorizonResponse()
            if let path = frame.imageAccessor.nameForImage(frameIndex: Int(req.frameIndex), ofType: .userHorizon, atSize: .original) {
                var ref = Star_V1_ImageRef()
                ref.path = path
                ref.width = Int32(frame.width)
                ref.height = Int32(frame.height)
                ref.format = "tiff"
                resp.referenceMask = ref
            }
            resp.isGlobal = finalConfig.hasStaticReferenceHorizon && !finalConfig.tripodHeadWasMoving
            try await transport.respond(id: id, payload: resp.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    static func getReference(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_GetReferenceHorizonRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let frame = await session.frame(at: Int(req.frameIndex)) else {
                await transport.sendError(id: id, message: "frame index out of range", code: 404); return
            }

            var resp = Star_V1_GetReferenceHorizonResponse()
            let exists = await frame.hasHorizonReference
            resp.exists = exists
            if exists {
                if let path = frame.imageAccessor.nameForImage(frameIndex: Int(req.frameIndex), ofType: .userHorizon, atSize: .original) {
                    var ref = Star_V1_ImageRef()
                    ref.path = path
                    ref.width = Int32(frame.width)
                    ref.height = Int32(frame.height)
                    ref.format = "tiff"
                    resp.referenceMask = ref
                }
                // Per-column horizon-Y in image space, for re-painting.
                if let ys = try? await frame.loadBestExistingHorizonAsViewY(viewWidth: frame.width, viewHeight: frame.height) {
                    var cols = Star_V1_HorizonColumns()
                    cols.spaceWidth = Int32(frame.width)
                    cols.spaceHeight = Int32(frame.height)
                    cols.horizonY = ys.map { Int32($0 ?? -1) }
                    resp.columns = cols
                }
            }
            try await transport.respond(id: id, payload: resp.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // Per-frame horizon overlay (kind + per-column Y) for the grid; nil overlay → exists=false.
    static func getOverlay(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_GetHorizonOverlayRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let frame = await session.frame(at: Int(req.frameIndex)) else {
                await transport.sendError(id: id, message: "frame index out of range", code: 404); return
            }
            let w = req.width > 0 ? Int(req.width) : frame.width
            let h = req.height > 0 ? Int(req.height) : frame.height
            var resp = Star_V1_GetHorizonOverlayResponse()
            if let overlay = try await frame.loadHorizonThumbnailOverlay(thumbnailWidth: w, thumbnailHeight: h) {
                resp.exists = true
                resp.kind = Mapping.horizonOverlayKind(overlay.kind)
                resp.yPerColumn = overlay.yPerColumn.map { Int32($0) }
                resp.height = Int32(overlay.height)
            } else {
                resp.exists = false
            }
            try await transport.respond(id: id, payload: resp.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    static func clearReference(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_ClearReferenceHorizonRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let frame = await session.frame(at: Int(req.frameIndex)) else {
                await transport.sendError(id: id, message: "frame index out of range", code: 404); return
            }
            let config = await session.config()
            // Remove the per-frame user-horizon file.
            if let perFrame = frame.imageAccessor.nameForImage(frameIndex: Int(req.frameIndex), ofType: .userHorizon, atSize: .original) {
                try? FileManager.default.removeItem(atPath: perFrame)
            }
            if req.clearGlobal_p {
                try? FileManager.default.removeItem(atPath: "\(config.tempOutputPath)/horizonReference/reference.tiff")
                if config.hasStaticReferenceHorizon { await session.setStaticReferenceHorizon(false) }
            }
            try await transport.respond(id: id, payload: Star_V1_ClearReferenceHorizonResponse().serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // Reprocess with the (already-set) reference horizon; streams ProgressEvent like Processing.StreamProgress.
    static func reprocess(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_ReprocessHorizonsRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            let (stream, cont) = AsyncStream<Star_V1_ProgressEvent>.makeStream()
            await session.setProgressContinuation(cont)
            // Re-run the frame graph; with hasStaticReferenceHorizon set, ops read reference.tiff directly.
            await session.reprocessWithReferenceHorizon()
            do {
                for await event in stream {
                    try Task.checkCancellation()
                    if let data = try? event.serializedData() {
                        await transport.sendStreamItem(id: id, payload: data)
                    }
                }
            } catch is CancellationError {
                // cancelled via CANCEL envelope
            }
            await transport.sendStreamEnd(id: id)
            await session.setProgressContinuation(nil)
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }
}
