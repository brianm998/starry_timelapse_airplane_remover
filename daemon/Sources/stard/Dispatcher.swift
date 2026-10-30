import Foundation
import StarDaemonMessages
import SwiftProtobuf
import logging

// A handler is a closure that runs in its own Task and receives the raw request payload.
// It sends responses/items via the transport and returns when complete.
typealias Handler = @Sendable (UInt64, Data, StdioTransport) async -> Void

// Dispatcher routes method strings to registered handlers and tracks active Tasks by id
// for cancellation support (§5.4).
actor Dispatcher {
    private var handlers: [String: Handler] = [:]
    private var activeTasks: [UInt64: Task<Void, Never>] = [:]

    /// Cancels that arrived before their request. The reader hands requests and cancels to the
    /// dispatcher as separate tasks, so a cancel can run first; with nothing registered under its
    /// id it used to do nothing, and the request then ran to completion. Remembered here and
    /// applied when the request shows up. Bounded: a cancel for a request that already finished
    /// also lands here, and ids are never reused, so the oldest are simply forgotten.
    private var earlyCancels: [UInt64] = []
    private static let earlyCancelLimit = 256
    private let transport: StdioTransport
    private let sessions: SessionManager

    init(transport: StdioTransport, sessions: SessionManager) {
        self.transport = transport
        self.sessions = sessions
    }

    func register(method: String, handler: @escaping Handler) {
        handlers[method] = handler
    }

    // Dispatch an incoming REQUEST envelope.
    func dispatch(envelope: Star_V1_Envelope) {
        let id = envelope.id
        let method = envelope.method
        let payload = envelope.payload

        guard let handler = handlers[method] else {
            Task { [transport] in
                await transport.sendError(id: id, message: "unknown method: \(method)", code: 404)
            }
            return
        }

        let t = Task { [transport] in
            await handler(id, payload, transport)
        }
        activeTasks[id] = t
        if let early = earlyCancels.firstIndex(of: id) {
            earlyCancels.remove(at: early)
            t.cancel()
            activeTasks.removeValue(forKey: id)
        }
    }

    // Cancel the Task servicing the given request id.
    func cancel(id: UInt64) {
        if let task = activeTasks[id] {
            task.cancel()
            activeTasks.removeValue(forKey: id)
        } else {
            // not registered (yet): remember it for when the request arrives
            earlyCancels.append(id)
            if earlyCancels.count > Self.earlyCancelLimit {
                earlyCancels.removeFirst(earlyCancels.count - Self.earlyCancelLimit)
            }
        }
    }

    /// For tests: how many cancels are waiting for a request that has not arrived.
    var pendingEarlyCancelCount: Int { earlyCancels.count }

    // Remove completed task from registry (called by handlers on completion).
    func taskCompleted(id: UInt64) {
        activeTasks.removeValue(forKey: id)
    }
}

// MARK: - Registration helper

extension Dispatcher {
    // Register all method handlers.
    func registerAll() async {
        let t = self
        let s = sessions

        let scratchRoot = await s.scratchRoot

        // Daemon
        register(method: "Daemon.Hello")    { id, payload, transport in await DaemonHandlers.hello(id: id, payload: payload, transport: transport, scratchRoot: scratchRoot); await t.taskCompleted(id: id) }
        register(method: "Daemon.SetLogLevel") { id, payload, transport in await DaemonHandlers.setLogLevel(id: id, payload: payload, transport: transport); await t.taskCompleted(id: id) }
        register(method: "Daemon.Shutdown") { id, payload, transport in await DaemonHandlers.shutdown(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }

        // Blob processing (the developer window)
        register(method: "Blob.GetSteps")       { id, payload, transport in await BlobHandlers.getSteps(id: id, payload: payload, transport: transport); await t.taskCompleted(id: id) }
        register(method: "Blob.SetCustomSteps") { id, payload, transport in await BlobHandlers.setCustomSteps(id: id, payload: payload, transport: transport); await t.taskCompleted(id: id) }

        // Session
        register(method: "Session.ProbeVideo")   { id, payload, transport in await SessionHandlers.probeVideo(id: id, payload: payload, transport: transport); await t.taskCompleted(id: id) }
        register(method: "Session.GetFreeSpace")   { id, payload, transport in await SessionHandlers.freeSpace(id: id, payload: payload, transport: transport); await t.taskCompleted(id: id) }
        register(method: "Session.OpenSequence") { id, payload, transport in await SessionHandlers.openSequence(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Session.OpenConfig")   { id, payload, transport in await SessionHandlers.openConfig(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Session.OpenVideo")    { id, payload, transport in await SessionHandlers.openVideo(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Session.OpenSequenceStream") { id, payload, transport in await SessionHandlers.openSequenceStream(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Session.OpenConfigStream")   { id, payload, transport in await SessionHandlers.openConfigStream(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Session.Close")        { id, payload, transport in await SessionHandlers.close(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Session.List")         { id, payload, transport in await SessionHandlers.list(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }

        // Sequence
        register(method: "Sequence.GetConfig")    { id, payload, transport in await SequenceHandlers.getConfig(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Sequence.UpdateConfig") { id, payload, transport in await SequenceHandlers.updateConfig(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Sequence.GetProgressSurvey") { id, payload, transport in await SequenceHandlers.getProgressSurvey(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Sequence.GetKeypointAdvice") { id, payload, transport in await SequenceHandlers.getKeypointAdvice(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Sequence.PreviewConfigChange") { id, payload, transport in await SequenceHandlers.previewConfigChange(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }

        // Frame
        register(method: "Frame.Get")                 { id, payload, transport in await FrameHandlers.get(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Frame.GetPreview")          { id, payload, transport in await FrameHandlers.getPreview(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Frame.Prioritize")          { id, payload, transport in await FrameHandlers.prioritize(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Frame.GetEta")              { id, payload, transport in await FrameHandlers.eta(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Frame.GetOutlierLabelImage"){ id, payload, transport in await FrameHandlers.getOutlierLabelImage(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Frame.GetOutlierTrashImage"){ id, payload, transport in await FrameHandlers.getOutlierTrashImage(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Frame.SetNeighborOverride") { id, payload, transport in await FrameHandlers.setNeighborOverride(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Frame.SetCleanMethod")      { id, payload, transport in await FrameHandlers.setCleanMethod(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Frame.FindOutliers")      { id, payload, transport in await FrameHandlers.findOutliers(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }

        // Outlier
        register(method: "Outlier.List")         { id, payload, transport in await OutlierHandlers.list(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Outlier.SetDecisions") { id, payload, transport in await OutlierHandlers.setDecisions(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Outlier.RenderFrame")  { id, payload, transport in await OutlierHandlers.renderFrame(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Outlier.ApplyDecisionTree")          { id, payload, transport in await OutlierHandlers.applyDecisionTree(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Outlier.ApplyDecisionTreeAllFrames") { id, payload, transport in await OutlierHandlers.applyDecisionTreeAllFrames(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Outlier.SetDecisionsInArea")         { id, payload, transport in await OutlierHandlers.setDecisionsInArea(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Outlier.SetDecisionsOverlapping")    { id, payload, transport in await OutlierHandlers.setDecisionsOverlapping(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Outlier.SetAll")                     { id, payload, transport in await OutlierHandlers.setAll(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Outlier.ApplyAreaTool")              { id, payload, transport in await OutlierHandlers.applyAreaTool(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Outlier.GetFeatures")                { id, payload, transport in await OutlierHandlers.getFeatures(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Outlier.GetLineCandidates")          { id, payload, transport in await LineHandlers.getCandidates(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Outlier.SetLine")                    { id, payload, transport in await LineHandlers.setLine(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Debug.GetHoughLineFinderArgs")       { id, payload, transport in await LineHandlers.getArgs(id: id, payload: payload, transport: transport); await t.taskCompleted(id: id) }
        register(method: "Debug.SetHoughLineFinderArgs")       { id, payload, transport in await LineHandlers.setArg(id: id, payload: payload, transport: transport); await t.taskCompleted(id: id) }

        // Processing
        register(method: "Processing.Start")          { id, payload, transport in await ProcessingHandlers.start(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Processing.StreamProgress") { id, payload, transport in await ProcessingHandlers.streamProgress(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Processing.Restart")        { id, payload, transport in await ProcessingHandlers.restart(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Processing.Cancel")         { id, payload, transport in await ProcessingHandlers.cancel(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Processing.ReprocessFrames"){ id, payload, transport in await ProcessingHandlers.reprocessFrames(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }

        // Export
        register(method: "Export.RenderSequence")       { id, payload, transport in await ExportHandlers.renderSequence(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Export.Video")                { id, payload, transport in await ExportHandlers.video(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Export.GetVideoCapabilities") { id, payload, transport in await ExportHandlers.getVideoCapabilities(id: id, payload: payload, transport: transport); await t.taskCompleted(id: id) }
        register(method: "Export.GetDefaultVideoPath") { id, payload, transport in await ExportHandlers.getDefaultVideoPath(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }

        // Alignment
        register(method: "Alignment.Get")         { id, payload, transport in await AlignmentHandlers.get(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Alignment.GetSequence") { id, payload, transport in await AlignmentHandlers.getSequence(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }

        // Horizon
        register(method: "Horizon.SetReference")   { id, payload, transport in await HorizonHandlers.setReference(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Horizon.GetReference")   { id, payload, transport in await HorizonHandlers.getReference(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Horizon.ClearReference") { id, payload, transport in await HorizonHandlers.clearReference(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Horizon.ReferenceUpdated") { id, payload, transport in await HorizonHandlers.referenceUpdated(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Horizon.GetTunedParameters") { id, payload, transport in await HorizonHandlers.getTunedParameters(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Horizon.SetTunedParameters") { id, payload, transport in await HorizonHandlers.setTunedParameters(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Horizon.GetRefinementStatus") { id, payload, transport in await HorizonHandlers.refinementStatus(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Horizon.DeferRefinement") { id, payload, transport in await HorizonHandlers.deferRefinement(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Horizon.RunRefinement")   { id, payload, transport in await HorizonHandlers.runRefinement(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Horizon.Reprocess")      { id, payload, transport in await HorizonHandlers.reprocess(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Horizon.GetOverlay")     { id, payload, transport in await HorizonHandlers.getOverlay(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Horizon.ComputeInBand")  { id, payload, transport in await HorizonHandlers.computeInBand(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Horizon.GetBest")        { id, payload, transport in await HorizonHandlers.getBest(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
    }
}
