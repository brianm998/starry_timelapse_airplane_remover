import XCTest
@testable import StarCore

/// File scope rather than an instance property: the timeout helper below takes a @Sendable
/// closure, which cannot capture a non-Sendable XCTestCase.
private let mb: UInt64 = 1024 * 1024

/// `MemoryMonitor` is the admission gate every heavy operation passes through: it keeps a
/// predictive ledger of what ops intend to allocate, and a "reality brake" that refuses once the
/// real process footprint has crossed the budget.  Getting it wrong either starves the pipeline
/// (nothing is ever admitted) or lets it overcommit and get killed.
///
/// It is testable because of `RealityProbe`, which is the injection point for both footprint and
/// available memory — nothing here depends on the machine's actual memory state except the budget,
/// which is a fraction of `physicalMemory` and so is only ever asserted on relatively.
final class MemoryMonitorTests: XCTestCase {

    /// A fresh monitor rather than `.shared`, so the tests cannot disturb each other or anything
    /// else in the process.
    private func monitor(footprint: UInt64 = 0,
                         available: UInt64 = 64 * 1024 * 1024 * 1024) async -> MemoryMonitor
    {
        let m = MemoryMonitor()
        await m.setRealityProbe(.init(processFootprint: { footprint },
                                     systemAvailable: { available }))
        return m
    }

    // MARK: - estimatedImageBytes

    /// The estimate every op's reservation is derived from.  A wrong factor here mis-sizes every
    /// reservation in the run at once.
    func testAnImageEstimateIsWidthTimesHeightTimesComponentsTimesBytes() {
        XCTAssertEqual(MemoryMonitor.estimatedImageBytes(width: 100, height: 200,
                                                         componentsPerPixel: 3,
                                                         bytesPerComponent: 2),
                       100 * 200 * 3 * 2)
        XCTAssertEqual(MemoryMonitor.estimatedImageBytes(width: 1, height: 1,
                                                         componentsPerPixel: 1,
                                                         bytesPerComponent: 1),
                       1)
    }

    /// The defaults describe star's normal input: 3 components at 16 bits.
    func testTheDefaultsAreThreeComponentsAtTwoBytes() {
        XCTAssertEqual(MemoryMonitor.estimatedImageBytes(width: 10, height: 10),
                       10 * 10 * 3 * 2)
    }

    /// A 42 megapixel 16-bit RGB frame is the size the memory work in this codebase was measured
    /// against, so it is worth having the number written down.
    func testAFortyTwoMegapixelFrameIsAboutTwoHundredAndFortyMegabytes() {
        let bytes = MemoryMonitor.estimatedImageBytes(width: 7952, height: 5304)
        XCTAssertEqual(Double(bytes) / Double(mb), 241.3, accuracy: 0.5)
    }

    /// The arithmetic is done in `UInt64` throughout, so a frame far larger than `Int32` can hold
    /// must not overflow — a wrapped estimate would reserve almost nothing for a huge frame.
    func testAVeryLargeFrameDoesNotOverflow() {
        let bytes = MemoryMonitor.estimatedImageBytes(width: 100_000, height: 100_000,
                                                      componentsPerPixel: 4,
                                                      bytesPerComponent: 2)
        XCTAssertEqual(bytes, 100_000 * 100_000 * 4 * 2)
        XCTAssertGreaterThan(bytes, UInt64(Int32.max))
    }

    func testAZeroSizedImageEstimatesZero() {
        XCTAssertEqual(MemoryMonitor.estimatedImageBytes(width: 0, height: 100), 0)
        XCTAssertEqual(MemoryMonitor.estimatedImageBytes(width: 100, height: 0), 0)
    }

    func testTheEstimateScalesWithEveryFactor() {
        let base = MemoryMonitor.estimatedImageBytes(width: 100, height: 100)
        XCTAssertEqual(MemoryMonitor.estimatedImageBytes(width: 200, height: 100), base * 2)
        XCTAssertEqual(MemoryMonitor.estimatedImageBytes(width: 100, height: 200), base * 2)
        XCTAssertEqual(MemoryMonitor.estimatedImageBytes(width: 100, height: 100,
                                                         componentsPerPixel: 6), base * 2)
        XCTAssertEqual(MemoryMonitor.estimatedImageBytes(width: 100, height: 100,
                                                         bytesPerComponent: 4), base * 2)
    }

    // MARK: - the ledger

    /// A reservation that fits is granted immediately — if this ever blocked, the pipeline would
    /// stall with memory to spare.
    func testAReservationThatFitsIsGrantedWithoutWaiting() async {
        let m = await monitor()
        await m.reserve(bytes: 10 * mb)
        let stats = await m.stats()
        XCTAssertTrue(stats.contains("10"), "stats should report the reservation: \(stats)")
    }

    func testReservingNothingIsANoOp() async {
        let m = await monitor()
        await m.reserve(bytes: 0)
        await m.release(bytes: 0)
    }

    /// Release has to give the bytes back, or the ledger ratchets up until nothing is ever
    /// admitted again for the life of the process.
    func testReleaseReturnsTheBytesToTheLedger() async {
        let m = await monitor()
        await m.reserve(bytes: 100 * mb)
        let held = await m.stats()
        await m.release(bytes: 100 * mb)
        let freed = await m.stats()
        XCTAssertNotEqual(held, freed, "releasing should change the reported total")
    }

    /// Releasing more than was reserved clamps at zero rather than wrapping.  `reservedBytes` is
    /// `UInt64`, so an unclamped subtraction would underflow to something astronomical and block
    /// every future reservation permanently.
    func testReleasingMoreThanWasReservedClampsAtZeroRatherThanWrapping() async {
        let m = await monitor()
        await m.reserve(bytes: 10 * mb)
        await m.release(bytes: 999 * mb)

        // if it had wrapped, the ledger would be astronomically full and this would block
        // until the wait timeout rather than returning promptly
        let granted = await withTimeout(seconds: 5) { await m.reserve(bytes: 50 * mb) }
        XCTAssertTrue(granted, "a reservation after an over-release should still be admitted")
    }

    func testRepeatedOverReleaseStaysAtZero() async {
        let m = await monitor()
        for _ in 0..<5 { await m.release(bytes: 100 * mb) }
        let granted = await withTimeout(seconds: 5) { await m.reserve(bytes: 50 * mb) }
        XCTAssertTrue(granted)
    }

    /// A single request larger than the whole budget can never fit, so queueing it would block
    /// until the timeout no matter what else happens.  It is admitted ungated instead, which is
    /// what keeps the queue's patience safe for everyone else.
    func testASingleReservationBiggerThanTheBudgetIsAdmittedUngated() async {
        let m = await monitor()
        await m.configure(budgetFraction: 0.1)

        let physical = UInt64(ProcessInfo.processInfo.physicalMemory)
        let oversized = physical            // far past a 10% budget

        let granted = await withTimeout(seconds: 5) { await m.reserve(bytes: oversized) }
        XCTAssertTrue(granted, "an impossible reservation must be admitted rather than queued")
    }

    // MARK: - configure

    /// The fraction is clamped, because a value outside this range is either a no-op gate (1.0+)
    /// or a gate nothing can pass (0.0).
    func testTheBudgetFractionIsClampedToAUsableRange() async {
        let m = await monitor()

        await m.configure(budgetFraction: 5.0)
        let high = await m.stats()
        await m.configure(budgetFraction: 0.95)
        let atMax = await m.stats()
        XCTAssertEqual(high, atMax, "anything above 0.95 should clamp to 0.95")

        await m.configure(budgetFraction: -1)
        let low = await m.stats()
        await m.configure(budgetFraction: 0.1)
        let atMin = await m.stats()
        XCTAssertEqual(low, atMin, "anything below 0.1 should clamp to 0.1")
    }

    func testANegativeWaitTimeIsClampedToZero() async {
        let m = await monitor()
        await m.configure(budgetFraction: 0.85, maxWaitTime: -30)
        // a zero wait means a queued reservation gives up at once rather than never
        await m.setRealityProbe(.init(processFootprint: { UInt64.max / 2 },
                                     systemAvailable: { 0 }))
        let granted = await withTimeout(seconds: 10) { await m.reserve(bytes: 1 * mb) }
        XCTAssertTrue(granted, "with no wait time a blocked reservation should time out promptly")
    }

    func testConfiguringDoesNotDisturbAnExistingReservation() async {
        let m = await monitor()
        await m.reserve(bytes: 20 * mb)
        await m.configure(budgetFraction: 0.5)
        let stats = await m.stats()
        XCTAssertTrue(stats.contains("20"), "the reservation should survive reconfiguration: \(stats)")
    }

    // MARK: - the reality brake

    /// The brake is deliberately a brake and not a co-equal gate: it refuses only once the
    /// footprint has *already* crossed the budget, never on `footprint + needed`.  Process
    /// footprint does not drop promptly when memory is freed, so gating on the sum would starve
    /// admissions permanently after the first heavy frame.
    func testAFootprintWellUnderBudgetDoesNotBrake() async {
        let m = await monitor(footprint: 1 * mb)
        let granted = await withTimeout(seconds: 5) { await m.reserve(bytes: 100 * mb) }
        XCTAssertTrue(granted)
    }

    /// A footprint already past the budget holds the reservation back — but as a waiter, so the
    /// forced-admission escape hatch still applies and it cannot deadlock.
    func testAFootprintPastTheBudgetHoldsAReservationBackButDoesNotDeadlock() async {
        let m = await monitor(footprint: UInt64.max / 2)
        await m.configure(budgetFraction: 0.1, maxWaitTime: 1)

        let granted = await withTimeout(seconds: 20) { await m.reserve(bytes: 1 * mb) }
        XCTAssertTrue(granted,
                      "the brake must be escapable — a held reservation becomes a normal waiter")
    }

    /// The probe is only consulted through `reality`, so replacing it fully controls what the
    /// monitor believes about the machine.
    func testTheProbeIsWhatTheMonitorBelieves() async {
        let m = MemoryMonitor()
        await m.setRealityProbe(.init(processFootprint: { 12345 * (1024 * 1024) },
                                     systemAvailable: { 0 }))
        let stats = await m.stats()
        XCTAssertTrue(stats.contains("12345"),
                      "stats should report the injected footprint: \(stats)")
    }

    func testTheSystemFloorCanBeSet() async {
        let m = await monitor()
        await m.setSystemFloor(bytes: 1 * mb)
        // still able to reserve afterwards
        let granted = await withTimeout(seconds: 5) { await m.reserve(bytes: 10 * mb) }
        XCTAssertTrue(granted)
    }

    // MARK: - OS memory pressure

    /// The distinction this section exists for.  Darwin has two non-normal pressure levels and
    /// they mean different things: `warn` is the system asking every application to give memory
    /// back, which a machine working through a large sequence reaches and comes out of on its
    /// own, while `critical` is the last notice before jetsam starts killing processes.  Both
    /// used to arrive here as one Bool and be reported as `critical`, and `critical` is what
    /// every client puts in front of the user — which is how a run that finished normally
    /// stopped to show a modal saying the system might kill it.
    func testWarnLevelPressureIsReportedWithoutClaimingTheRunIsAboutToBeKilled() async {
        let m = await monitor(footprint: 500 * mb)
        let posted = await capturingWarnings { await m.pressureChanged(level: .warning) }

        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted.first?.kind, .memoryPressure)
        XCTAssertEqual(posted.first?.severity, .warning,
                       "warn-level pressure must not interrupt the user")
        XCTAssertTrue(posted.first?.message.contains("500") ?? false,
                      "the footprint belongs in the sentence: \(posted.first?.message ?? "")")
    }

    /// The other half: at `critical` the warning has to be loud, because on Darwin this is the
    /// last thing the system says before the kill arrives as an uncatchable SIGKILL.
    func testCriticalLevelPressureIsReportedAsCritical() async {
        let m = await monitor(footprint: 500 * mb)
        let posted = await capturingWarnings { await m.pressureChanged(level: .critical) }

        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted.first?.kind, .memoryPressure)
        XCTAssertEqual(posted.first?.severity, .critical)
    }

    /// Both levels carry the same `kind`, which is what `RunMarker.diagnosis` reads: a run
    /// killed after nothing worse than warn-level pressure is still diagnosed as a likely
    /// out-of-memory death rather than as an unexplained stop.
    func testBothLevelsReportTheSameKind() async {
        let m = await monitor()
        let posted = await capturingWarnings(atLeast: 2) {
            await m.pressureChanged(level: .warning)
            await m.pressureChanged(level: .critical)
        }
        XCTAssertEqual(posted.count, 2)
        XCTAssertEqual(posted.map(\.kind), [.memoryPressure, .memoryPressure])
        // A set: each warning is handed to the relay in its own task, so which of the two
        // arrives first is not something this can rely on.
        XCTAssertEqual(Set(posted.map(\.severity)), [.warning, .critical])
    }

    /// The source fires repeatedly at the level it is already at; only a change is news.
    func testTheSameLevelReportedTwiceIsOneWarning() async {
        let m = await monitor()
        let posted = await capturingWarnings(atLeast: 0) {
            await m.pressureChanged(level: .warning)
            await m.pressureChanged(level: .warning)
        }
        XCTAssertEqual(posted.count, 1)
    }

    /// Returning to normal says nothing to the user — there is nothing to say, and the run is
    /// about to speed up on its own.
    func testPressureClearingPostsNothing() async {
        let m = await monitor()
        // Through the capture too, so the warn-level post has landed and cannot be mistaken
        // for something the clear produced.
        _ = await capturingWarnings { await m.pressureChanged(level: .warning) }

        let posted = await capturingWarnings(atLeast: 0) {
            await m.pressureChanged(level: .normal)
        }
        XCTAssertTrue(posted.isEmpty)
    }

    /// Quieter reporting is not laxer gating.  Warn-level pressure still holds new heavy work
    /// back: declining to start more of it costs some throughput and undoes itself, which is
    /// exactly what interrupting the user does not.
    func testWarnLevelPressureStillHoldsAdmissionsBack() async {
        let m = await monitor()
        await m.configure(budgetFraction: 0.9, maxWaitTime: 60, forcedAdmissionInterval: 60)
        await m.pressureChanged(level: .warning)

        let granted = await withTimeout(seconds: 2) { await m.reserve(bytes: 1 * mb) }
        XCTAssertFalse(granted,
                       "the reality brake must hold at warn level, not only at critical")
    }

    /// And it lets go again when the system does.
    func testAdmissionsResumeOnceThePressureIsGone() async {
        let m = await monitor()
        await m.pressureChanged(level: .critical)
        await m.pressureChanged(level: .normal)

        let granted = await withTimeout(seconds: 5) { await m.reserve(bytes: 1 * mb) }
        XCTAssertTrue(granted)
    }

    /// The level names the reason a reservation is being held, so a log tells you which of the
    /// two conditions the machine is in.
    func testStatsNamesTheLevelItIsHoldingAt() async {
        let m = await monitor()
        await m.pressureChanged(level: .critical)
        let stats = await m.stats()
        XCTAssertTrue(stats.contains("critical"), "stats should name the level: \(stats)")
    }

    // MARK: - stats

    func testStatsIsNonEmptyAndMentionsTheBudget() async {
        let m = await monitor()
        let stats = await m.stats()
        XCTAssertFalse(stats.isEmpty)
        XCTAssertTrue(stats.lowercased().contains("budget") || stats.contains("MB"),
                      "stats should be readable: \(stats)")
    }

    // MARK: - helper

    /// Runs `work` with a handler installed on `StarWarnings.shared` and returns the
    /// memory-pressure warnings it delivered.
    ///
    /// The shared relay rather than a fresh one because that is where `MemoryMonitor` posts —
    /// the monitor under test can be a private instance, but the relay it reports to cannot
    /// be.  The dedup interval is dropped to zero for the duration so that two levels
    /// reported a millisecond apart are both seen, and everything is put back afterwards.
    ///
    /// `atLeast` is how many warnings to wait for: the monitor hands a warning off in a
    /// detached `Task` rather than awaiting the relay from its own admission path, so a post
    /// lands shortly *after* the call that caused it returns.
    private func capturingWarnings(
      atLeast expected: Int = 1,
      _ work: @escaping @Sendable () async -> Void
    ) async -> [StarWarning] {
        let box = Box()
        await StarWarnings.shared.setMinimumInterval(0)
        await StarWarnings.shared.set { box.append($0) }

        await work()

        let deadline = Date().addingTimeInterval(3)
        repeat {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if box.values.filter({ $0.kind == .memoryPressure }).count >= expected,
               expected > 0
            {
                break
            }
        } while Date() < deadline && expected > 0
        if expected == 0 { try? await Task.sleep(nanoseconds: 300_000_000) }

        await StarWarnings.shared.set(handler: nil)
        await StarWarnings.shared.setMinimumInterval(30)
        await StarWarnings.shared.reset()

        return box.values.filter { $0.kind == .memoryPressure }
    }

    /// Runs `work`, returning false if it did not finish within the timeout.  Used to assert that
    /// a reservation is *admitted* rather than queued, without hanging the suite if it is not.
    private func withTimeout(seconds: Double,
                             _ work: @escaping @Sendable () async -> Void) async -> Bool
    {
        let done = Flag()
        let worker = Task { await work(); await done.set() }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await done.value { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        worker.cancel()
        return await done.value
    }

    private actor Flag {
        var value = false
        func set() { value = true }
    }
}


/// Collects warnings from the relay's handler, which is `@Sendable` and called from whatever
/// context posted.
private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [StarWarning] = []

    func append(_ warning: StarWarning) {
        lock.lock(); defer { lock.unlock() }
        storage.append(warning)
    }

    var values: [StarWarning] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
