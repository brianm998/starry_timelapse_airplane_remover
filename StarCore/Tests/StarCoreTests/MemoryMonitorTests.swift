import XCTest
@testable import StarCore

/// File scope rather than an instance property: the timeout helper below takes a @Sendable
/// closure, which cannot capture a non-Sendable XCTestCase.
private let mb: UInt64 = 1024 * 1024

/// File scope for the same reason as `mb` above: `withTimeout` takes a `@Sendable` closure,
/// and reaching these through `self` would capture the non-Sendable XCTestCase.
private let physical: UInt64 = UInt64(ProcessInfo.processInfo.physicalMemory)

/// A whole-percent fraction of physical memory, as bytes. The effective-budget assertions
/// are all relative, so they read the same on a 16GB laptop and a 128GB workstation.
private func portion(_ percent: UInt64) -> UInt64 { physical / 100 * percent }

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

    // MARK: - the effective budget
    //
    // Every assertion here is a fraction of the machine's own RAM rather than an absolute
    // size, because the budget is derived from `physicalMemory` and the suite has to give
    // the same answer on a 16GB laptop and a 128GB workstation.
    //
    // What this section is about: the monitor used to admit against
    // `physicalMemory x budgetFraction` alone, which is a statement about the machine
    // masquerading as a statement about the moment. On a 128GB machine that is 111GB, and
    // `Config.keypointConcurrency` will fill essentially all of it with keypoint ops alone
    // (14 x 7868MB at 32.7MP). A run did exactly that while Lightroom was exporting a 42MP
    // sequence, and the machine ran out of RAM and killed the user's window session.

    /// The point of the whole change: what star may reserve has to shrink when something
    /// else on the machine is holding memory, even though the structural budget has not
    /// moved an inch.
    func testAReservationThatFitsTheMachineButNotTheMomentIsHeldBack() async {
        let m = await monitor(footprint: portion(10), available: portion(10))
        await m.setSystemFloor(bytes: 0)
        await m.configure(budgetFraction: 0.8)

        // 30% of RAM: comfortably inside the 80% structural budget, but well past the 20%
        // (10% held + 10% spare) that is actually reachable right now.
        let granted = await withTimeout(seconds: 2) { await m.reserve(bytes: portion(30)) }
        XCTAssertFalse(granted,
                       "a reservation the machine cannot currently back must queue")
    }

    /// The control for the test above: same request, same structural budget, same footprint
    /// — only the machine's spare memory differs. If this failed the gate would simply be
    /// refusing everything.
    func testTheSameReservationIsAdmittedWhenTheMachineHasRoom() async {
        let m = await monitor(footprint: portion(10), available: portion(80))
        await m.setSystemFloor(bytes: 0)
        await m.configure(budgetFraction: 0.8)

        let granted = await withTimeout(seconds: 5) { await m.reserve(bytes: portion(30)) }
        XCTAssertTrue(granted, "with the machine free, the structural budget should bind")
    }

    /// The anti-starvation property: the budget is anchored on what star already holds, so
    /// it tracks the footprint up and cannot collapse below it. Both monitors below see the
    /// same machine — the same spare memory, the same floor, the same structural budget —
    /// and differ only in how much star is holding, so the different answers are entirely
    /// the anchor at work. "Keep what you have, finish what you are doing, start nothing
    /// new" is what makes the gate safe to make this strict: a run already underway is
    /// throttled, never stopped.
    ///
    /// Note the floor is a whisker under `available` rather than over it. Above it the
    /// separate low-system-memory brake in `realityBlock()` holds every admission on its
    /// own, which is correct but would tell us nothing about the budget.
    func testTheBudgetIsAnchoredOnWhatStarAlreadyHolds() async {
        let deep = await monitor(footprint: portion(50), available: portion(26))
        await deep.setSystemFloor(bytes: portion(25))
        await deep.configure(budgetFraction: 0.8)

        let admitted = await withTimeout(seconds: 5) { await deep.reserve(bytes: portion(45)) }
        XCTAssertTrue(admitted,
                      "work inside the existing footprint must still be admitted with the " +
                      "machine nearly full")

        let shallow = await monitor(footprint: portion(5), available: portion(26))
        await shallow.setSystemFloor(bytes: portion(25))
        await shallow.configure(budgetFraction: 0.8)

        let refused = await withTimeout(seconds: 2) { await shallow.reserve(bytes: portion(45)) }
        XCTAssertFalse(refused,
                       "the same request on the same machine must queue when star is not " +
                       "already holding the memory it implies")
    }

    /// Zero from either probe means the platform could not answer — see
    /// `star_available_system_memory()`, which returns 0 on unknown platforms and on a
    /// failed `host_statistics64`, and `star_process_footprint()`, which does the same.
    /// Reading that as "the machine is empty" would gate every reservation on a figure of
    /// zero and stall the pipeline everywhere the probes are unimplemented.
    ///
    /// The `(0, portion(10))` row is the one that would break without the `footprint > 0`
    /// guard: 0 + spare is a perfectly plausible-looking small budget, and it would refuse
    /// a request the machine has ample room for.
    func testAProbeThatCannotAnswerFallsBackToTheStructuralBudget() async {
        for (footprint, available) in [(UInt64(0), UInt64(0)),
                                       (portion(10), UInt64(0)),
                                       (UInt64(0), portion(10))] {
            let m = await monitor(footprint: footprint, available: available)
            // Small enough that the low-system-memory brake cannot fire and confuse the
            // result — this test is only about which budget the gate uses.
            await m.setSystemFloor(bytes: 1 * mb)
            await m.configure(budgetFraction: 0.8)

            let granted = await withTimeout(seconds: 5) { await m.reserve(bytes: portion(70)) }
            XCTAssertTrue(granted,
                          "footprint \(footprint) / available \(available) should fall back " +
                          "to the structural budget")
        }
    }

    /// The inversion this could easily have become. `reserve(bytes:)` admits an impossible
    /// request IMMEDIATELY and ungated, on the reasoning that queueing something that can
    /// never fit would just block until the timeout. That test has to stay against the
    /// structural budget: measured against the effective one, a perfectly ordinary 7.8GB
    /// keypoint op would be declared impossible and waved straight through at exactly the
    /// moment the machine had no room for it — the opposite of the intended behaviour.
    func testAnOversizedRequestIsMeasuredAgainstTheMachineNotTheMoment() async {
        let m = await monitor(footprint: portion(1), available: portion(2))
        await m.setSystemFloor(bytes: 0)
        await m.configure(budgetFraction: 0.8)

        // 10% of RAM is far past the ~3% currently reachable, and nowhere near the 80%
        // structural budget. It must queue, not be waved through as impossible.
        let ordinary = await withTimeout(seconds: 2) { await m.reserve(bytes: portion(10)) }
        XCTAssertFalse(ordinary,
                       "a request that merely does not fit right now must queue")
    }

    /// And the genuinely impossible request is still admitted ungated, with the shrunken
    /// budget in play — otherwise it would queue forever.
    func testATrulyImpossibleRequestIsStillAdmittedUngatedWhenTheBudgetIsNarrowed() async {
        let m = await monitor(footprint: portion(1), available: portion(2))
        await m.setSystemFloor(bytes: 0)
        await m.configure(budgetFraction: 0.5)

        let granted = await withTimeout(seconds: 5) { await m.reserve(bytes: physical) }
        XCTAssertTrue(granted, "an impossible reservation must be admitted rather than queued")
    }

    /// The invariant the whole section exists for, stated directly: however many ops pile
    /// up at the gate, what star is admitted to hold plus what everything else on the
    /// machine is holding has to leave the floor intact.
    ///
    /// The probe is a closed loop — `footprint` is what the admitted ops have allocated,
    /// and `available` is the machine minus that and minus another process — which is what
    /// makes this a bound rather than a fixture. Note what falls out of it: the effective
    /// budget is *constant* across the loop at `physical - other - floor`, because each op
    /// admitted moves the same bytes from `available` into `footprint`. That stability is
    /// the reason `footprint + spare` is the right shape and `available` alone is not.
    ///
    /// Before this existed the loop had no effect whatsoever: admissions were decided
    /// against `physical x budgetFraction`, the other process was invisible to the
    /// accounting, and star's own footprint never came near the figure it was measured
    /// against. Fourteen 7868MB keypoint ops went through on a 128GB machine that was also
    /// exporting a 42MP Lightroom sequence, which is 109% of the machine, and it died.
    func testWhatStarIsAdmittedToHoldLeavesTheMachineItsFloor() async {
        let other = portion(25)        // another application, invisible to the ledger
        let floor = portion(6)
        let opSize = portion(6)        // ~ one full-resolution keypoint op

        let allocated = Counter()
        let m = MemoryMonitor()
        await m.setRealityProbe(.init(
          processFootprint: { allocated.value },
          systemAvailable: { physical - other - min(allocated.value, physical - other) }))
        await m.setSystemFloor(bytes: floor)
        // A wait and a forced gap far longer than the test, so nothing here is the escape
        // hatch getting through — every admission below is one the gate meant to allow.
        await m.configure(budgetFraction: 0.85,
                          maxWaitTime: 3600,
                          forcedAdmissionInterval: 3600)

        var admitted = 0
        while admitted < 30 {
            guard await withTimeout(seconds: 2, { await m.reserve(bytes: opSize) }) else { break }
            admitted += 1
            allocated.add(opSize)      // the op it admitted now allocates what it reserved
        }

        let held = UInt64(admitted) * opSize
        XCTAssertLessThanOrEqual(held + other, physical - floor,
                                 "\(admitted) ops of 6% each, plus a 25% other process, " +
                                 "must not eat into the 6% floor")

        // The structural 85% budget on its own admits 14 ops of 6%, which with the other
        // process is 109% of the machine.  Fewer than that is the whole point.
        XCTAssertLessThan(admitted, 14,
                          "the structural budget alone would have admitted 14 — the " +
                          "effective budget has to admit fewer")

        // And not so few that the gate has simply stopped working: the machine really does
        // have room for most of these.
        XCTAssertGreaterThanOrEqual(admitted, 8,
                                    "throttling is the goal, starving is not")
    }

    /// A throttled run has to say why. Without this the only symptom of the machine being
    /// full is that everything gets slower — and the pre-existing low-memory warning fires
    /// only once available memory is under the floor, which a merely busy machine may never
    /// reach. So the user watching a run crawl gets told it is the other applications.
    func testHoldingAReservationForTheMachineRatherThanTheLedgerTellsTheUser() async {
        let m = await monitor(footprint: portion(10), available: portion(10))
        await m.setSystemFloor(bytes: 0)
        await m.configure(budgetFraction: 0.8)

        // Spawned and cancelled rather than run through `withTimeout`, which is an
        // instance method and cannot be reached from this `@Sendable` closure.
        let posted = await capturingWarnings(kind: .lowSystemMemory) {
            // Fits the 80% structural budget, does not fit the 20% actually reachable.
            let queued = Task { await m.reserve(bytes: portion(30)) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            queued.cancel()
        }

        XCTAssertEqual(posted.first?.kind, .lowSystemMemory)
        XCTAssertEqual(posted.first?.severity, .warning,
                       "a busy machine is a reason to wait, not to interrupt the user")
    }

    /// And it stays quiet when the ledger is what refused: that is star's own accounting
    /// doing its job, and telling the user to close applications would be wrong.
    func testHoldingAReservationForTheLedgerAloneSaysNothingAboutTheMachine() async {
        // Both probes zero, so the effective budget is the structural budget and only the
        // ledger can refuse.
        let m = await monitor(footprint: 0, available: 0)
        await m.configure(budgetFraction: 0.8)
        await m.reserve(bytes: portion(79))

        let posted = await capturingWarnings(kind: .lowSystemMemory, atLeast: 0) {
            let queued = Task { await m.reserve(bytes: portion(10)) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            queued.cancel()
        }
        XCTAssertTrue(posted.isEmpty,
                      "an over-full ledger is not a claim about the machine: \(posted)")
    }

    // MARK: - bounding the forced-admission ratchet
    //
    // Forcing used to be unconditional: one waiter per `forcedAdmissionInterval`, forever,
    // with no ceiling. The comment above it claimed this "keeps the overshoot to a single
    // operation", which is only true if ops complete — and when the machine is already
    // thrashing they do not. A real run ratcheted from 111GB to 151GB reserved, five 7.8GB
    // admissions in five minutes, the last two of them after the OS had started reporting
    // memory pressure. The two tests below are the two halves of that fix.

    /// At most one forced admission outstanding at a time. Since nothing but forcing can
    /// put the ledger over the structural budget, "the ledger is already over" is exactly
    /// "a forced admission has not been released yet".
    func testForcingStopsWhileAnEarlierForcedAdmissionIsStillOutstanding() async {
        // Both probes at zero so the effective budget falls back to the structural one and
        // this is a test of the forced ceiling alone.
        let m = await monitor(footprint: 0, available: 0)
        await m.configure(budgetFraction: 0.8, maxWaitTime: 0.5, forcedAdmissionInterval: 0)

        await m.reserve(bytes: portion(79))     // fills the ledger to just under budget

        let first = await withTimeout(seconds: 5) { await m.reserve(bytes: portion(10)) }
        XCTAssertTrue(first, "the deadlock escape hatch must still let one waiter through")

        let second = await withTimeout(seconds: 5) { await m.reserve(bytes: portion(10)) }
        XCTAssertFalse(second,
                       "a second forced admission is the unbounded ratchet that drove a " +
                       "real run 39GB past its budget")
    }

    /// Critical pressure is the last thing the OS says before jetsam, and the kill arrives
    /// as an uncatchable SIGKILL. Starting more heavy work here is how a run gets killed
    /// rather than merely delayed — a stall is recoverable and a SIGKILL is not. Two of the
    /// five forced admissions in the run that motivated this went through at warn or
    /// critical level.
    func testForcingIsWithheldEntirelyAtCriticalPressure() async {
        let m = await monitor(footprint: 0, available: 0)
        await m.configure(budgetFraction: 0.8, maxWaitTime: 0.5, forcedAdmissionInterval: 0)
        await m.pressureChanged(level: .critical)

        let granted = await withTimeout(seconds: 3) { await m.reserve(bytes: 1 * mb) }
        XCTAssertFalse(granted, "nothing may be forced through while jetsam is imminent")
    }

    /// The other half of that distinction, and the reason it is not simply "never force
    /// under pressure". Warn level is the system asking for memory back, which a machine
    /// working through a long sequence crosses into and out of routinely; refusing to force
    /// there would stall those runs indefinitely, which would be its own bug.
    func testForcingStillHappensAtWarnLevel() async {
        let m = await monitor(footprint: 0, available: 0)
        await m.configure(budgetFraction: 0.8, maxWaitTime: 0.5, forcedAdmissionInterval: 0)
        await m.pressureChanged(level: .warning)

        let granted = await withTimeout(seconds: 5) { await m.reserve(bytes: 1 * mb) }
        XCTAssertTrue(granted,
                      "warn level must delay a reservation, not strand it — see " +
                      "testWarnLevelPressureStillHoldsAdmissionsBack for the delay")
    }

    // MARK: - stats

    /// Both budgets belong in the log when they disagree, because "which one is binding" is
    /// the first question a stalled run raises.
    func testStatsReportsBothBudgetsWhenTheMomentIsNarrowerThanTheMachine() async {
        let m = await monitor(footprint: portion(10), available: portion(10))
        await m.setSystemFloor(bytes: 0)
        await m.configure(budgetFraction: 0.8)

        let stats = await m.stats()
        XCTAssertTrue(stats.contains("physical"),
                      "a narrowed budget should name the structural one too: \(stats)")
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
    /// `kind` is which warning to wait for and return. It defaults to `.memoryPressure`,
    /// which is what most of this suite is about; the effective-budget tests pass
    /// `.lowSystemMemory` instead.
    private func capturingWarnings(
      kind: StarWarning.Kind = .memoryPressure,
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
            if box.values.filter({ $0.kind == kind }).count >= expected,
               expected > 0
            {
                break
            }
        } while Date() < deadline && expected > 0
        if expected == 0 { try? await Task.sleep(nanoseconds: 300_000_000) }

        await StarWarnings.shared.set(handler: nil)
        await StarWarnings.shared.setMinimumInterval(30)
        await StarWarnings.shared.reset()

        return box.values.filter { $0.kind == kind }
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
/// A Sendable byte counter, so the reality probe in
/// `testWhatStarIsAdmittedToHoldLeavesTheMachineItsFloor` can report a footprint that grows
/// as the test admits ops.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: UInt64 = 0

    func add(_ bytes: UInt64) {
        lock.lock(); defer { lock.unlock() }
        storage += bytes
    }

    var value: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

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
