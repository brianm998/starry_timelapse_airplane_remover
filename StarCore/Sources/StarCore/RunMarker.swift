import Foundation
import StarCoreC
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

/// A breadcrumb describing a run that is currently in progress, written so that if the run
/// never finishes, the *next* launch can say what happened to it.
///
/// This exists because the failure that matters most cannot be caught as it happens.  When
/// macOS jetsam kills a process for running out of memory it sends `SIGKILL`, which is
/// uncatchable by definition: no handler runs, no log line is written, and the last thing
/// in the log file is whatever happened to be mid-write.  That is precisely the report this
/// was built for — a user whose cli "crashed with no error message", where the only
/// evidence was a truncated log line.
///
/// So the strategy is inverted.  Instead of trying to catch the kill, star records what it
/// is doing while it is still alive, keeps that record fresh with a heartbeat, and deletes
/// it on a clean exit.  A record still present at the next launch *is* the crash report,
/// and because it carries the peak footprint and the last `StarWarning`, it can usually
/// name the cause.
///
/// It costs one small atomic file write every `RunMarkerStore.heartbeatInterval`.
public struct RunMarker: Codable, Sendable, Equatable {

    /// Bumped when a field's meaning changes.  A marker from a future version is reported
    /// as an unexplained stop rather than being misread — see `RunMarkerStore.abandonedRuns`.
    public static let currentFormatVersion = 1

    public var formatVersion: Int = RunMarker.currentFormatVersion

    /// Stable id, also the filename stem.  Includes the pid and the start time so two
    /// concurrent runs cannot collide and a reused pid cannot overwrite an older record.
    public var id: String

    /// Which client wrote this — `"star"`, `"Star"` (the gui), `"stard"`.  All clients share
    /// one marker directory, so this is how a report says whose run died.
    public var client: String

    public var starVersion: String
    public var pid: Int32

    public var startedAt: Date

    /// Refreshed by the heartbeat.  When a marker is found at the next launch, this is when
    /// the run was last known to be alive — i.e. approximately when it died.
    public var heartbeatAt: Date

    public var hostPhysicalMemoryBytes: UInt64

    // MARK: - What it was working on

    public var sequenceName: String?
    public var sequencePath: String?

    /// The `config.json` a resume would be pointed at, so the report can print a command
    /// the user can actually run.
    public var resumeConfigPath: String?

    /// The file log of the dead run, when it had one.  Worth naming in the report: it is
    /// the thing the user would otherwise have to go find.
    public var logPath: String?

    public var frameCount: Int?
    public var imageWidth: Int?
    public var imageHeight: Int?
    public var imageBytesPerPixel: Int?

    // MARK: - How far it got

    public var framesCompleted: Int = 0
    public var currentPhase: String?

    /// Highest process footprint seen by the heartbeat.  Together with
    /// `hostPhysicalMemoryBytes` this is what turns "the run stopped" into "the run was
    /// holding 92% of this machine's memory when it stopped".
    public var peakFootprintBytes: UInt64 = 0

    /// The last thing `StarWarnings` delivered before the run ended.
    public var lastWarning: StarWarning?

    /// The name of the fatal signal that ended the run — `"SIGSEGV"`, `"SIGABRT"` — if the
    /// crash handler caught one.
    ///
    /// Never written by the process that owns the marker, and so always nil on disk: the
    /// signal handler cannot rewrite a JSON file (it may not allocate), so it drops a
    /// separate one-line note instead and `RunMarkerStore.abandonedRuns()` pairs the two when
    /// it reads them back. `Codable` only because the rest of the struct is.
    public var fatalSignal: String?

    public init(id: String,
                client: String,
                starVersion: String = Config.latestVersion,
                pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                startedAt: Date = Date(),
                hostPhysicalMemoryBytes: UInt64 = UInt64(ProcessInfo.processInfo.physicalMemory))
    {
        self.id = id
        self.client = client
        self.starVersion = starVersion
        self.pid = pid
        self.startedAt = startedAt
        self.heartbeatAt = startedAt
        self.hostPhysicalMemoryBytes = hostPhysicalMemoryBytes
    }

    // MARK: - Diagnosis

    /// What star thinks killed the run.  Deliberately hedged in wording: the marker proves
    /// the run did not finish, and gives strong evidence about memory, but it never
    /// observed the kill itself.
    public enum Diagnosis: Sendable, Equatable {
        /// The crash handler caught a fatal signal and named it.  Direct evidence rather
        /// than inference, so this outranks everything below.
        case crashed(signal: String)

        /// The run was holding a large fraction of the machine when it stopped, and/or the
        /// last warning was about memory.  `fraction` is peak footprint over physical.
        case likelyOutOfMemory(fraction: Double)

        /// It stopped, and nothing in the record points anywhere.
        case unknown
    }

    /// Peak footprint as a fraction of the machine, or nil when either number is missing.
    public var peakMemoryFraction: Double? {
        guard hostPhysicalMemoryBytes > 0, peakFootprintBytes > 0 else { return nil }
        return Double(peakFootprintBytes) / Double(hostPhysicalMemoryBytes)
    }

    /// The threshold above which a stopped run is called a likely OOM on footprint alone.
    ///
    /// 0.7 rather than something nearer 1.0 for two reasons.  `phys_footprint` is sampled
    /// on an interval, so the peak it recorded is a lower bound on the real peak — the
    /// allocation that actually crossed the line is the one that never got sampled.  And
    /// jetsam does not wait for a process to reach physical memory: it kills once the
    /// compressor and swap are exhausted, which on a machine with other things running
    /// happens well below 100%.
    public static let outOfMemoryFootprintFraction: Double = 0.7

    public var diagnosis: Diagnosis {
        // A caught signal is something star observed, not something it inferred from a
        // footprint, so it wins outright. It also means completely different advice: an
        // out-of-memory report tells the user to use less memory, whereas this one tells them
        // they have found a bug.
        if let fatalSignal { return .crashed(signal: fatalSignal) }

        let memoryWarning: Bool
        switch lastWarning?.kind {
        case .memoryPressure, .lowSystemMemory, .footprintOverBudget,
             .oversizedReservation, .memoryGatingDisabled:
            memoryWarning = true
        // Disk, not memory. Blaming an out-of-space run on RAM would send the user to
        // entirely the wrong remedy — and `outputWriteFailed` in particular means the run
        // was reported properly at the time, so there is nothing here to re-diagnose.
        case .outputWriteFailed, .lowDiskSpace, .previousRunDied, .none:
            memoryWarning = false
        }

        let fraction = peakMemoryFraction ?? 0

        if memoryWarning || fraction >= RunMarker.outOfMemoryFootprintFraction {
            return .likelyOutOfMemory(fraction: fraction)
        }
        return .unknown
    }

    // MARK: - Reporting

    private static func gb(_ bytes: UInt64) -> String { bytes.humanReadableBytes }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// One sentence naming the run and what probably happened to it.  This is the headline
    /// — the cli prints it, the gui puts it in an alert title area, the daemon logs it.
    public var summary: String {
        let what = sequenceName.map { "run of \($0)" } ?? "run"
        let when = RunMarker.stamp.string(from: heartbeatAt)
        switch diagnosis {
        case .crashed(let signal):
            return "\(client)'s previous \(what) crashed at \(when) (\(signal))."
        case .likelyOutOfMemory:
            return "\(client)'s previous \(what) stopped unexpectedly at \(when), " +
                   "most likely because the system ran out of memory."
        case .unknown:
            return "\(client)'s previous \(what) stopped unexpectedly at \(when)."
        }
    }

    /// The full report: the summary, the evidence, and what to do next.
    ///
    /// Built here rather than in each client so the three of them cannot drift into saying
    /// three different things about the same marker.
    public var report: String {
        var lines: [String] = [summary, ""]

        if let sequenceName {
            var detail = "  sequence:      \(sequenceName)"
            if let frameCount {
                detail += " (\(frameCount) frames"
                if let imageWidth, let imageHeight, imageWidth > 0, imageHeight > 0 {
                    detail += ", \(imageWidth)×\(imageHeight)"
                }
                detail += ")"
            }
            lines.append(detail)
        }

        lines.append("  started:       \(RunMarker.stamp.string(from: startedAt))")

        var lastSeen = "  last seen:     \(RunMarker.stamp.string(from: heartbeatAt))" +
                       " (after \(RunMarker.duration(heartbeatAt.timeIntervalSince(startedAt)))"
        if let frameCount, frameCount > 0 {
            lastSeen += ", at frame \(framesCompleted) of \(frameCount)"
        }
        lastSeen += ")"
        lines.append(lastSeen)

        if let currentPhase {
            lines.append("  doing:         \(currentPhase)")
        }

        lines.append("  version:       \(client) \(starVersion) (pid \(pid))")

        if hostPhysicalMemoryBytes > 0 {
            var memory = "  memory:        "
            if peakFootprintBytes > 0 {
                memory += "peaked at \(RunMarker.gb(peakFootprintBytes)) of " +
                          "\(RunMarker.gb(hostPhysicalMemoryBytes))"
                if let fraction = peakMemoryFraction {
                    memory += String(format: " (%.0f%%)", fraction * 100)
                }
            } else {
                memory += "\(RunMarker.gb(hostPhysicalMemoryBytes)) on this machine"
            }
            lines.append(memory)
        }

        if let fatalSignal {
            lines.append("  signal:        \(fatalSignal)")
        }

        if let lastWarning {
            lines.append("  last warning:  [\(lastWarning.severity.rawValue)] \(lastWarning.message)")
        }

        if let logPath {
            lines.append("  log:           \(logPath)")
        }

        lines.append("")

        switch diagnosis {
        case .crashed(let signal):
            lines.append("star caught \(signal) and stopped. This is a bug in star, not a " +
                         "problem with your images — please report it.")
            lines.append("")
            lines.append("The operating system also wrote its own crash report, which has the " +
                         "backtrace. On macOS it is the newest file for this program in:")
            lines.append("  ~/Library/Logs/DiagnosticReports/")
            // Only when there is memory evidence as well. A crash under memory pressure is
            // often an allocation that failed rather than a logic error, and in that case the
            // advice below genuinely helps — but offering it every time would tell users to
            // reduce their settings in response to bugs that have nothing to do with memory.
            if let fraction = peakMemoryFraction,
               fraction >= RunMarker.outOfMemoryFootprintFraction
            {
                lines.append("")
                lines.append("Memory was also very high when this happened " +
                             String(format: "(%.0f%% of this machine)", fraction * 100) +
                             ", so the crash may have been a failed allocation. Retrying with " +
                             "--keypoint-divisor 1.5 is worth trying as well as reporting it.")
            }
        case .likelyOutOfMemory:
            lines.append("An out-of-memory kill cannot be caught and reported as it happens — " +
                         "the system stops the process outright — which is why this is being " +
                         "reported now rather than at the time.")
            lines.append("")
            lines.append("To use less memory on the next attempt:")
            lines.append("  --keypoint-divisor 1.5      detect keypoints at reduced resolution")
            lines.append("  --num-concurrent-renders N  process fewer frames at once")
            lines.append("  --max-keypoint-ops 1        serialise the most expensive step")
        case .unknown:
            lines.append("Nothing in the record points at a cause. If there is a log above, " +
                         "its last lines are the best evidence.")
        }

        if let resumeConfigPath {
            lines.append("")
            lines.append("To resume this run where it stopped:")
            lines.append("  star \(resumeConfigPath)")
        }

        return lines.joined(separator: "\n")
    }

    /// The report condensed to fit somewhere with no room for it — a gui banner, a
    /// notification.  `report` is what goes in the log and the terminal.
    public var briefReport: String {
        var text = summary
        switch diagnosis {
        case .crashed:
            text += " This is a bug in star — please report it."
        case .likelyOutOfMemory:
            text += " Try --keypoint-divisor 1.5, or fewer concurrent renders."
        case .unknown:
            break
        }
        if let resumeConfigPath {
            text += " Resume with: star \(resumeConfigPath)"
        }
        return text
    }

    /// The marker as a `StarWarning`, so a client that has already wired up warnings gets
    /// crash reporting through the same path with no extra plumbing.
    public var asWarning: StarWarning {
        StarWarning(kind: .previousRunDied,
                    severity: .critical,
                    message: summary,
                    suggestion: briefReport == summary ? nil
                      : String(briefReport.dropFirst(summary.count)).trimmingCharacters(in: .whitespaces),
                    time: heartbeatAt)
    }
}

/// Writes, refreshes and reaps `RunMarker`s.
///
/// Lifecycle, from a client's point of view:
///
///     // at startup, before doing anything expensive
///     for marker in await RunMarkerStore.shared.abandonedRuns() { report(marker) }
///     await RunMarkerStore.shared.clearAbandoned()
///
///     // once there is a sequence to describe
///     await RunMarkerStore.shared.begin(client: "star", sequenceName: name, ...)
///
///     // on the way out, however the run ended
///     await RunMarkerStore.shared.finish()
///
/// `finish()` is the only thing that distinguishes a crash from a clean exit, so it must
/// be reached on *every* non-crash path — including a failed run.  A run that threw an
/// error and reported it properly is not a crash, and reporting it as one at the next
/// launch would be worse than saying nothing.
public actor RunMarkerStore {

    public static let shared = RunMarkerStore()

    /// How often the marker is rewritten.  Small enough that "last seen" is a useful
    /// approximation of the time of death, large enough to be free.
    public static let heartbeatInterval: TimeInterval = 15

    /// How stale a heartbeat must be before a marker whose pid still appears alive is
    /// treated as abandoned.
    ///
    /// Generous — 20 heartbeats — because the false positive here is telling a user their
    /// perfectly healthy concurrent run has crashed.  The pid check below is what catches
    /// the ordinary case promptly; this only has to catch the two cases the pid check
    /// cannot: a pid that has been reused by an unrelated process, and Windows, where there
    /// is no portable liveness check at all.
    public static let staleHeartbeatAge: TimeInterval = heartbeatInterval * 20

    private let directory: URL
    private var marker: RunMarker?
    private var heartbeat: Task<Void, Never>?

    /// Markers reported by `abandonedRuns()` and awaiting `clearAbandoned()`.
    private var reported: [RunMarker] = []

    /// - Parameter directory: where markers live.  Defaults to a per-user location shared
    ///   by every client, so the gui can report a cli crash and vice versa.  Tests pass a
    ///   temporary directory.
    public init(directory: URL? = nil) {
        self.directory = directory ?? RunMarkerStore.defaultDirectory()
    }

    /// `<application support>/star/runs`, falling back to the temp directory.
    ///
    /// Not the documents directory that `FileLogHandler` uses: these are machine state, not
    /// something a user should find sitting next to their logs.
    public static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
        let base = support ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("star", isDirectory: true)
                   .appendingPathComponent("runs", isDirectory: true)
    }

    // MARK: - Writing

    /// Start recording this run.  Overwrites any marker this process had already begun,
    /// which is what the gui wants when the user opens a second sequence.
    public func begin(client: String,
                      sequenceName: String? = nil,
                      sequencePath: String? = nil,
                      resumeConfigPath: String? = nil,
                      logPath: String? = nil,
                      frameCount: Int? = nil,
                      imageWidth: Int? = nil,
                      imageHeight: Int? = nil,
                      imageBytesPerPixel: Int? = nil)
    {
        heartbeat?.cancel()
        heartbeat = nil

        // Delete the marker this process had already begun, if any.  Without this a client
        // that calls `begin` twice leaves the first file behind forever: `finish()` only
        // removes the current one, and once this process exits the orphan's pid is dead, so
        // the *next* launch reports a crash that never happened.
        if let previous = marker {
            try? FileManager.default.removeItem(at: fileURL(for: previous.id))
        }
        completedFrames = []

        let pid = ProcessInfo.processInfo.processIdentifier
        let started = Date()

        // A note sitting under our own pid belongs to a dead process that happened to have it
        // first. Left in place it would be read back as *this* run having crashed.
        StarCrashHandler.clearNote(pid: pid, in: directory)
        // The id has to be unique across concurrent runs and across pid reuse, hence both
        // the pid and the start time to the second.
        let id = "\(client)-\(pid)-\(Int(started.timeIntervalSince1970))"

        var new = RunMarker(id: id, client: client, pid: pid, startedAt: started)
        new.sequenceName = sequenceName
        new.sequencePath = sequencePath
        new.resumeConfigPath = resumeConfigPath
        new.logPath = logPath
        new.frameCount = frameCount
        new.imageWidth = imageWidth
        new.imageHeight = imageHeight
        new.imageBytesPerPixel = imageBytesPerPixel
        new.peakFootprintBytes = star_process_footprint()
        // Seed from anything already noticed.  Clients install the warning handler before
        // `begin` (the cli does it while still resolving the sequence), so a warning can
        // arrive first — and if the process is killed before the first heartbeat, this is the
        // only chance the marker gets to carry it.  That window is small but it is exactly
        // the early-OOM case worth diagnosing.
        new.lastWarning = latestWarningSnapshot

        self.marker = new
        RunMarkerStore.livePath = fileURL(for: id).path
        write()

        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(RunMarkerStore.heartbeatInterval))
                if Task.isCancelled { return }
                await self?.beat()
            }
        }

        Log.i("run marker \(id) written to \(directory.path)")
    }

    /// Fill in what the run turned out to be, once the client knows.  Every parameter is
    /// optional so a caller can set one field without knowing the others.
    ///
    /// Deliberately does not write: the heartbeat picks these up within
    /// `heartbeatInterval`.  A marker is only ever read after the process that wrote it is
    /// gone, so a file write per update would be real I/O for no benefit.
    public func update(framesCompleted: Int? = nil,
                       phase: String? = nil,
                       frameCount: Int? = nil,
                       resumeConfigPath: String? = nil,
                       logPath: String? = nil,
                       imageWidth: Int? = nil,
                       imageHeight: Int? = nil,
                       imageBytesPerPixel: Int? = nil)
    {
        guard var marker else { return }
        if let framesCompleted { marker.framesCompleted = framesCompleted }
        if let phase { marker.currentPhase = phase }
        if let frameCount { marker.frameCount = frameCount }
        if let resumeConfigPath { marker.resumeConfigPath = resumeConfigPath }
        if let logPath { marker.logPath = logPath }
        if let imageWidth { marker.imageWidth = imageWidth }
        if let imageHeight { marker.imageHeight = imageHeight }
        if let imageBytesPerPixel { marker.imageBytesPerPixel = imageBytesPerPixel }
        self.marker = marker
    }

    /// Name the sequence this run is working on, after `begin`.
    ///
    /// The cli knows what it is processing before it starts and passes it to `begin`; the
    /// daemon and the gui do not — they come up first and are handed a sequence later, and
    /// may be handed a different one after that.  Resets the progress count, since frame 40
    /// of the last sequence says nothing about this one.
    public func describe(sequenceName: String?, sequencePath: String? = nil) {
        guard marker != nil else { return }
        marker?.sequenceName = sequenceName
        marker?.sequencePath = sequencePath
        completedFrames = []
        marker?.framesCompleted = 0
        write()
    }

    /// Which frames have reached their terminal state.  A set rather than a counter because
    /// the state-change callback fires many times per frame and more than once for the
    /// terminal state, so counting calls would overcount badly.
    private var completedFrames: Set<Int> = []

    /// Record progress from a frame state change.  Cheap enough to call on every one.
    public func note(phase: String? = nil, frameCompleted: Int? = nil) {
        guard marker != nil else { return }
        if let frameCompleted {
            completedFrames.insert(frameCompleted)
            marker?.framesCompleted = completedFrames.count
        }
        if let phase { marker?.currentPhase = phase }
    }

    /// Stop recording: the run ended in a way star knows about.  Idempotent.
    ///
    /// This is the only thing that distinguishes a crash from a clean exit, so it has to be
    /// reached on every non-crash path — *including* a run that failed and reported the
    /// failure properly.  An error that was caught and shown to the user is not a crash, and
    /// reporting it as one at the next launch would be worse than saying nothing.
    public func finish() {
        heartbeat?.cancel()
        heartbeat = nil
        completedFrames = []
        RunMarkerStore.livePath = nil
        guard let marker else { return }
        let url = fileURL(for: marker.id)
        try? FileManager.default.removeItem(at: url)
        self.marker = nil
        Log.i("run marker \(marker.id) cleared — this run ended cleanly")
    }

    /// The current marker, for tests and for a client that wants to show run state.
    public func current() -> RunMarker? { marker }

    private func beat() {
        guard var marker else { return }
        marker.heartbeatAt = Date()
        let footprint = star_process_footprint()
        if footprint > marker.peakFootprintBytes { marker.peakFootprintBytes = footprint }
        marker.lastWarning = latestWarningSnapshot
        self.marker = marker
        write()
    }

    /// Cached rather than awaited inside `beat()`: reaching into another actor from the
    /// heartbeat would make the write wait on `StarWarnings`, and the whole point of the
    /// heartbeat is that it is never in anybody's way.  `noteLatest(warning:)` pushes
    /// instead.
    private var latestWarningSnapshot: StarWarning?

    /// Called by whoever installs the warning handler, so the marker carries the last thing
    /// star noticed.  See `Callbacks.installWarningHandler()`.
    public func note(warning: StarWarning) {
        latestWarningSnapshot = warning
        // A critical warning is exactly the thing we most want on disk before a kill, so
        // this one does not wait for the next heartbeat.
        if warning.severity == .critical, marker != nil {
            beat()
        }
    }

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    /// The live marker's path, readable without entering the actor.
    ///
    /// `NSApplicationDelegate.applicationWillTerminate` and other last-gasp hooks are
    /// synchronous and get no opportunity to await an actor — and blocking the main thread
    /// on one during termination risks not finishing at all.  Written only from `begin` and
    /// `finish` on the actor, read only by `finishWithoutWaiting()`, so the unsafety is a
    /// pointer-sized write racing a read that at worst unlinks a path that was already
    /// unlinked.
    private nonisolated(unsafe) static var livePath: String?

    /// Clear the marker from a synchronous context.  Best effort, and safe to call after
    /// `finish()` has already run.
    ///
    /// Prefer `finish()` wherever there is an async context to call it from; this exists for
    /// the ones where there is not.
    public nonisolated static func finishWithoutWaiting() {
        guard let path = livePath else { return }
        try? FileManager.default.removeItem(atPath: path)
        livePath = nil
    }

    private func write() {
        guard let marker else { return }
        do {
            try FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(marker)
            // Atomic: a marker half-written when the process dies would be undecodable,
            // and an undecodable marker is a crash report we cannot read.
            try data.write(to: fileURL(for: marker.id), options: .atomic)
        } catch {
            // Never fatal.  Failing to write a breadcrumb must not be the thing that
            // breaks a run, and there is nothing the user can do about it.
            Log.w("could not write run marker: \(error)")
        }
    }

    // MARK: - Reaping

    /// Markers left behind by runs that are no longer alive, newest first.
    ///
    /// Excludes this process's own marker, and any marker whose process is still running
    /// with a fresh heartbeat — so a second star started while the first is working does
    /// not accuse the first of having crashed.
    public func abandonedRuns() -> [RunMarker] {
        let ourPid = ProcessInfo.processInfo.processIdentifier
        let now = Date()

        guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil)
        else {
            return []
        }

        var found: [RunMarker] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Pids whose crash note has been claimed by a marker below.  Whatever is left over
        // crashed without a marker to attach to — before `begin`, or in a process that never
        // wrote one — and is reported on its own rather than thrown away.
        var notePids = Set<Int32>()
        for url in contents where url.pathExtension == "signal" {
            if let pid = Int32(url.deletingPathExtension().lastPathComponent) {
                notePids.insert(pid)
            }
        }

        for url in contents where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }

            guard var marker = try? decoder.decode(RunMarker.self, from: data) else {
                // Undecodable: a truncated write, or a marker from a version whose fields
                // this one cannot read.  Delete it rather than accumulating it forever, and
                // say so at debug level — reporting "a run crashed" on the strength of a
                // file we cannot read would be a guess dressed as a finding.
                Log.d("discarding unreadable run marker at \(url.lastPathComponent)")
                try? FileManager.default.removeItem(at: url)
                continue
            }

            if marker.pid == ourPid, marker.id == self.marker?.id { continue }

            let stale = now.timeIntervalSince(marker.heartbeatAt) > RunMarkerStore.staleHeartbeatAge
            if !stale, RunMarkerStore.processIsAlive(pid: marker.pid) { continue }

            // How it ended, from the note the signal handler left. A marker on its own only
            // proves the run never finished; this is what turns that into a named cause.
            marker.fatalSignal = StarCrashHandler.caughtSignal(pid: marker.pid, in: directory)
            if marker.fatalSignal != nil { notePids.remove(marker.pid) }

            found.append(marker)
        }

        // Crash notes with no surviving marker. A crash before `begin` — while resolving the
        // sequence, loading a config, probing a video — leaves one of these, and the fact that
        // star crashed is worth reporting even without knowing what it was working on.
        for pid in notePids where !(pid == ourPid) {
            guard !RunMarkerStore.processIsAlive(pid: pid) else { continue }
            guard let signal = StarCrashHandler.caughtSignal(pid: pid, in: directory) else { continue }
            let url = StarCrashHandler.noteURL(pid: pid, in: directory)
            let when = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
                as? Date ?? Date()

            var marker = RunMarker(id: "signal-\(pid)", client: "star", pid: pid, startedAt: when)
            marker.fatalSignal = signal
            found.append(marker)
        }

        found.sort { $0.heartbeatAt > $1.heartbeatAt }
        reported = found
        return found
    }

    /// Delete the markers the last `abandonedRuns()` returned, so the next launch does not
    /// report them again.  Separate from `abandonedRuns()` so a client can decide to keep
    /// them — the gui defers this until the user has dismissed the report.
    public func clearAbandoned() {
        for marker in reported {
            try? FileManager.default.removeItem(at: fileURL(for: marker.id))
            // The crash note too, otherwise it would be re-reported forever as an
            // orphan once its marker was gone.
            StarCrashHandler.clearNote(pid: marker.pid, in: directory)
        }
        reported = []
    }

    /// Whether a process with this pid exists.
    ///
    /// `kill(pid, 0)` sends no signal; it only performs the existence and permission
    /// checks.  `EPERM` means the process exists but belongs to somebody else, which for
    /// this purpose is still alive.
    ///
    /// Windows has no equivalent in the C runtime Swift exposes there, so it answers "alive"
    /// unconditionally and liveness falls back entirely to `staleHeartbeatAge`.  That makes
    /// a Windows crash report late rather than absent.
    static func processIsAlive(pid: Int32) -> Bool {
        #if os(Windows)
        return true
        #else
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
        #endif
    }
}
