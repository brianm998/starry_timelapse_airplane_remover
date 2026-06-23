import Foundation
import CoreGraphics
import StarCore
import StarDaemonMessages
import SwiftProtobuf
import logging

enum OutlierHandlers {

    // Render the current decisions of [frame] to a preview PNG; returns its ImageRef (nil on failure).
    private static func renderPreview(session: Session, frameIndex: Int, width: Int, height: Int) async -> Star_V1_ImageRef? {
        let scratchDir = await session.scratchSessionDir
        let previewDir = "\(scratchDir)/previews"
        try? FileManager.default.createDirectory(atPath: previewDir, withIntermediateDirectories: true)
        let previewPath = "\(previewDir)/frame_\(frameIndex)_rendered.png"
        let imageSequence = await session.imageSequence
        let filenames = await imageSequence.filenames
        guard frameIndex < filenames.count else { return nil }
        let loader = await imageSequence.getImage(withName: filenames[frameIndex])
        guard let image = try? await loader.image() else { return nil }
        image.writeTIFFEncoding(toFilename: previewPath)
        var ref = Star_V1_ImageRef()
        ref.path = previewPath; ref.width = Int32(width); ref.height = Int32(height); ref.format = "png"
        return ref
    }

    // Re-run the decision-tree classifier over one frame's outlier groups.
    static func applyDecisionTree(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_ApplyDecisionTreeRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let frame = await session.frame(at: Int(req.frameIndex)) else {
                await transport.sendError(id: id, message: "frame index out of range", code: 404); return
            }
            let minSize = req.minimumSize > 0 ? Int(req.minimumSize) : nil
            if req.autoOnly {
                await frame.applyDecisionTreeToAutoSelectedOutliers(includingTrash: req.includingTrash, overwrite: req.overwrite, minimumSize: minSize)
            } else {
                await frame.applyDecisionTreeToAllOutliers(overwrite: req.overwrite, minimumSize: minSize)
            }
            await frame.markAsChanged()
            var resp = Star_V1_ApplyDecisionTreeResponse()
            resp.frame = await Mapping.frameInfo(frame: frame, outlierGroups: await frame.getOutlierGroups())
            if req.rerender, let ref = await renderPreview(session: session, frameIndex: Int(req.frameIndex), width: frame.width, height: frame.height) {
                resp.preview = ref
            }
            try await transport.respond(id: id, payload: resp.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // Re-run the decision-tree classifier over every frame's outlier groups.
    static func applyDecisionTreeAllFrames(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_ApplyDecisionTreeAllFramesRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            let minSize = req.minimumSize > 0 ? Int(req.minimumSize) : nil
            let count = await session.frameCount
            var resp = Star_V1_ApplyDecisionTreeAllFramesResponse()
            for i in 0..<count {
                guard let frame = await session.frame(at: i) else { continue }
                guard await frame.getOutlierGroups() != nil else { continue } // skip frames with no loaded outliers
                await frame.applyDecisionTreeToAllOutliers(overwrite: req.overwrite, minimumSize: minSize)
                await frame.markAsChanged()
                resp.frames.append(await Mapping.frameInfo(frame: frame, outlierGroups: await frame.getOutlierGroups()))
            }
            try await transport.respond(id: id, payload: resp.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // Bulk keep/remove for outliers inside a rectangular AREA across a frame range.
    static func setDecisionsInArea(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_SetOutlierDecisionsInAreaRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            let count = await session.frameCount
            let start = max(0, Int(req.startIndex)), end = min(count - 1, Int(req.endIndex))
            let a = CGPoint(x: req.startLocation.x, y: req.startLocation.y)
            let b = CGPoint(x: req.endLocation.x, y: req.endLocation.y)
            var resp = Star_V1_MultiFrameDecisionsResponse()
            if start <= end {
                for i in start...end {
                    guard let frame = await session.frame(at: i) else { continue }
                    if req.overlapping {
                        // For each group touching the area, propagate the decision to groups overlapping it.
                        _ = await frame.foreachOutlierGroupMulti(between: a, and: b, includingTrash: req.includingTrash) { group, _ in
                            _ = await frame.userSelectAllOutliers(toShouldRemove: req.shouldRemove, overlapping: group)
                            return true
                        }
                    } else {
                        await frame.userSelectAllOutliers(toShouldRemove: req.shouldRemove, between: a, and: b, includingTrash: req.includingTrash)
                    }
                    await frame.markAsChanged()
                    await frame.writeOutliersRemoveReasons()
                    resp.frames.append(await Mapping.frameInfo(frame: frame, outlierGroups: await frame.getOutlierGroups()))
                    if req.rerender, let ref = await renderPreview(session: session, frameIndex: i, width: frame.width, height: frame.height) {
                        resp.previews.append(ref)
                    }
                }
            }
            try await transport.respond(id: id, payload: resp.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // Bulk keep/remove for outliers OVERLAPPING a reference group, across a frame range.
    static func setDecisionsOverlapping(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_SetOutlierDecisionsOverlappingRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let refFrame = await session.frame(at: Int(req.referenceFrame)),
                  let refGroups = await refFrame.getOutlierGroups(),
                  let refGroup = await refGroups.get(with: UInt16(req.referenceGroupID)) else {
                await transport.sendError(id: id, message: "reference outlier group not found", code: 404); return
            }
            let count = await session.frameCount
            let start = max(0, Int(req.startIndex)), end = min(count - 1, Int(req.endIndex))
            var resp = Star_V1_MultiFrameDecisionsResponse()
            if start <= end {
                for i in start...end {
                    guard let frame = await session.frame(at: i) else { continue }
                    _ = await frame.userSelectAllOutliers(toShouldRemove: req.shouldRemove, overlapping: refGroup)
                    await frame.markAsChanged()
                    await frame.writeOutliersRemoveReasons()
                    resp.frames.append(await Mapping.frameInfo(frame: frame, outlierGroups: await frame.getOutlierGroups()))
                    if req.rerender, let ref = await renderPreview(session: session, frameIndex: i, width: frame.width, height: frame.height) {
                        resp.previews.append(ref)
                    }
                }
            }
            try await transport.respond(id: id, payload: resp.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }
    static func list(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_FrameRef(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let frame = await session.frame(at: Int(req.frameIndex)) else {
                await transport.sendError(id: id, message: "frame index out of range", code: 404); return
            }
            guard let groups = await frame.getOutlierGroups() else {
                await transport.sendError(id: id, message: "outlier groups not yet loaded"); return
            }
            var list = Star_V1_OutlierGroupList()
            for group in await groups.members.values {
                var pg = Star_V1_OutlierGroup()
                pg.id = UInt32(group.id)
                pg.size = UInt64(group.size)
                pg.bounds = Mapping.protoBoundingBox(group.bounds)
                pg.brightness = UInt64(group.brightness)
                let rr = await group.shouldRemove()
                pg.shouldRemove = Mapping.protoRemoveReason(rr)

                if let rr, case .fromClassifier(let score) = rr {
                    pg.classificationScore = score
                }

                if let line = await group.line() {
                    var pl = Star_V1_Line()
                    pl.theta = line.theta
                    pl.rho = line.rho
                    pl.votes = Int32(line.votes)
                    pg.line = pl
                }
                list.groups.append(pg)
            }
            try await transport.respond(id: id, payload: list.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    static func setDecisions(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_SetOutlierDecisionsRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let frame = await session.frame(at: Int(req.frameIndex)) else {
                await transport.sendError(id: id, message: "frame index out of range", code: 404); return
            }
            guard let groups = await frame.getOutlierGroups() else {
                await transport.sendError(id: id, message: "outlier groups not yet loaded"); return
            }

            let membersDict = await groups.members

            for decision in req.decisions {
                if let group = membersDict[UInt16(decision.groupID)],
                   let reason = Mapping.removeReason(from: decision.decision) {
                    _ = await group.shouldRemove(reason)
                }
            }

            await frame.markAsChanged()

            var resp = Star_V1_SetOutlierDecisionsResponse()
            resp.frame = await Mapping.frameInfo(frame: frame, outlierGroups: groups)

            if req.rerender {
                let scratchDir = await session.scratchSessionDir
                let previewDir = "\(scratchDir)/previews"
                try FileManager.default.createDirectory(atPath: previewDir, withIntermediateDirectories: true)
                let previewPath = "\(previewDir)/frame_\(req.frameIndex)_rendered.png"

                let imageSequence = await session.imageSequence
                let filenames = await imageSequence.filenames
                let frameIdx = Int(req.frameIndex)
                if frameIdx < filenames.count {
                    let loader = await imageSequence.getImage(withName: filenames[frameIdx])
                    let image = try await loader.image()
                    image.writeTIFFEncoding(toFilename: previewPath)
                    var ref = Star_V1_ImageRef()
                    ref.path = previewPath
                    ref.width = Int32(frame.width)
                    ref.height = Int32(frame.height)
                    ref.format = "png"
                    resp.preview = ref
                }
            }

            try await transport.respond(id: id, payload: resp.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    static func renderFrame(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_FrameRef(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let frame = await session.frame(at: Int(req.frameIndex)) else {
                await transport.sendError(id: id, message: "frame index out of range", code: 404); return
            }
            let scratchDir = await session.scratchSessionDir
            let previewDir = "\(scratchDir)/previews"
            try FileManager.default.createDirectory(atPath: previewDir, withIntermediateDirectories: true)
            let previewPath = "\(previewDir)/frame_\(req.frameIndex)_rendered.png"

            let imageSequence = await session.imageSequence
            let filenames = await imageSequence.filenames
            let frameIdx = Int(req.frameIndex)
            guard frameIdx < filenames.count else {
                await transport.sendError(id: id, message: "frame index out of range", code: 404); return
            }
            let loader = await imageSequence.getImage(withName: filenames[frameIdx])
            let image = try await loader.image()
            image.writeTIFFEncoding(toFilename: previewPath)

            var ref = Star_V1_ImageRef()
            ref.path = previewPath
            ref.width = Int32(frame.width)
            ref.height = Int32(frame.height)
            ref.format = "png"
            try await transport.respond(id: id, payload: ref.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }
}
