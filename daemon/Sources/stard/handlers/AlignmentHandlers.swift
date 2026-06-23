import Foundation
import StarCore
import StarDaemonMessages
import SwiftProtobuf
import logging

// Read-only per-frame alignment diagnostics for the client's Alignment window.
// Everything here is headless (no AppKit): persisted homography DB reads + on-disk preview paths.
enum AlignmentHandlers {

    // Alignment.Get — single frame, full detail (homography + aligned-image previews).
    static func get(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_GetAlignmentRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            guard let frame = await session.frame(at: Int(req.frameIndex)) else {
                await transport.sendError(id: id, message: "frame index out of range", code: 404); return
            }
            let config = await session.config()
            let info = await buildInfo(frame: frame, frameIndex: Int(req.frameIndex), config: config,
                                       includeHomography: true, includePreviews: true)
            try await transport.respond(id: id, payload: info.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // Alignment.GetSequence — the whole sequence in one round-trip (drives the window).
    static func getSequence(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_GetAlignmentSequenceRequest(serializedBytes: payload)
            guard let session = await sessions.get(id: req.sessionID) else {
                await transport.sendError(id: id, message: "session not found", code: 404); return
            }
            let config = await session.config()
            let count = await session.frameCount
            var seq = Star_V1_AlignmentSequence()
            for i in 0..<count {
                guard let frame = await session.frame(at: i) else { continue }
                let info = await buildInfo(frame: frame, frameIndex: i, config: config,
                                           includeHomography: req.includeHomography,
                                           includePreviews: req.includePreviews)
                seq.frames.append(info)
            }
            try await transport.respond(id: id, payload: seq.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    // MARK: - builder

    private static func buildInfo(
        frame: FrameAirplaneRemover,
        frameIndex: Int,
        config: Config,
        includeHomography: Bool,
        includePreviews: Bool
    ) async -> Star_V1_AlignmentInfo {
        var info = Star_V1_AlignmentInfo()
        info.frameIndex = Int32(frameIndex)
        info.allowEarthAlignment = config.allowEarthAlignment

        if let star = await frame.readStarNeighborHomographyForThisFrame() {
            info.hasStarResults_p = true
            var results = Mapping.protoHomographyResults(star, includeHomography: includeHomography)
            if includePreviews { setPreviews(on: &results, frame: frame, forStars: true) }
            info.star = results
        }
        if config.allowEarthAlignment, let earth = await frame.readEarthNeighborHomographyForThisFrame() {
            info.hasEarthResults_p = true
            var results = Mapping.protoHomographyResults(earth, includeHomography: includeHomography)
            if includePreviews { setPreviews(on: &results, frame: frame, forStars: false) }
            info.earth = results
        }

        // Keypoint counts read 0 when features aren't loaded; report -1 (unknown) unless we have results.
        info.numSkyKeypoints   = info.hasStarResults_p  ? Int32(await frame.skyKeyPointCount())   : -1
        info.numEarthKeypoints = info.hasEarthResults_p ? Int32(await frame.earthKeyPointCount()) : -1

        let neighbors = config.tripodHeadWasMoving
            ? await frame.getAlignmentFrameIndices()
            : await frame.getStaticNeighborFrames()
        info.alignmentFrameIndices = neighbors.map { Int32($0) }
        return info
    }

    // Attach the aligned (or failed-aligned) preview path for each neighbor pair, if on disk.
    private static func setPreviews(on results: inout Star_V1_HomographyResults, frame: FrameAirplaneRemover, forStars: Bool) {
        for i in results.neighbors.indices {
            let state = results.neighbors[i].state
            let ok = (state == .alignHomographySuccess || state == .alignUsedExistingHomography)
            let mode: StarCore.FrameViewMode = forStars
                ? (ok ? .starAligned : .failedStarAligned)
                : (ok ? .earthAligned : .failedEarthAligned)
            guard let path = frame.imageAccessor.nameForImage(
                    frameIndex: Int(results.neighbors[i].frameIndex), ofType: mode, atSize: .preview),
                  FileManager.default.fileExists(atPath: path)
            else { continue }
            var ref = Star_V1_ImageRef()
            ref.path = path
            ref.format = "jpg"
            results.neighbors[i].alignedPreview = ref
        }
    }
}
