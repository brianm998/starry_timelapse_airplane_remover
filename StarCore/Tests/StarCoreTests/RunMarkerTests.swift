import XCTest
@testable import StarCore

/// `RunMarker` is star's answer to the one crash it can never catch: an out-of-memory kill
/// arrives as `SIGKILL`, so no handler runs and nothing gets written.  The strategy is to
/// record the run while it is alive and treat a record that outlived its process as the crash
/// report.
///
/// That makes two behaviours load-bearing, and they pull in opposite directions:
///
///   - a run that ended in any way star knows about must leave **nothing** behind, or every
///     normal quit becomes a false crash report;
///   - a run that was killed must leave a record that survives and stays readable.
///
/// Most of what follows is about the boundary between those two.
final class RunMarkerTests: XCTestCase {

    /// A pid above macOS's `PID_MAX` (99999), so it can never belong to a live process and
    /// `processIsAlive` is guaranteed to say so.
    private let deadPid: Int32 = 999_999

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
          .appendingPathComponent("run-marker-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> RunMarkerStore {
        RunMarkerStore(directory: directory)
    }

    private func markerFileCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
          .filter { $0.pathExtension == "json" }.count
    }

    /// Write a marker file directly, bypassing `begin`, so a test can describe a run that
    /// already died without having to kill a process.
    private func writeMarker(_ mutate: (inout RunMarker) -> Void) throws -> RunMarker {
        var marker = RunMarker(id: "test-\(UUID().uuidString)",
                               client: "star",
                               pid: deadPid,
                               startedAt: Date().addingTimeInterval(-3600))
        marker.heartbeatAt = marker.startedAt.addingTimeInterval(1800)
        mutate(&marker)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(marker)
        try data.write(to: directory.appendingPathComponent("\(marker.id).json"))
        return marker
    }

    // MARK: - The clean-exit contract

    /// The whole scheme rests on this: `finish()` must leave nothing behind, because a
    /// leftover file is indistinguishable from a crash.
    func testFinishRemovesTheMarkerFile() async throws {
        let store = self.store()
        await store.begin(client: "star", sequenceName: "seq")
        XCTAssertEqual(try markerFileCount(), 1)

        await store.finish()
        XCTAssertEqual(try markerFileCount(), 0)
        let current = await store.current()
        XCTAssertNil(current)
    }

    /// `finish()` is called from several exit paths in each client and some of them overlap,
    /// so calling it twice must not throw or resurrect anything.
    func testFinishIsIdempotent() async throws {
        let store = self.store()
        await store.begin(client: "star")
        await store.finish()
        await store.finish()
        XCTAssertEqual(try markerFileCount(), 0)
    }

    /// The gui begins a marker at launch and could begin another one later.  The first file
    /// has to go with it — `finish()` only knows about the current marker, so an orphan
    /// would sit in the directory until this process exited and then be reported as a crash
    /// at the next launch, which is exactly the false positive this whole thing must not
    /// produce.
    func testBeginningASecondRunRemovesTheFirstMarkerFile() async throws {
        let store = self.store()
        await store.begin(client: "star", sequenceName: "first")
        await store.begin(client: "star", sequenceName: "second")

        XCTAssertEqual(try markerFileCount(), 1,
                       "the first marker was orphaned — it will be reported as a crash later")
        let current = await store.current()
        XCTAssertEqual(current?.sequenceName, "second")
    }

    /// A synchronous last-gasp hook (`applicationWillTerminate`) has no way to await the
    /// actor, so it gets its own path.  It has to clear the same file.
    func testFinishWithoutWaitingRemovesTheMarkerFile() async throws {
        let store = self.store()
        await store.begin(client: "Star")
        XCTAssertEqual(try markerFileCount(), 1)

        RunMarkerStore.finishWithoutWaiting()
        XCTAssertEqual(try markerFileCount(), 0)
    }

    // MARK: - Detecting an abandoned run

    /// The positive case: a marker whose process is gone is a crash report.
    func testAMarkerFromADeadProcessIsReportedAsAbandoned() async throws {
        let written = try writeMarker { $0.sequenceName = "some_sequence" }

        let abandoned = await store().abandonedRuns()
        XCTAssertEqual(abandoned.count, 1)
        XCTAssertEqual(abandoned.first?.id, written.id)
        XCTAssertEqual(abandoned.first?.sequenceName, "some_sequence")
    }

    /// The most important negative case.  Two stars can run at once, and accusing a healthy
    /// concurrent run of having crashed is worse than saying nothing — so a marker whose pid
    /// is alive *and* whose heartbeat is fresh is left alone.
    func testALiveRunWithAFreshHeartbeatIsNotReported() async throws {
        _ = try writeMarker {
            $0.pid = ProcessInfo.processInfo.processIdentifier
            $0.heartbeatAt = Date()
        }

        let abandoned = await store().abandonedRuns()
        XCTAssertTrue(abandoned.isEmpty)
    }

    /// The other half of liveness.  A pid can be reused by an unrelated process, and on
    /// Windows there is no liveness check at all — in both cases a heartbeat that stopped
    /// long ago is the only evidence, so it has to be sufficient on its own.
    func testALiveLookingPidWithAStaleHeartbeatIsReported() async throws {
        _ = try writeMarker {
            $0.pid = ProcessInfo.processInfo.processIdentifier
            $0.heartbeatAt = Date()
              .addingTimeInterval(-RunMarkerStore.staleHeartbeatAge - 60)
        }

        let abandoned = await store().abandonedRuns()
        XCTAssertEqual(abandoned.count, 1)
    }

    /// A store never reports the run it is itself recording, whatever else is in the
    /// directory.
    func testAStoreDoesNotReportItsOwnRun() async throws {
        let store = self.store()
        await store.begin(client: "star")
        let abandoned = await store.abandonedRuns()
        XCTAssertTrue(abandoned.isEmpty)
    }

    /// A marker written while the process was dying can be truncated, and a marker from a
    /// future version may not decode.  Either way star must not claim a crash on the
    /// strength of a file it cannot read — and must not keep the unreadable file forever.
    func testAnUnreadableMarkerIsDiscardedRatherThanReported() async throws {
        try Data("{ not json".utf8)
          .write(to: directory.appendingPathComponent("broken.json"))

        let abandoned = await store().abandonedRuns()
        XCTAssertTrue(abandoned.isEmpty)
        XCTAssertEqual(try markerFileCount(), 0, "the unreadable marker was left to accumulate")
    }

    /// Reported markers are cleared explicitly, so the same crash is not reported at every
    /// launch from then on.
    func testClearAbandonedRemovesWhatWasReported() async throws {
        _ = try writeMarker { _ in }
        let store = self.store()

        let reported = await store.abandonedRuns()
        XCTAssertEqual(reported.count, 1)
        await store.clearAbandoned()

        XCTAssertEqual(try markerFileCount(), 0)
        let afterClearing = await store.abandonedRuns()
        XCTAssertTrue(afterClearing.isEmpty)
    }

    /// Newest first: when several runs died, the one the user just lost is the one they care
    /// about.
    func testAbandonedRunsAreNewestFirst() async throws {
        let old = try writeMarker { $0.heartbeatAt = Date().addingTimeInterval(-7200) }
        let recent = try writeMarker { $0.heartbeatAt = Date().addingTimeInterval(-60) }

        let abandoned = await store().abandonedRuns()
        XCTAssertEqual(abandoned.map(\.id), [recent.id, old.id])
    }

    // MARK: - Progress recording

    /// Frame progress comes from the state-change callback, which fires many times per frame
    /// and more than once for the terminal state.  Counting calls would overcount wildly, so
    /// the count is of distinct frames.
    func testFrameProgressCountsDistinctFramesNotCallbacks() async throws {
        let store = self.store()
        await store.begin(client: "star", frameCount: 10)

        await store.note(phase: "complete", frameCompleted: 3)
        await store.note(phase: "complete", frameCompleted: 3)
        await store.note(phase: "complete", frameCompleted: 4)

        let marker = await store.current()
        XCTAssertEqual(marker?.framesCompleted, 2)
    }

    /// Opening a different sequence resets progress: frame 40 of the last sequence says
    /// nothing about this one.
    func testDescribingANewSequenceResetsProgress() async throws {
        let store = self.store()
        await store.begin(client: "Star")
        await store.note(frameCompleted: 1)
        await store.note(frameCompleted: 2)

        await store.describe(sequenceName: "another_sequence")

        let marker = await store.current()
        XCTAssertEqual(marker?.sequenceName, "another_sequence")
        XCTAssertEqual(marker?.framesCompleted, 0)
    }

    /// Updates before `begin` (or after `finish`) are dropped rather than trapping — clients
    /// call these from callbacks whose lifetime they do not tightly control.
    func testUpdatesWithNoRunInProgressAreIgnored() async throws {
        let store = self.store()
        await store.note(phase: "whatever", frameCompleted: 1)
        await store.update(frameCount: 5)
        await store.describe(sequenceName: "nope")
        let current = await store.current()
        XCTAssertNil(current)
        XCTAssertEqual(try markerFileCount(), 0)
    }

    // MARK: - A caught fatal signal

    /// Write a crash note the way the C handler does: the signal's name and a newline.
    private func writeNote(pid: Int32, signal: String = "SIGSEGV") throws {
        try Data("\(signal)\n".utf8)
          .write(to: directory.appendingPathComponent(StarCrashHandler.noteFileName(pid: pid)))
    }

    /// The pairing that makes the two halves worth more than either alone: the marker says
    /// what the run was doing, the note says how it ended.
    func testACrashNoteIsAttachedToItsMarker() async throws {
        let written = try writeMarker { $0.sequenceName = "seq" }
        try writeNote(pid: written.pid, signal: "SIGBUS")

        let abandoned = await store().abandonedRuns()
        XCTAssertEqual(abandoned.count, 1)
        XCTAssertEqual(abandoned.first?.fatalSignal, "SIGBUS")
        XCTAssertEqual(abandoned.first?.sequenceName, "seq")
    }

    /// A crash before `begin` — while resolving a sequence, loading a config, probing a video
    /// — leaves a note with no marker.  That star crashed is worth reporting even when there
    /// is nothing to say about what it was doing.
    func testACrashNoteWithNoMarkerIsStillReported() async throws {
        try writeNote(pid: deadPid, signal: "SIGABRT")

        let abandoned = await store().abandonedRuns()
        XCTAssertEqual(abandoned.count, 1)
        XCTAssertEqual(abandoned.first?.fatalSignal, "SIGABRT")
        XCTAssertTrue(abandoned.first?.report.contains("SIGABRT") ?? false)
    }

    /// An orphan note must obey the same liveness rule as a marker, or a running process that
    /// caught and survived something would be reported as dead.
    func testAnOrphanNoteFromALiveProcessIsNotReported() async throws {
        try writeNote(pid: ProcessInfo.processInfo.processIdentifier)
        let abandoned = await store().abandonedRuns()
        XCTAssertTrue(abandoned.isEmpty)
    }

    /// The handler writes the note while the process is already dying, so it can be truncated
    /// to nothing.  An empty note still means "something was caught" — downgrading that to
    /// "stopped for no reason" would throw away the one fact it does establish.
    func testAnEmptyCrashNoteStillCountsAsACrash() async throws {
        let written = try writeMarker { _ in }
        try Data().write(to: directory.appendingPathComponent(
                           StarCrashHandler.noteFileName(pid: written.pid)))

        let abandoned = await store().abandonedRuns()
        XCTAssertEqual(abandoned.count, 1)
        XCTAssertNotNil(abandoned.first?.fatalSignal)
        guard case .crashed = abandoned.first?.diagnosis else {
            return XCTFail("an empty note should still read as a crash")
        }
    }

    /// Clearing has to take the note as well.  Left behind, it would have no marker next time
    /// and be re-reported as an orphan crash at every launch from then on.
    func testClearingAlsoRemovesTheCrashNote() async throws {
        let written = try writeMarker { _ in }
        try writeNote(pid: written.pid)
        let store = self.store()

        let reported = await store.abandonedRuns()
        XCTAssertEqual(reported.count, 1)
        await store.clearAbandoned()

        let afterClearing = await store.abandonedRuns()
        XCTAssertTrue(afterClearing.isEmpty, "the crash note outlived its marker")
    }

    /// Pids get reused.  A note left under a pid that this process has now been given would
    /// otherwise be read back as this run having crashed before it started.
    func testBeginningARunClearsAStaleNoteUnderOurOwnPid() async throws {
        try writeNote(pid: ProcessInfo.processInfo.processIdentifier)
        let store = self.store()
        await store.begin(client: "star")

        let note = directory.appendingPathComponent(
          StarCrashHandler.noteFileName(pid: ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
    }

    // MARK: - Diagnosis

    /// The payoff.  A run holding most of the machine when it stopped is called a likely
    /// out-of-memory kill, because that is the one conclusion the evidence supports and the
    /// one the user can act on.
    func testAHighPeakFootprintReadsAsLikelyOutOfMemory() {
        var marker = RunMarker(id: "x", client: "star",
                               hostPhysicalMemoryBytes: 16 * 1024 * 1024 * 1024)
        marker.peakFootprintBytes = 15 * 1024 * 1024 * 1024

        guard case .likelyOutOfMemory(let fraction) = marker.diagnosis else {
            return XCTFail("expected an out-of-memory diagnosis, got \(marker.diagnosis)")
        }
        XCTAssertEqual(fraction, 15.0 / 16.0, accuracy: 0.001)
    }

    /// A memory warning is enough on its own, without a high footprint.
    ///
    /// This is the case the sampled footprint cannot cover: memory pressure is reported
    /// system-wide, so star can be killed while its own footprint looks unremarkable —
    /// something else on the machine was the hog.  Requiring both signals would miss it.
    func testAMemoryWarningAloneReadsAsLikelyOutOfMemory() {
        var marker = RunMarker(id: "x", client: "star",
                               hostPhysicalMemoryBytes: 64 * 1024 * 1024 * 1024)
        marker.peakFootprintBytes = 1024 * 1024 * 1024      // 1GB of 64GB — nothing
        marker.lastWarning = StarWarning(kind: .memoryPressure,
                                         severity: .critical,
                                         message: "low")

        guard case .likelyOutOfMemory = marker.diagnosis else {
            return XCTFail("a memory-pressure warning should be enough on its own")
        }
    }

    /// And the honest case: a run that stopped while using very little memory, with nothing
    /// recorded about why, is not blamed on memory.  Over-claiming here would send users
    /// chasing a memory problem they do not have.
    func testAModestFootprintWithNoWarningIsNotBlamedOnMemory() {
        var marker = RunMarker(id: "x", client: "star",
                               hostPhysicalMemoryBytes: 64 * 1024 * 1024 * 1024)
        marker.peakFootprintBytes = 2 * 1024 * 1024 * 1024

        XCTAssertEqual(marker.diagnosis, .unknown)
        XCTAssertFalse(marker.report.lowercased().contains("out of memory"),
                       "an unexplained stop must not be reported as an out-of-memory kill")
    }

    /// `previousRunDied` is the kind star posts *about* a marker, so finding it recorded as
    /// the last warning says nothing about memory and must not be read as if it did.
    func testAPreviousRunDiedWarningIsNotItselfMemoryEvidence() {
        var marker = RunMarker(id: "x", client: "star",
                               hostPhysicalMemoryBytes: 64 * 1024 * 1024 * 1024)
        marker.peakFootprintBytes = 1024 * 1024 * 1024
        marker.lastWarning = StarWarning(kind: .previousRunDied,
                                         severity: .critical,
                                         message: "an earlier run died")

        XCTAssertEqual(marker.diagnosis, .unknown)
    }

    /// Missing numbers must not divide by zero or read as 0% used.
    func testAMarkerWithNoMemoryNumbersHasNoFraction() {
        let marker = RunMarker(id: "x", client: "star", hostPhysicalMemoryBytes: 0)
        XCTAssertNil(marker.peakMemoryFraction)
        XCTAssertEqual(marker.diagnosis, .unknown)
    }

    // MARK: - The report

    /// The report exists to be read by somebody who has just lost a long run and has no
    /// other information.  These are the things it must not omit.
    func testTheReportNamesTheSequenceTheProgressAndTheResumeCommand() throws {
        var marker = RunMarker(id: "x", client: "star",
                               hostPhysicalMemoryBytes: 16 * 1024 * 1024 * 1024)
        marker.sequenceName = "my_sequence"
        marker.frameCount = 312
        marker.framesCompleted = 47
        marker.imageWidth = 7952
        marker.imageHeight = 5304
        marker.peakFootprintBytes = 15 * 1024 * 1024 * 1024
        marker.resumeConfigPath = "/tmp/star_temp_my_sequence/config.json"
        marker.logPath = "/Users/somebody/Documents/star-log.txt"

        let report = marker.report
        XCTAssertTrue(report.contains("my_sequence"))
        XCTAssertTrue(report.contains("312"))
        XCTAssertTrue(report.contains("47"))
        XCTAssertTrue(report.contains("7952×5304"))
        XCTAssertTrue(report.contains("/Users/somebody/Documents/star-log.txt"))
        XCTAssertTrue(report.contains("star /tmp/star_temp_my_sequence/config.json"),
                      "the report must print a resume command the user can actually run")
        XCTAssertTrue(report.contains("keypoint-divisor"),
                      "an out-of-memory report must say how to use less memory")
    }

    /// A marker recorded before the run's shape was known still has to produce a report
    /// rather than a crash or a wall of "nil" — the daemon writes its marker before it has a
    /// session, so this is the normal state for an early death.
    func testAMarkerWithAlmostNothingRecordedStillReports() {
        let marker = RunMarker(id: "x", client: "stard")
        XCTAssertFalse(marker.summary.isEmpty)
        XCTAssertFalse(marker.report.isEmpty)
        XCTAssertFalse(marker.report.contains("nil"))
        XCTAssertFalse(marker.briefReport.isEmpty)
    }

    /// A caught signal is observed, not inferred, so it outranks the footprint heuristic.
    /// It also changes the advice completely — "you found a bug" rather than "use less
    /// memory" — so getting the precedence wrong sends users to the wrong remedy.
    func testACaughtSignalOutranksTheMemoryHeuristic() {
        var marker = RunMarker(id: "x", client: "star",
                               hostPhysicalMemoryBytes: 16 * 1024 * 1024 * 1024)
        marker.peakFootprintBytes = 15 * 1024 * 1024 * 1024   // would read as OOM on its own
        marker.fatalSignal = "SIGSEGV"

        XCTAssertEqual(marker.diagnosis, .crashed(signal: "SIGSEGV"))
        let report = marker.report
        XCTAssertTrue(report.contains("SIGSEGV"))
        XCTAssertTrue(report.contains("bug in star"))
        XCTAssertTrue(report.contains("DiagnosticReports"),
                      "the report should point at the OS crash report, which has the backtrace")
    }

    /// When memory was also very high, a crash is plausibly a failed allocation, so the
    /// memory advice is worth adding on top of "report this".
    func testACrashUnderHighMemoryAlsoMentionsMemory() {
        var marker = RunMarker(id: "x", client: "star",
                               hostPhysicalMemoryBytes: 16 * 1024 * 1024 * 1024)
        marker.peakFootprintBytes = 15 * 1024 * 1024 * 1024
        marker.fatalSignal = "SIGABRT"

        XCTAssertTrue(marker.report.contains("keypoint-divisor"))
    }

    /// And when memory was not a factor, it must not be mentioned — otherwise every bug
    /// report comes with irrelevant advice to reduce settings, and users act on it.
    func testACrashAtLowMemoryDoesNotSuggestMemorySettings() {
        var marker = RunMarker(id: "x", client: "star",
                               hostPhysicalMemoryBytes: 64 * 1024 * 1024 * 1024)
        marker.peakFootprintBytes = 2 * 1024 * 1024 * 1024
        marker.fatalSignal = "SIGSEGV"

        XCTAssertFalse(marker.report.contains("keypoint-divisor"))
    }

    /// The summary is what a gui alert and a log line both show, so it has to name the signal
    /// without the rest of the report.
    func testTheSummaryOfACrashNamesTheSignal() {
        var marker = RunMarker(id: "x", client: "Star")
        marker.sequenceName = "seq"
        marker.fatalSignal = "SIGTRAP"

        XCTAssertTrue(marker.summary.contains("crashed"))
        XCTAssertTrue(marker.summary.contains("SIGTRAP"))
        XCTAssertTrue(marker.briefReport.contains("report it"))
    }

    // MARK: - Restarting the run that stopped

    /// The gui offers a "Restart Now" button on the crash report, and it can only do that if
    /// there is a config to re-open.
    func testAMarkerWithAConfigStillOnDiskCanBeRestarted() throws {
        let config = directory.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: config)

        var marker = RunMarker(id: "x", client: "Star")
        marker.resumeConfigPath = config.path

        XCTAssertEqual(marker.restartableConfigPath, config.path)
    }

    /// A marker is read at the *next* launch, which may be long after the run died, so the
    /// path in it is a claim about the past.  Offering a restart that fails after the click
    /// is worse than not offering one.
    func testAMarkerWhoseConfigHasGoneCannotBeRestarted() {
        var marker = RunMarker(id: "x", client: "Star")
        marker.resumeConfigPath = directory.appendingPathComponent("gone.json").path

        XCTAssertNil(marker.restartableConfigPath)
    }

    /// The daemon writes its marker before it has a session, and a run killed that early
    /// never named a config at all.
    func testAMarkerThatNamedNoConfigCannotBeRestarted() {
        let marker = RunMarker(id: "x", client: "stard")

        XCTAssertNil(marker.restartableConfigPath)
    }

    // MARK: - Liveness

    func testAPidAboveTheSystemMaximumIsNotAlive() throws {
        #if os(Windows)
        throw XCTSkip("Windows has no liveness check; staleness covers it")
        #else
        XCTAssertFalse(RunMarkerStore.processIsAlive(pid: deadPid))
        #endif
    }

    func testOurOwnPidIsAlive() {
        XCTAssertTrue(
          RunMarkerStore.processIsAlive(pid: ProcessInfo.processInfo.processIdentifier))
    }

    /// Pid 0 and negatives are not processes, and `kill(0, 0)` means "the whole process
    /// group" — passing it through would report the group as alive and suppress a real crash
    /// report.
    func testPidZeroIsNotTreatedAsAlive() throws {
        #if os(Windows)
        throw XCTSkip("Windows has no liveness check; staleness covers it")
        #else
        XCTAssertFalse(RunMarkerStore.processIsAlive(pid: 0))
        XCTAssertFalse(RunMarkerStore.processIsAlive(pid: -1))
        #endif
    }

    // MARK: - Round trip

    /// The marker is only ever read by a *different* process than wrote it, so an encoding
    /// that does not round trip means the crash report is silently lost.
    func testAMarkerRoundTripsThroughTheFileItIsWrittenTo() async throws {
        let store = self.store()
        await store.begin(client: "star",
                          sequenceName: "seq",
                          sequencePath: "/some/path",
                          logPath: "/some/log.txt",
                          frameCount: 100,
                          imageWidth: 1920,
                          imageHeight: 1080,
                          imageBytesPerPixel: 6)

        // Read it back the way `abandonedRuns` does, from a store that knows nothing about it.
        let files = try FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: nil)
          .filter { $0.pathExtension == "json" }
        XCTAssertEqual(files.count, 1)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RunMarker.self, from: try Data(contentsOf: files[0]))

        XCTAssertEqual(decoded.client, "star")
        XCTAssertEqual(decoded.sequenceName, "seq")
        XCTAssertEqual(decoded.sequencePath, "/some/path")
        XCTAssertEqual(decoded.logPath, "/some/log.txt")
        XCTAssertEqual(decoded.frameCount, 100)
        XCTAssertEqual(decoded.imageWidth, 1920)
        XCTAssertEqual(decoded.imageHeight, 1080)
        XCTAssertEqual(decoded.imageBytesPerPixel, 6)
        XCTAssertEqual(decoded.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(decoded.formatVersion, RunMarker.currentFormatVersion)

        await store.finish()
    }
}
