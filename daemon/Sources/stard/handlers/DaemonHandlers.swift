import Foundation
import StarCore
import StarDaemonMessages
import SwiftProtobuf
import logging

enum DaemonHandlers {
    static func hello(id: UInt64, payload: Data, transport: StdioTransport, scratchRoot: String) async {
        do {
            let _ = try Star_V1_HelloRequest(serializedBytes: payload)
            var resp = Star_V1_HelloResponse()
            resp.daemonVersion = Config.latestVersion
            resp.scratchDir = scratchRoot
            try await transport.respond(id: id, payload: resp.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
    }

    static func shutdown(id: UInt64, payload: Data, transport: StdioTransport) async {
        do {
            let resp = Star_V1_ShutdownResponse()
            try await transport.respond(id: id, payload: resp.serializedData())
        } catch {
            await transport.sendError(id: id, message: "\(error)")
        }
        // An explicit shutdown is the daemon's other clean exit besides stdin EOF, so it
        // has to clear the run marker too — otherwise every normal quit would have the
        // next daemon report a crash that never happened.
        await RunMarkerStore.shared.finish()
        // Give the response time to flush, then exit.
        try? await Task.sleep(nanoseconds: 100_000_000)
        Foundation.exit(0)
    }
}
