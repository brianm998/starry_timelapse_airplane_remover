import Foundation
import StarCore
import StarDaemonMessages
import SwiftProtobuf
import logging

enum ExportHandlers {
    static func renderSequence(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        // Phase 2: Render all output frames using the frame graph's finish() mechanism.
        // For now, emit an error to indicate this requires Phase 2 completion.
        await transport.sendError(id: id, message: "Export.RenderSequence not yet implemented (Phase 2)", code: 501)
    }

    static func video(id: UInt64, payload: Data, transport: StdioTransport, sessions: SessionManager) async {
        // Phase 4: Export frames to video via VideoConvert / ffmpeg.
        await transport.sendError(id: id, message: "Export.Video not yet implemented (Phase 4)", code: 501)
    }
}
