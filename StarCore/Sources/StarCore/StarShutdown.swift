import Foundation
import logging

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// Turns an interruption — Ctrl-C, `kill`, a closed terminal, a client shutting the daemon
/// down — into an orderly stop instead of an instant death.
///
/// Three things go wrong without this, and the third is the one that made it urgent:
///
///   1. Queued log lines are lost. `LogGremlin` moves lines to its handlers on a 1ms poll, so
///      whatever is in the queue when the process dies never reaches the file.
///   2. The user is told nothing — in particular not that the run can be resumed, which is
///      the single most useful thing to say to somebody who just interrupted an hour of work.
///   3. The run marker is left behind, and the *next* launch reports the interruption as a
///      crash. That one is self-inflicted: it appeared the moment `RunMarker` landed. It is
///      not hypothetical for the daemon either — the desktop client's `DaemonProcess.destroy()`
///      calls `Process.destroy()`, which is SIGTERM, so every normal quit of the Kotlin client
///      would have accused the daemon of crashing.
///
/// Deliberately *not* the same mechanism as the fatal-signal handler. These signals arrive in
/// a process that is still healthy, so there is no reason to be restricted to
/// async-signal-safe code — `DispatchSource.makeSignalSource` delivers them on a queue,
/// outside handler context, where ordinary Swift is fine. `crash_handler.c` exists because a
/// process that has just segfaulted cannot make that assumption.
public enum StarShutdown {

    /// How long the orderly path gets before it is abandoned.
    ///
    /// There has to be a limit. Cancelling operations and draining the log queue should take
    /// well under a second, but "should" is not good enough for the path a user takes when
    /// they have already decided to stop: an interrupt that does not interrupt is worse than
    /// an abrupt one. The watchdog runs on a plain Dispatch queue rather than as a `Task` on
    /// purpose — if the Swift concurrency pool is what is wedged, a `Task`-based timeout is
    /// wedged with it.
    public static let gracePeriod: TimeInterval = 5

    /// Signals treated as "stop cleanly": Ctrl-C, `kill`, and a closed terminal.
    ///
    /// SIGHUP matters for the cli specifically — closing the terminal window mid-run is an
    /// ordinary thing to do, and it should leave a resumable state and a complete log rather
    /// than a marker that reads as a crash.
    #if !os(Windows)
    static let handledSignals: [Int32] = [SIGINT, SIGTERM, SIGHUP]
    #else
    static let handledSignals: [Int32] = []
    #endif

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        #if !os(Windows)
        var sources: [DispatchSourceSignal] = []
        #endif
        var shuttingDown = false
        var hook: (@Sendable () async -> Void)?
        var clientName = "star"
        var quiet = false
    }

    private static let state = State()

    /// Begin handling interruptions.
    ///
    /// - Parameters:
    ///   - clientName: what to call this process in the message the user sees.
    ///   - quiet: suppress that message. For the gui, where stderr goes nowhere a user will
    ///     read and the point of installing at all is only to clear the run marker when
    ///     something sends SIGTERM.
    ///   - onShutdown: client-specific work — closing a session, stopping a server. Runs
    ///     inside the grace period, before the log queue is drained.
    ///
    /// Idempotent. A no-op on Windows, which has no signals to install.
    public static func install(clientName: String = "star",
                               quiet: Bool = false,
                               onShutdown: (@Sendable () async -> Void)? = nil)
    {
        #if !os(Windows)
        state.lock.lock()
        defer { state.lock.unlock() }

        state.clientName = clientName
        state.quiet = quiet
        state.hook = onShutdown

        guard state.sources.isEmpty else { return }   // already installed; hook updated above

        for signo in handledSignals {
            // Required: a dispatch signal source *observes* delivery, it does not replace the
            // disposition. Without this the default action still terminates the process
            // before the handler ever runs.
            signal(signo, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: signo,
                                                         queue: .global(qos: .userInitiated))
            source.setEventHandler { @Sendable in
                StarShutdown.received(signo)
            }
            source.activate()
            state.sources.append(source)
        }

        Log.i("shutdown handlers installed for \(handledSignals.map(String.init).joined(separator: ", "))")
        #endif
    }

    /// Whether an orderly shutdown is under way. Long-running work can poll this to bail out
    /// early rather than being cut off by the watchdog.
    public static var isShuttingDown: Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.shuttingDown
    }

    private static func name(of signo: Int32) -> String {
        #if !os(Windows)
        switch signo {
        case SIGINT:  return "SIGINT"
        case SIGTERM: return "SIGTERM"
        case SIGHUP:  return "SIGHUP"
        default:      return "signal \(signo)"
        }
        #else
        return "signal \(signo)"
        #endif
    }

    /// Straight to fd 2 rather than through `Log`, because at this point the log queue is
    /// about to be drained and shut down, and this is the one message that must not be lost
    /// to it.
    private static func tell(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }

    private static func received(_ signo: Int32) {
        state.lock.lock()
        let alreadyStopping = state.shuttingDown
        state.shuttingDown = true
        let clientName = state.clientName
        let quiet = state.quiet
        let hook = state.hook
        state.lock.unlock()

        // Second interrupt: the user has asked twice, so stop asking them to wait. `_exit`
        // rather than `exit` — no atexit handlers, no flushing, no chance of blocking on
        // whatever the first attempt is stuck on.
        if alreadyStopping {
            if !quiet { tell("\n\(clientName): stopping now.\n") }
            // Still a deliberate stop, so still not a crash. `_exit` skips everything the
            // orderly path would have done, including clearing the marker — and leaving it
            // behind would have the next launch report the user's own second Ctrl-C as an
            // unexpected stop, which is precisely the noise this whole file exists to remove.
            // The synchronous variant, because there is no awaiting an actor from here.
            RunMarkerStore.finishWithoutWaiting()
            _exit(128 + signo)
        }

        if !quiet {
            tell("\n\(clientName): interrupted (\(name(of: signo))), stopping. " +
                 "Press Ctrl-C again to stop immediately.\n")
        }

        // The backstop, armed before any of the work below is attempted.
        DispatchQueue.global(qos: .userInitiated)
          .asyncAfter(deadline: .now() + gracePeriod) {
            tell("\(clientName): shutdown took too long, exiting.\n")
            // Same reasoning as the second-interrupt path: the orderly clear never got to
            // run, but this was still an interruption and not a crash.
            RunMarkerStore.finishWithoutWaiting()
            _exit(128 + signo)
        }

        Task {
            await performShutdown(signo: signo, clientName: clientName, quiet: quiet, hook: hook)
        }
    }

    private static func performShutdown(signo: Int32,
                                        clientName: String,
                                        quiet: Bool,
                                        hook: (@Sendable () async -> Void)?) async
    {
        // Stop new work first, so everything after this is racing less. Operations already
        // running are not interrupted — `cancelAllOperations` only unqueues what has not
        // started and asks the rest to notice — which is fine: output frames are written to a
        // temp file and atomically renamed, so an operation cut off mid-write cannot leave a
        // half-written frame behind.
        await frameGraphBuilder.cancelAllOperations()

        await hook?()

        // Say how to pick up where this left off, while the user is still looking at the
        // terminal they just pressed Ctrl-C in.
        let marker = await RunMarkerStore.shared.current()
        if !quiet, let resume = marker?.resumeConfigPath {
            tell("\(clientName): resume this run with:\n  star \(resume)\n")
        }

        // An interruption is not a crash. Clearing the marker is what stops the next launch
        // reporting it as one.
        await RunMarkerStore.shared.finish()

        Log.i("\(clientName) interrupted by \(name(of: signo)), shutting down")
        await logging.gremlin.finishLogging()

        exit(128 + signo)
    }
}
