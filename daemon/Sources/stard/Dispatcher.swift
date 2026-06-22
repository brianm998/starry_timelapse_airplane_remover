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
    }

    // Cancel the Task servicing the given request id.
    func cancel(id: UInt64) {
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)
    }

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
        register(method: "Daemon.Shutdown") { id, payload, transport in await DaemonHandlers.shutdown(id: id, payload: payload, transport: transport); await t.taskCompleted(id: id) }

        // Session
        register(method: "Session.OpenSequence") { id, payload, transport in await SessionHandlers.openSequence(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Session.OpenConfig")   { id, payload, transport in await SessionHandlers.openConfig(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Session.OpenVideo")    { id, payload, transport in await SessionHandlers.openVideo(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Session.Close")        { id, payload, transport in await SessionHandlers.close(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Session.List")         { id, payload, transport in await SessionHandlers.list(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }

        // Sequence
        register(method: "Sequence.GetConfig")    { id, payload, transport in await SequenceHandlers.getConfig(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Sequence.UpdateConfig") { id, payload, transport in await SequenceHandlers.updateConfig(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }

        // Frame
        register(method: "Frame.Get")                 { id, payload, transport in await FrameHandlers.get(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Frame.GetPreview")          { id, payload, transport in await FrameHandlers.getPreview(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Frame.GetOutlierLabelImage"){ id, payload, transport in await FrameHandlers.getOutlierLabelImage(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Frame.SetCleanMethod")      { id, payload, transport in await FrameHandlers.setCleanMethod(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }

        // Outlier
        register(method: "Outlier.List")         { id, payload, transport in await OutlierHandlers.list(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Outlier.SetDecisions") { id, payload, transport in await OutlierHandlers.setDecisions(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Outlier.RenderFrame")  { id, payload, transport in await OutlierHandlers.renderFrame(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }

        // Processing
        register(method: "Processing.Start")          { id, payload, transport in await ProcessingHandlers.start(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Processing.StreamProgress") { id, payload, transport in await ProcessingHandlers.streamProgress(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Processing.Cancel")         { id, payload, transport in await ProcessingHandlers.cancel(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }

        // Export
        register(method: "Export.RenderSequence") { id, payload, transport in await ExportHandlers.renderSequence(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
        register(method: "Export.Video")          { id, payload, transport in await ExportHandlers.video(id: id, payload: payload, transport: transport, sessions: s); await t.taskCompleted(id: id) }
    }
}
