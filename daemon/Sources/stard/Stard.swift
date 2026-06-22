import Foundation
import ArgumentParser
import StarCore
import StarDaemonMessages
import SwiftProtobuf
import logging

// StarDecisionTrees is a pre-compiled static library linked via Package.swift linker settings.
// Import its Swift module:
import StarDecisionTrees

@main
struct Stard: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stard",
        abstract: "Star headless daemon — serves StarCore over protobuf-over-stdio"
    )

    @Option(name: .customLong("scratch"), help: "Root scratch directory for session data")
    var scratchDir: String = "\(FileManager.default.temporaryDirectory.path)/star-scratch"

    @Option(name: [.customShort("l"), .customLong("log-level")], help: "Log level (debug/info/warn/error)")
    var logLevel: Log.Level = .info

    mutating func run() async throws {
        // Must be called before any stdin/stdout I/O on Windows.
        setBinaryStdIO()

        // All logging goes to stderr (never stdout — that carries the binary frame stream).
        Log.name = "stard"
        Log.add(handler: ConsoleLogHandler(at: logLevel), for: .console)

        // Register decision-tree classifiers (same as CLI).
        await StarCore.currentClassifier.set(for: .all)      { OutlierGroupForestClassifier_2436760d() }
        await StarCore.currentClassifier.set(for: .isolated) { OutlierGroupForestClassifier_f9f52500() }

        // Ensure scratch root exists.
        try FileManager.default.createDirectory(atPath: scratchDir, withIntermediateDirectories: true)

        let transport = StdioTransport()
        await transport.startWriter()

        let sessions = SessionManager(scratchRoot: scratchDir)
        let dispatcher = Dispatcher(transport: transport, sessions: sessions)
        await dispatcher.registerAll()

        Log.i("stard: ready (scratch=\(scratchDir)) pid=\(ProcessInfo.processInfo.processIdentifier)")

        // Read loop: blocks on stdin, dispatches envelopes, exits on EOF.
        while true {
            guard let frameData = readFrame() else {
                Log.i("stard: stdin EOF — exiting")
                break
            }

            let envelope: Star_V1_Envelope
            do {
                envelope = try Star_V1_Envelope(serializedBytes: frameData)
            } catch {
                Log.e("stard: failed to decode envelope: \(error)")
                continue
            }

            switch envelope.kind {
            case .request:
                await dispatcher.dispatch(envelope: envelope)
            case .cancel:
                await dispatcher.cancel(id: envelope.id)
            default:
                Log.w("stard: unexpected envelope kind from client — ignoring")
            }
        }

        await TaskWaiter.shared.finish()
        await logging.gremlin.finishLogging()
    }
}

extension Log.Level: @retroactive ExpressibleByArgument {}
