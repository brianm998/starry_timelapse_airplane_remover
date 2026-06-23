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
        // FIRST, before any I/O or logging: move the protocol onto private FDs and redirect the
        // process-wide stdout→stderr / stdin→/dev/null, so no stray write/read can corrupt the
        // frame stream. Also sets binary mode on Windows. (See StdioTransport.setupProtocolIO.)
        setupProtocolIO()

        // Logging goes to stderr (never the protocol stream). StderrLogHandler writes fd 2 directly;
        // and because setupProtocolIO redirected fd 1→fd 2, even a stray print()/ConsoleLogHandler
        // can no longer reach the protocol.
        Log.name = "stard"
        Log.add(handler: StderrLogHandler(at: logLevel), for: .console)

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

        // Run the blocking stdin read loop on a DEDICATED thread, not here.
        //
        // AsyncParsableCommand runs `run()` on the MainActor. `readFrame()` does a *synchronous*
        // blocking `read()` on stdin, which — if run on the MainActor executor — blocks it for the
        // entire time we're waiting for the next client frame. That starves every
        // `Task { @MainActor in … }` in StarCore, most importantly `GraphCompletionOp`'s completion:
        // processing finishes (all output written) but the graph never signals "done", so the client
        // waits forever. Reading on a dedicated thread keeps the MainActor free to service that work.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let reader = Thread {
                while true {
                    guard let frameData = readFrame() else {
                        Log.i("stard: stdin EOF — exiting")
                        break
                    }
                    guard let envelope = try? Star_V1_Envelope(serializedBytes: frameData) else {
                        Log.e("stard: failed to decode envelope")
                        continue
                    }
                    switch envelope.kind {
                    case .request: Task { await dispatcher.dispatch(envelope: envelope) }
                    case .cancel:  Task { await dispatcher.cancel(id: envelope.id) }
                    default:       Log.w("stard: unexpected envelope kind from client — ignoring")
                    }
                }
                cont.resume()
            }
            reader.name = "stard-stdin-reader"
            reader.stackSize = 4 << 20
            reader.start()
        }

        await TaskWaiter.shared.finish()
        await logging.gremlin.finishLogging()
    }
}

extension Log.Level: @retroactive ExpressibleByArgument {}
