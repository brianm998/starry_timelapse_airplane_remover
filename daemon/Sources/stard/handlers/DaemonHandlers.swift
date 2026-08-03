import Foundation
import StarCore
import StarDaemonMessages
import SwiftProtobuf
import logging

enum DaemonHandlers {
    static func hello(id: UInt64, payload: Data, transport: StdioTransport, scratchRoot: String) async {
        do {
            let request = try Star_V1_HelloRequest(serializedBytes: payload)

            // Adopt the client's language for everything this daemon will say from here on.
            // The daemon has no UI of its own, but it does originate user-visible text —
            // Warning messages and suggestions, error strings — and that text has to arrive
            // in the language the client is already showing. Hello is the right place: it is
            // the first message on the connection, and there is exactly one client per
            // daemon process, so a process-wide setting is not a shared-state problem.
            //
            // An empty locale means "you decide", which leaves the daemon on its own machine
            // settings. An unknown one falls back the same way every other entry point does.
            if !request.locale.isEmpty {
                StarLocalization.shared.languageOverride = request.locale
            }

            var resp = Star_V1_HelloResponse()
            resp.daemonVersion = Config.latestVersion
            resp.scratchDir = scratchRoot
            // What was actually resolved, which is not always what was asked for.
            resp.locale = StarLocalization.shared.currentCode
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
