import Foundation
import StarCore
import StarCppBridge
import StarDaemonMessages

/// The outlier window's Hough-line panel: the lines the finder proposes for a group, choosing one of them as the group's line, and the
/// finder's arguments (macOS `HoughLinesTableView` / `ArgableView`).
enum LineHandlers {

    // ---- the lines proposed for one group ----

    static func getCandidates(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_GetLineCandidatesRequest(serializedBytes: payload)
            guard let group = await findGroup(sessionID: req.sessionID, frameIndex: Int(req.frameIndex), groupID: req.groupID,
                                              id: id, transport: transport, sessions: sessions) else { return }
            var resp = Star_V1_LineCandidatesResponse()
            resp.candidates = await candidates(for: group)
            try await transport.respond(id: id, payload: resp.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    /// Every line the finder proposes for [group] with the arguments it has now, the best fit (intensity score) first.  The finder is
    /// heavy and runs on a thread of its own, not the group's.
    static func candidates(for group: OutlierGroup) async -> [Star_V1_LineCandidate] {
        let finder = await group.lineFinder
        let infos = await Task.detached(priority: .userInitiated) { finder.lineData }.value
        return infos
            .sorted { $0.intensityScore > $1.intensityScore }
            .map { info in
                var c = Star_V1_LineCandidate()
                c.line = Mapping.protoLine(info.line)
                c.intensityScore = info.intensityScore
                c.pixelScore = info.pixelScore
                c.border = Int32(info.border)
                return c
            }
    }

    static func setLine(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        do {
            let req = try Star_V1_SetLineRequest(serializedBytes: payload)
            guard let group = await findGroup(sessionID: req.sessionID, frameIndex: Int(req.frameIndex), groupID: req.groupID,
                                              id: id, transport: transport, sessions: sessions) else { return }
            guard req.hasCandidate, req.candidate.hasLine else {
                await transport.sendError(id: id, message: "no line given", code: 400); return
            }
            var resp = Star_V1_SetLineResponse()
            resp.group = await choose(req.candidate, for: group)
            try await transport.respond(id: id, payload: resp.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    /// Make [candidate] the line of [group], and return the group as it is then.
    static func choose(_ candidate: Star_V1_LineCandidate, for group: OutlierGroup) async -> Star_V1_OutlierGroup {
        // A group works out its own line the first time it is asked for it, and would then replace the one set here: ask now.
        _ = await group.line()
        await group.set(line: HoughLineFinder.LineInfo(
            line: Line(theta: candidate.line.theta, rho: candidate.line.rho, votes: Int(candidate.line.votes)),
            intensityScore: candidate.intensityScore,
            pixelScore: candidate.pixelScore,
            border: Int(candidate.border)))
        return await OutlierHandlers.protoGroup(group)
    }

    private static func findGroup(sessionID: String, frameIndex: Int, groupID: UInt32, id: UInt64,
                                  transport: StdioTransport, sessions: SessionManager) async -> OutlierGroup?
    {
        guard let session = await sessions.get(id: sessionID) else {
            await transport.sendError(id: id, message: "session not found", code: 404); return nil
        }
        guard let frame = await session.frame(at: frameIndex) else {
            await transport.sendError(id: id, message: "frame index out of range", code: 404); return nil
        }
        await ensureOutliersLoaded(frame)
        guard let groups = await frame.getOutlierGroups() else {
            await transport.sendError(id: id, message: "outlier groups not yet loaded"); return nil
        }
        guard let key = UInt16(exactly: groupID), let group = await groups.members[key] else {
            await transport.sendError(id: id, message: "group not found", code: 404); return nil
        }
        return group
    }

    // ---- the finder's arguments ----

    static func getArgs(id: UInt64, payload: Data, transport: StdioTransport) async {
        do {
            try await transport.respond(id: id, payload: args(await constants.getHoughLineFinderArgs()).serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    static func setArg(id: UInt64, payload: Data, transport: StdioTransport) async {
        do {
            let req = try Star_V1_SetHoughLineFinderArgRequest(serializedBytes: payload)
            let current = await constants.getHoughLineFinderArgs()
            guard let updated = updated(current, name: req.name, value: req.value) else {
                await transport.sendError(id: id, message: "cannot set \(req.name) to \(req.value)", code: 400); return
            }
            await constants.set(houghLineFinderArgs: updated)
            try await transport.respond(id: id, payload: args(updated).serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    /// The arguments as the client lists them: one entry for each, with its name as StarCore has it.
    static func args(_ args: HoughLineFinder.Args) -> Star_V1_HoughLineFinderArgs {
        var out = Star_V1_HoughLineFinderArgs()
        for type in HoughLineFinder.Args.ArgType.allCases {
            var a = Star_V1_HoughLineFinderArg()
            a.name = "\(type)"
            a.value = args.value(for: type) ?? 0
            a.isInteger = args.isInteger(type)
            a.description_p = args.description(for: type)
            out.args.append(a)
        }
        return out
    }

    /// [args] with the argument called [name] set to [value]; nil if there is no such argument or it cannot be set that way.
    static func updated(_ args: HoughLineFinder.Args, name: String, value: Double) -> HoughLineFinder.Args? {
        guard let type = HoughLineFinder.Args.ArgType.allCases.first(where: { "\($0)" == name }), value.isFinite else { return nil }
        if args.isInteger(type) {
            guard let whole = Int(exactly: value.rounded()) else { return nil }
            return args.intUpdate(for: type, value: whole)
        }
        return args.doubleUpdate(for: type, value: value)
    }
}
