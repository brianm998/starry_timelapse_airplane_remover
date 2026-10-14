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
            resp.refinementPending = await session.isRefinementPending(Int(req.frameIndex))
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

    // Run a horizon detector over a user-painted band (the live painter): COMBINED_SIOX for the
    // initial detect, RANDOM_WALKER for sky/ground refinement. Pure per-frame compute — no state
    // mutation; returns the per-column horizon line for the client to display and (later) save.
    static func computeInBand(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_ComputeHorizonInBandRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let frame = await session.frame(at: Int(req.frameIndex)) else {
                await transport.sendError(id: id, message: "frame index out of range", code: 404); return
            }

            // -1 sentinel → nil. top/bottom always present; known_* may be empty (=> nil).
            func toOptional(_ a: [Int32]) -> [Int?] { a.map { $0 < 0 ? nil : Int($0) } }
            func toOptionalOrNil(_ a: [Int32]) -> [Int?]? { a.isEmpty ? nil : toOptional(a) }
            let top = toOptional(req.topBoundaryY)
            let bottom = toOptional(req.bottomBoundaryY)
            let skyFloor = toOptionalOrNil(req.knownSkyFloorY)
            let gndCeiling = toOptionalOrNil(req.knownGroundCeilingY)
            let vw = Int(req.spaceWidth)
            let vh = Int(req.spaceHeight)

            let horizon: [Int?]
            switch req.method {
            case .randomWalker:
                let beta = req.beta > 0 ? req.beta : 90.0
                horizon = try await frame.computeRandomWalkerHorizon(
                    topBoundaryY: top, bottomBoundaryY: bottom,
                    viewWidth: vw, viewHeight: vh,
                    knownSkyFloorY: skyFloor, knownGroundCeilingY: gndCeiling, beta: beta)
            default: // COMBINED_SIOX / UNSPECIFIED
                horizon = try await frame.computeCombinedHorizonInBand(
                    topBoundaryY: top, bottomBoundaryY: bottom,
                    viewWidth: vw, viewHeight: vh,
                    knownSkyFloorY: skyFloor, knownGroundCeilingY: gndCeiling)
            }

            var resp = Star_V1_ComputeHorizonInBandResponse()
            var cols = Star_V1_HorizonColumns()
            cols.spaceWidth = Int32(vw)
            cols.spaceHeight = Int32(vh)
            cols.horizonY = horizon.map { Int32($0 ?? -1) }
            resp.columns = cols
            try await transport.respond(id: id, payload: resp.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // Best existing horizon (user reference > merged > raw) as per-column Y, for seeding the painter
    // when re-opening a frame that already has a (possibly auto-computed) horizon. exists=false → none.
    static func getBest(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_GetBestHorizonRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let frame = await session.frame(at: Int(req.frameIndex)) else {
                await transport.sendError(id: id, message: "frame index out of range", code: 404); return
            }
            let vw = req.spaceWidth > 0 ? Int(req.spaceWidth) : frame.width
            let vh = req.spaceHeight > 0 ? Int(req.spaceHeight) : frame.height

            var resp = Star_V1_GetBestHorizonResponse()
            if let ys = try? await frame.loadBestExistingHorizonAsViewY(viewWidth: vw, viewHeight: vh) {
                resp.exists = true
                var cols = Star_V1_HorizonColumns()
                cols.spaceWidth = Int32(vw)
                cols.spaceHeight = Int32(vh)
                cols.horizonY = ys.map { Int32($0 ?? -1) }
                resp.columns = cols
            } else {
                resp.exists = false
            }
            try await transport.respond(id: id, payload: resp.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // Horizon.ReferenceUpdated: the reference of a frame was saved.  Marks the frames that interpolate from it as
    // pending (with apply_to_nearby) and says what a re-run would touch, for the "now or later?" question.
    static func referenceUpdated(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_HorizonReferenceUpdatedRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard await session.frame(at: Int(req.frameIndex)) != nil else {
                await transport.sendError(id: id, message: "frame index out of range", code: 404); return
            }
            var resp = Star_V1_HorizonReferenceUpdatedResponse()
            if let counts = await session.horizonReferenceUpdated(frameIndex: Int(req.frameIndex), applyToNearby: req.applyToNearby) {
                resp.affectedFrameCount = Int32(counts.frameCount)
                resp.renderCount = Int32(counts.renderCount)
            }
            try await transport.respond(id: id, payload: resp.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // The tuned horizon parameters are one file for the whole sequence, but are read and written through a frame's
    // horizon processor, which knows where the sequence's directory is; any frame will do.
    private static func tunedParameters(_ params: HorizonTunedParameters, config: Config) -> Star_V1_TunedHorizonParametersResponse {
        var resp = Star_V1_TunedHorizonParametersResponse()
        resp.maxDownwardExtension = Int32(params.maxDownwardExtension)
        resp.effectiveMaxDownwardExtension = Int32(HorizonTunedParameters.effectiveMaxDownwardExtension(
            configured: params.maxDownwardExtension,
            searchRadius: config.referenceHorizonBrightnessRefinementSearchRadius))
        return resp
    }

    // Horizon.GetTunedParameters
    static func getTunedParameters(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_SessionRef(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let frame = await session.frame(at: 0) else {
                await transport.sendError(id: id, message: "the sequence has no frames", code: 404); return
            }
            let params = await frame.loadTunedHorizonParameters()
            let resp = tunedParameters(params, config: await session.config())
            try await transport.respond(id: id, payload: resp.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // Horizon.SetTunedParameters: change the stepper's value, leaving the other tuned parameters as they are.  It reaches a frame's
    // horizon the next time that frame's merged horizon is built, not the ones already on disk.
    static func setTunedParameters(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_SetTunedHorizonParametersRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let frame = await session.frame(at: 0) else {
                await transport.sendError(id: id, message: "the sequence has no frames", code: 404); return
            }
            var params = await frame.loadTunedHorizonParameters()
            params.maxDownwardExtension = max(0, Int(req.maxDownwardExtension))
            try await frame.saveTunedHorizonParameters(params)
            let resp = tunedParameters(params, config: await session.config())
            try await transport.respond(id: id, payload: resp.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // Horizon.GetRefinementStatus: whether any refinement is waiting.
    static func refinementStatus(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_SessionRef(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            let status = await session.horizonRefinementStatus()
            var resp = Star_V1_RefinementStatusResponse()
            resp.pending = status.pending
            resp.pendingFrameCount = Int32(status.markedFrames)
            try await transport.respond(id: id, payload: resp.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // Horizon.DeferRefinement: "Later".
    static func deferRefinement(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_SessionRef(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            await session.deferHorizonRefinement()
            try await transport.respond(id: id, payload: Star_V1_DeferRefinementResponse().serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // Horizon.RunRefinement: "Now".  Answers once the work is queued.
    static func runRefinement(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_SessionRef(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            var resp = Star_V1_RunRefinementResponse()
            resp.started = await session.runHorizonRefinement()
            try await transport.respond(id: id, payload: resp.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // Horizon.Reprocess (deprecated): for each edited frame what Horizon.ReferenceUpdated does, then what
    // Horizon.RunRefinement does; streams the run's ProgressEvents and ends when the run does (at once, if there
    // is nothing to run).  It is a subscriber of its own for that long, alongside the client's long-lived
    // Processing.StreamProgress, which hears the same events.
    static func reprocess(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_ReprocessHorizonsRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            let (stream, cont) = AsyncStream<Star_V1_ProgressEvent>.makeStream()
            let token = await session.addProgressSubscriber(cont)
            for index in req.editedFrameIndices {
                _ = await session.horizonReferenceUpdated(frameIndex: Int(index), applyToNearby: true)
            }
            let started = await session.runHorizonRefinement()
            if started {
                do {
                    for await event in stream {
                        try Task.checkCancellation()
                        if let data = try? event.serializedData() {
                            await transport.sendStreamItem(id: id, payload: data)
                        }
                        // The run's last event; nothing more is coming for this request.
                        if case .sequenceState(let s) = event.kind, ProcessingRun.isTerminal(s.state) { break }
                    }
                } catch is CancellationError {
                    // cancelled via CANCEL envelope
                }
            }
            await session.removeProgressSubscriber(token)
            await transport.sendStreamEnd(id: id)
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }
}
