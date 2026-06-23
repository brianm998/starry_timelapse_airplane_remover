import Foundation
import CoreGraphics
import StarCore
import StarDaemonMessages
import SwiftProtobuf
import logging

// Ensure a frame's outlier groups are in memory before an outlier op. After processing (or a config
// resume) StarCore purges groups to disk to save RAM; this lazily reloads them from the persisted
// binary (no-op when already loaded, or when the frame has no outliers on disk). Mirrors the macOS
// app reloading outliers via FrameViewModel.setOutlierGroups when entering a frame. Shared by the
// Outlier.* and Frame.GetOutlierLabelImage handlers.
func ensureOutliersLoaded(_ frame: FrameAirplaneRemover) async {
    if await frame.getOutlierGroups() == nil {
        try? await frame.loadOutliers(loadOnly: true)
    }
}

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
            await ensureOutliersLoaded(frame)
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
                await ensureOutliersLoaded(frame)
                guard await frame.getOutlierGroups() != nil else { continue } // skip frames with no outliers on disk
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
                    await ensureOutliersLoaded(frame)
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
            guard let refFrame = await session.frame(at: Int(req.referenceFrame)) else {
                await transport.sendError(id: id, message: "reference frame out of range", code: 404); return
            }
            await ensureOutliersLoaded(refFrame)
            guard let refGroups = await refFrame.getOutlierGroups(),
                  let refGroup = await refGroups.get(with: UInt16(req.referenceGroupID)) else {
                await transport.sendError(id: id, message: "reference outlier group not found", code: 404); return
            }
            let count = await session.frameCount
            let start = max(0, Int(req.startIndex)), end = min(count - 1, Int(req.endIndex))
            var resp = Star_V1_MultiFrameDecisionsResponse()
            if start <= end {
                for i in start...end {
                    guard let frame = await session.frame(at: i) else { continue }
                    await ensureOutliersLoaded(frame)
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

    // Single-frame area editing tools (razor / shovel / trash / get-from-trash). Each acts on the
    // rectangle [start_location, end_location] of [frame_index]; mirrors the macOS FrameEditView drag.
    static func applyAreaTool(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_ApplyOutlierAreaToolRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let frame = await session.frame(at: Int(req.frameIndex)) else {
                await transport.sendError(id: id, message: "frame index out of range", code: 404); return
            }
            await ensureOutliersLoaded(frame)
            let a = CGPoint(x: req.startLocation.x, y: req.startLocation.y)
            let b = CGPoint(x: req.endLocation.x, y: req.endLocation.y)
            let bounds = BoundingBox(between: a, and: b)

            // Each StarCore op persists (writes the outliers binary) and marks the frame as needed itself,
            // EXCEPT dumpInTrash — so only the TRASH branch writes/marks here (mirrors macOS, where
            // FrameViewModel.dumpInTrash writes the binary while applyRazor/promoteDust do it internally).
            switch req.tool {
            case .areaToolRazor:
                // applyRazor writes the binary, markAsChanged, and updateCombineSubjects internally (when it changes anything).
                try await frame.applyRazor(in: bounds, includingTrash: req.includingTrash)
            case .areaToolShovel:
                // findOutliers(within:) writes the binary; mirror macOS by completing the frame and marking it changed.
                try await frame.findOutliers(within: bounds)
                await frame.set(state: .complete)
                await frame.markAsChanged()
            case .areaToolTrash:
                if let groups = await frame.getOutlierGroups() {
                    if req.groupID > 0 {
                        // Single-tap: dump exactly the tapped group by id. Use the array overload — the single
                        // dumpInTrash(_:) only adds to trash without removing from members. macOS likewise passes
                        // a 1-element array (FrameViewModel.dumpInTrash(_ badGroup:) → OutlierGroups.dumpInTrash([…])).
                        if let g = await groups.get(with: UInt16(req.groupID)) { await groups.dumpInTrash([g]) }
                    } else {
                        // Drag: dump every member group whose bounding box is fully inside the rectangle (macOS dumpInTrash(between:and:)).
                        let inside = await groups.getMembers().values.filter { bounds.contains(other: $0.bounds) }
                        await groups.dumpInTrash(Array(inside))
                    }
                    await frame.updateCombineSubjects()
                    try? await groups.writeOutliersBinary(to: await frame.outliersDirname)
                    await frame.markAsChanged()
                }
            case .areaToolExtractTrash:
                // promoteDust writes the binary, markAsChanged, and updateCombineSubjects internally.
                _ = try await frame.promoteDust(in: bounds)
            case .areaToolUnspecified, .UNRECOGNIZED:
                await transport.sendError(id: id, message: "unspecified area tool", code: 400); return
            }

            var resp = Star_V1_ApplyOutlierAreaToolResponse()
            resp.frame = await Mapping.frameInfo(frame: frame, outlierGroups: await frame.getOutlierGroups())
            if req.rerender, let ref = await renderPreview(session: session, frameIndex: Int(req.frameIndex), width: frame.width, height: frame.height) {
                resp.preview = ref
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
            await ensureOutliersLoaded(frame)
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
            await ensureOutliersLoaded(frame)
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
