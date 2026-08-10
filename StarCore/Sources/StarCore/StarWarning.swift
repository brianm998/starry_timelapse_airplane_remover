import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// Something star noticed about the machine that the user would want to know before it
/// becomes a crash.
///
/// The motivating case: `MemoryMonitor` already receives the OS memory-pressure
/// notification, already measures the process footprint against its budget, and already
/// knows when system-available memory is under its floor.  Before this type existed all
/// three signals terminated inside the admission gate — they throttled `reserve()` and
/// wrote a `Log.w`, and that was the end of them.  A user watching the cli saw a normal
/// progress display right up until the OS killed the process, and a user in the gui saw
/// nothing at all.
///
/// `Codable` because the last warning issued is recorded into the `RunMarker`, which is
/// what lets the *next* launch say "it ran out of memory" about a kill it could not
/// possibly have caught as it happened.
public struct StarWarning: Sendable, Codable, Equatable {

    /// What was noticed.  The kind is also the dedup key in `StarWarnings`, so add cases
    /// for genuinely distinct conditions rather than for variations of one condition's
    /// wording.
    public enum Kind: String, Sendable, Codable {
        /// The OS reported memory pressure (`DispatchSource.MemoryPressureEvent`).  On
        /// Darwin this is the last warning the system gives before jetsam starts killing.
        case memoryPressure

        /// System-wide available memory has fallen below `MemoryMonitor`'s floor.
        case lowSystemMemory

        /// This process's footprint has reached or passed its own budget, which means the
        /// reservation ledger is under-counting what the run actually holds.
        case footprintOverBudget

        /// A single reservation is larger than the entire budget, so it was admitted
        /// ungated.  Either an op's multiplier or `maxMatMemoryFraction` is wrong, and
        /// until one of them changes this run has no memory gating for that op.
        case oversizedReservation

        /// `Config.set(imageInfo:)` never ran, so every op reserves zero bytes and the
        /// memory gating is inert.  This shipped in 0.11.1 and is exactly what got a
        /// user's cli OOM-killed, so it is worth a user-visible warning and not only the
        /// `Log.e` in `FrameGraphBuilder`.
        case memoryGatingDisabled

        /// A previous run of star ended without cleaning up after itself.  Posted at
        /// startup from a `RunMarker` left behind by the run that died.
        case previousRunDied

        /// star could not write an output frame — almost always a full disk or an output
        /// folder it cannot write to.  Distinct from every other kind here in that it is
        /// about the user's actual product going missing rather than about the machine.
        case outputWriteFailed

        /// The output volume does not obviously have room for what this run will produce.
        /// An estimate, posted before the run starts.
        case lowDiskSpace

        /// A setting that feeds a cached stage changed since this sequence was processed,
        /// so star is rebuilding that stage — and, where keypoints are involved, throwing
        /// away the stored alignment and the frames rendered from it.  Worth telling the
        /// user about because it is the one kind here that discards work they can see:
        /// output frames that existed a moment ago are now going to be re-rendered.
        case artifactsInvalidated
    }

    /// How bad it is.  `critical` means "this run is in real danger of being killed";
    /// clients are expected to put it somewhere the user cannot miss.
    public enum Severity: String, Sendable, Codable, Comparable {
        case warning
        case critical

        private var rank: Int {
            switch self {
            case .warning:  return 0
            case .critical: return 1
            }
        }

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    public let kind: Kind
    public let severity: Severity

    /// What happened, in a sentence a user can read.  No log prefixes, no actor names —
    /// this goes into an `NSAlert` and onto a terminal.
    public let message: String

    /// What the user can do about it, when there is something.  Kept separate from
    /// `message` so a client can render it differently (or, in a cramped banner, not at
    /// all) without having to split a string.
    public let suggestion: String?

    public let time: Date

    public init(kind: Kind,
                severity: Severity,
                message: String,
                suggestion: String? = nil,
                time: Date = Date())
    {
        self.kind = kind
        self.severity = severity
        self.message = message
        self.suggestion = suggestion
        self.time = time
    }

    /// A short heading, for a client that shows warnings in a titled box.  Here rather than
    /// in each client so the gui and any future UI cannot end up calling the same condition
    /// two different things.
    public var title: String {
        switch kind {
        case .memoryPressure:       return localized("warning.title.memory_pressure")
        case .lowSystemMemory:      return localized("warning.title.low_system_memory")
        case .footprintOverBudget:  return localized("warning.title.footprint_over_budget")
        case .oversizedReservation: return localized("warning.title.oversized_reservation")
        case .memoryGatingDisabled: return localized("warning.title.memory_gating_disabled")
        case .previousRunDied:      return localized("warning.title.previous_run_died")
        case .outputWriteFailed:    return localized("warning.title.output_write_failed")
        case .lowDiskSpace:         return localized("warning.title.low_disk_space")
        case .artifactsInvalidated: return localized("warning.title.artifacts_invalidated")
        }
    }

    /// `message` and `suggestion` as one line, for a log or a terminal.
    public var oneLineDescription: String {
        if let suggestion {
            return "\(message) \(suggestion)"
        }
        return message
    }
}

/// Where warnings are posted, and the one place a client installs a handler for them.
///
/// A global relay rather than a value threaded through the pipeline because the things
/// that notice these conditions are themselves process-wide singletons —
/// `MemoryMonitor.shared` and `frameGraphBuilder` — and plumbing a callback down to them
/// from three different clients meant three different chains that could each break
/// separately.  Clients set `Callbacks.warningCallback` and call
/// `Callbacks.installWarningHandler()`; everything that notices something calls `post`.
///
/// Note the asymmetry with `Log`: warnings are *also* logged here, so a source never has
/// to do both.  A warning is a superset of a log line, not an alternative to one.
public actor StarWarnings {

    public static let shared = StarWarnings()

    /// Installed by whichever client is running.  Nil in tests and in the standalone
    /// tools, where logging alone is the right behaviour.
    private var handler: (@Sendable (StarWarning) -> Void)?

    /// When each kind was last delivered.  The conditions behind these warnings are
    /// sampled repeatedly — `realityBlock()` is evaluated on every drain pass, twice a
    /// second while anything is queued — so without this the user would get the same
    /// sentence hundreds of times for one episode.
    private var lastDelivery: [StarWarning.Kind: Date] = [:]

    /// The severity last delivered per kind, so an escalation is never suppressed.  A
    /// condition that goes from `warning` to `critical` is new information even inside
    /// the dedup window.
    private var lastSeverity: [StarWarning.Kind: StarWarning.Severity] = [:]

    /// How long the same kind stays suppressed.  Long enough that a flapping condition
    /// reads as one episode, short enough that a genuinely worsening run keeps saying so.
    private var minimumInterval: TimeInterval = 30

    /// The most recent warning delivered, whatever its kind.  Read by `RunMarkerStore` so
    /// the breadcrumb carries the last thing star noticed before it died — which is the
    /// difference between "the run stopped" and "the run stopped while the OS was
    /// reporting memory pressure".
    private var mostRecent: StarWarning?

    public func set(handler: (@Sendable (StarWarning) -> Void)?) {
        self.handler = handler
    }

    /// Exposed for tests, which would otherwise have to wait out `minimumInterval`.
    public func setMinimumInterval(_ interval: TimeInterval) {
        self.minimumInterval = max(0, interval)
    }

    public func latest() -> StarWarning? { mostRecent }

    /// Report a condition.  Logged always; delivered to the client handler unless an
    /// equally-or-less severe warning of the same kind was delivered recently.
    ///
    /// Returns whether it was delivered, which is what the tests assert on.
    @discardableResult
    public func post(_ warning: StarWarning) -> Bool {
        switch warning.severity {
        case .critical: Log.e("WARNING[\(warning.kind.rawValue)]: \(warning.oneLineDescription)")
        case .warning:  Log.w("WARNING[\(warning.kind.rawValue)]: \(warning.oneLineDescription)")
        }

        if let previous = lastDelivery[warning.kind],
           warning.time.timeIntervalSince(previous) < minimumInterval,
           let seen = lastSeverity[warning.kind],
           warning.severity <= seen
        {
            return false
        }

        lastDelivery[warning.kind] = warning.time
        lastSeverity[warning.kind] = warning.severity
        mostRecent = warning

        handler?(warning)
        return true
    }

    /// Forget the dedup state.  For tests, and for a client that starts a new run inside
    /// one process — the gui, where the warnings from the sequence you just closed should
    /// not suppress the same warning about the one you just opened.
    public func reset() {
        lastDelivery = [:]
        lastSeverity = [:]
        mostRecent = nil
    }
}
