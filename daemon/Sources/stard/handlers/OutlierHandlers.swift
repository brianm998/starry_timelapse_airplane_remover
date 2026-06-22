import Foundation
import StarCore
import StarDaemonMessages
import SwiftProtobuf
import logging

enum OutlierHandlers {
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
