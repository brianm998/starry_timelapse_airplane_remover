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

    /// Starting language for user-visible text the daemon originates.
    ///
    /// Normally unnecessary — `Daemon.Hello` carries the client's locale and overrides this
    /// as soon as the connection opens. It matters for the window before Hello (a warning
    /// posted during startup, a crash report from a previous run) and for driving `stard`
    /// by hand.
    @Option(name: [.customLong("language")], help: "Language for user-visible messages (BCP-47, e.g. pt-BR)")
    var language: String?

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

        // Before the abandoned-run reports below, which are user-visible prose.
        if let language { StarLocalization.shared.languageOverride = language }

        // Always on, and the only durable record the daemon has. stderr is drained by whatever
        // launched it, and the desktop client's default sink is System.err.println — which in
        // a packaged app goes nowhere a user can reach. A daemon that died therefore left no
        // evidence at all, which matters more here than anywhere: it is the process most
        // likely to be killed and the least likely to be watched.
        let diagnosticLogPath = DiagnosticLog.enable(level: logLevel)

        // Register decision-tree classifiers (same as CLI).
        await StarCore.currentClassifier.set(for: .all)      { OutlierGroupForestClassifier_2436760d() }
        await StarCore.currentClassifier.set(for: .isolated) { OutlierGroupForestClassifier_f9f52500() }

        // Fatal signals. Worth more in the daemon than anywhere: its stderr may go nowhere a
        // user will ever look, so without this a crashed daemon is a client that says
        // "engine stopped" and nothing else.
        StarCrashHandler.install(logPath: diagnosticLogPath)

        // A daemon that was killed left a marker behind.  The client cannot see this yet
        // beyond the stderr drain, but the daemon is the process most likely to be killed
        // and least likely to be watched, so recording it is worth more here than anywhere.
        for marker in await RunMarkerStore.shared.abandonedRuns() {
            Log.e("previous run did not finish: \(marker.summary)")
            for line in marker.report.split(separator: "\n", omittingEmptySubsequences: false) {
                Log.e("  \(line)")
            }
        }
        await RunMarkerStore.shared.clearAbandoned()

        await RunMarkerStore.shared.begin(client: "stard", logPath: diagnosticLogPath)

        // Ensure scratch root exists.
        try FileManager.default.createDirectory(atPath: scratchDir, withIntermediateDirectories: true)

        let transport = StdioTransport()
        await transport.startWriter()

        // Machine-level warnings go to stderr *and* to the client. Installed here rather than
        // earlier because it needs the transport: stderr alone was never enough, since the
        // desktop client drains it into a sink that in a packaged app goes nowhere a user can
        // read, so a daemon under memory pressure had no way to say so.
        var callbacks = Callbacks()
        callbacks.warningCallback = { warning in
            Log.w("STAR-WARNING \(warning.kind.rawValue) \(warning.severity.rawValue): " +
                  warning.oneLineDescription)
            Task { await transport.sendWarning(warning) }
        }
        await callbacks.installWarningHandler()

        let sessions = SessionManager(scratchRoot: scratchDir)
        let dispatcher = Dispatcher(transport: transport, sessions: sessions)
        await dispatcher.registerAll()

        // The desktop client's DaemonProcess.destroy() calls Process.destroy(), which is
        // SIGTERM — so this is not an edge case, it is what happens every time the Kotlin
        // client quits. Handling it stops each of those normal shutdowns leaving a run marker
        // for the next daemon to report as a crash, and gives in-flight sessions a chance to
        // stop rather than being cut off mid-frame.
        StarShutdown.install(clientName: "stard") {
            for session in await sessions.all {
                await session.cancelProcessing()
            }
        }

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

        // stdin EOF is the daemon's normal exit — the client closed the pipe.  Clearing the
        // marker here is what makes a *missing* clean exit meaningful.
        await RunMarkerStore.shared.finish()

        await TaskWaiter.shared.finish()
        await logging.gremlin.finishLogging()
    }
}

extension Log.Level: @retroactive ExpressibleByArgument {}
