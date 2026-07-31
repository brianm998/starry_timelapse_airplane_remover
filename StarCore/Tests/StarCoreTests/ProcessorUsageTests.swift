import XCTest
@testable import StarCore

/// `ProcessorUsage` parses one line of `top` output and is what the task runner throttles on.  It
/// clamps every percentage into 0...100 on the way in, which is the part worth pinning: a reading
/// outside that range would make `withAdditional(cpus:)` produce nonsense and the throttle either
/// stall or run flat out.
final class ProcessorUsageTests: XCTestCase {

    /// The line `top` actually emits, which is what the parser was written against.
    private let realLine = "CPU usage: 3.44% user, 3.81% sys, 92.74% idle"

    // MARK: - parsing a real top line

    func testARealTopLineParses() throws {
        let usage = try XCTUnwrap(ProcessorUsage(from: realLine))
        XCTAssertEqual(usage.user, 3.44, accuracy: 1e-9)
        XCTAssertEqual(usage.sys, 3.81, accuracy: 1e-9)
        XCTAssertEqual(usage.idle, 92.74, accuracy: 1e-9)
    }

    /// The three percentages come from a running system, so they roughly sum to 100 — worth
    /// checking the fields are not transposed, which would otherwise look plausible.
    func testTheFieldsAreNotTransposed() throws {
        let usage = try XCTUnwrap(ProcessorUsage(from: "CPU usage: 10.0% user, 20.0% sys, 70.0% idle"))
        XCTAssertEqual(usage.user, 10, accuracy: 1e-9)
        XCTAssertEqual(usage.sys, 20, accuracy: 1e-9)
        XCTAssertEqual(usage.idle, 70, accuracy: 1e-9)
        XCTAssertEqual(usage.user + usage.sys + usage.idle, 100, accuracy: 1e-9)
    }

    func testIntegerPercentagesParse() throws {
        let usage = try XCTUnwrap(ProcessorUsage(from: "CPU usage: 0% user, 0% sys, 100% idle"))
        XCTAssertEqual(usage.user, 0)
        XCTAssertEqual(usage.sys, 0)
        XCTAssertEqual(usage.idle, 100)
    }

    func testAFullyBusyReadingParses() throws {
        let usage = try XCTUnwrap(ProcessorUsage(from: "CPU usage: 99.9% user, 0.1% sys, 0.0% idle"))
        XCTAssertEqual(usage.idle, 0, accuracy: 1e-9)
        XCTAssertEqual(usage.user, 99.9, accuracy: 1e-9)
    }

    /// A line whose numbers are not numbers returns nil rather than a zeroed reading, so the
    /// caller keeps the previous sample instead of believing the cpu went idle.
    func testALineWithUnparseableNumbersIsNil() {
        XCTAssertNil(ProcessorUsage(from: "CPU usage: xx% user, yy% sys, zz% idle"))
        XCTAssertNil(ProcessorUsage(from: "CPU usage: % user, % sys, % idle"))
    }

    // MARK: - malformed input returns nil rather than trapping

    /// The parser indexes `parts[1]`, `foobar[1]` and `foobar[2]`.  Those subscripts used to be
    /// unguarded, so a line without a colon — or with fewer than three comma separated fields
    /// after it — trapped instead of returning nil.  These could not be written before that was
    /// fixed: a Swift trap takes the whole test process down rather than failing one case.
    ///
    /// It mattered because a trap cannot be recovered from, and the `ObjC.catchException` wrapped
    /// around the caller catches ObjC exceptions, not Swift traps.  A change to `top`'s output on
    /// some future macOS would have taken star down instead of leaving it on the previous sample.
    func testALineWithNoColonIsNilRatherThanATrap() {
        XCTAssertNil(ProcessorUsage(from: "CPU usage 3.44% user, 3.81% sys, 92.74% idle"))
        XCTAssertNil(ProcessorUsage(from: ""))
        XCTAssertNil(ProcessorUsage(from: "nonsense"))
    }

    func testALineWithTooFewFieldsIsNilRatherThanATrap() {
        XCTAssertNil(ProcessorUsage(from: "CPU usage:"))
        XCTAssertNil(ProcessorUsage(from: "CPU usage: 3.44% user"))
        XCTAssertNil(ProcessorUsage(from: "CPU usage: 3.44% user, 3.81% sys"))
    }

    /// The shape the caller guarantees — a line starting "CPU usage:" — with the numbers missing.
    /// Structurally fine, so it reaches the number parse and fails there.
    func testAWellShapedLineWithNoNumbersIsNil() {
        XCTAssertNil(ProcessorUsage(from: "CPU usage: a, b, c"))
        XCTAssertNil(ProcessorUsage(from: "CPU usage: , , "))
    }

    /// Only the text after the *first* colon is read, so the percentages have to follow the first
    /// one.  A line with anything colon-bearing in front of "CPU usage:" — a timestamp, say — does
    /// not parse.  That is fine for the caller, which filters on `starts(with: "CPU usage:")`, and
    /// the point here is that it now declines rather than trapping.
    func testAColonBeforeTheUsageFieldsMeansTheLineDoesNotParse() {
        XCTAssertNil(ProcessorUsage(from: "12:34:56 CPU usage: 1.0% user, 2.0% sys, 97.0% idle"))
    }

    /// A colon *after* the fields is harmless, since only the first split matters.
    func testAColonAfterTheFieldsIsHarmless() throws {
        let usage = try XCTUnwrap(
          ProcessorUsage(from: "CPU usage: 1.0% user, 2.0% sys, 97.0% idle : extra"))
        XCTAssertEqual(usage.user, 1, accuracy: 1e-9)
    }

    /// A run of assorted junk, none of which may trap.
    func testNoMalformedLineTraps() {
        let junk = [
          "", ":", "::", ",", "%", "CPU usage:,", "CPU usage:,,", "CPU usage: ,,",
          "CPU usage: %,%,%", "CPU usage: 1%,2%", ": , ,", "CPU usage: 1% user,, 3% idle",
          "\n", "CPU usage: 🚩% user, 🚩% sys, 🚩% idle",
        ]
        for line in junk {
            // the assertion is simply that this returns at all
            _ = ProcessorUsage(from: line)
        }
    }

    /// Each field is read up to its `%`, so trailing text after the last one is ignored.
    func testTrailingTextAfterTheLastFieldIsIgnored() throws {
        let usage = try XCTUnwrap(
          ProcessorUsage(from: "CPU usage: 1.0% user, 2.0% sys, 97.0% idle and then some"))
        XCTAssertEqual(usage.idle, 97, accuracy: 1e-9)
    }

    // MARK: - clamping

    func testAnOutOfRangeReadingIsClampedIntoZeroToOneHundred() {
        let high = ProcessorUsage(user: 500, sys: 500, idle: 500)
        XCTAssertEqual(high.user, 100)
        XCTAssertEqual(high.sys, 100)
        XCTAssertEqual(high.idle, 100)

        let low = ProcessorUsage(user: -10, sys: -10, idle: -10)
        XCTAssertEqual(low.user, 0)
        XCTAssertEqual(low.sys, 0)
        XCTAssertEqual(low.idle, 0)
    }

    func testAnInRangeReadingIsLeftAlone() {
        let usage = ProcessorUsage(user: 12.5, sys: 7.25, idle: 80.25)
        XCTAssertEqual(usage.user, 12.5)
        XCTAssertEqual(usage.sys, 7.25)
        XCTAssertEqual(usage.idle, 80.25)
    }

    func testTheBoundsThemselvesAreKept() {
        let usage = ProcessorUsage(user: 0, sys: 100, idle: 0)
        XCTAssertEqual(usage.user, 0)
        XCTAssertEqual(usage.sys, 100)
    }

    func testTheBusyReadingIsFullyBusy() {
        let busy = ProcessorUsage.busy()
        XCTAssertEqual(busy.user, 100)
        XCTAssertEqual(busy.idle, 0, "a busy cpu has no idle time")
        XCTAssertEqual(busy.idlePercent, 0)
    }

    // MARK: - idlePercent guards against kernel thrash

    /// The guard that gives this type its purpose: when system time is high the kernel is
    /// thrashing, and the idle cores it reports cannot actually accept work.  Reporting the raw
    /// idle figure there would add tasks and make the thrash worse.
    func testHighSystemTimeReportsNoIdleCapacityHoweverIdleTheCpuLooks() {
        let thrashing = ProcessorUsage(user: 10, sys: 50, idle: 40)
        XCTAssertEqual(thrashing.idle, 40, "the raw reading is unchanged")
        XCTAssertEqual(thrashing.idlePercent, 0,
                       "but no capacity is offered while the kernel is busy")
    }

    func testOrdinarySystemTimeReportsTheRealIdleFigure() {
        let calm = ProcessorUsage(user: 10, sys: 5, idle: 85)
        XCTAssertEqual(calm.idlePercent, 85)
    }

    /// The threshold is 20% system time, and it is exclusive.
    func testTheThrashThresholdIsTwentyPercentExclusive() {
        XCTAssertEqual(ProcessorUsage(user: 0, sys: 20, idle: 80).idlePercent, 80,
                       "exactly 20 is not yet thrashing")
        XCTAssertEqual(ProcessorUsage(user: 0, sys: 20.01, idle: 80).idlePercent, 0,
                       "just past 20 is")
    }

    // MARK: - isDifferent

    func testAReadingIsNotDifferentFromItself() {
        let usage = ProcessorUsage(user: 30, sys: 10, idle: 60)
        XCTAssertFalse(usage.isDifferent(from: usage))
    }

    /// The default threshold is a 50 point swing on any one field, which is what makes the tracker
    /// re-sample rather than trust a stale reading.
    func testALargeSwingOnAnyFieldCountsAsDifferent() {
        let calm = ProcessorUsage(user: 5, sys: 5, idle: 90)

        XCTAssertTrue(calm.isDifferent(from: ProcessorUsage(user: 90, sys: 5, idle: 5)),
                      "user swung by 85")
        XCTAssertTrue(calm.isDifferent(from: ProcessorUsage(user: 5, sys: 90, idle: 5)),
                      "sys swung by 85")
        XCTAssertTrue(calm.isDifferent(from: ProcessorUsage(user: 5, sys: 5, idle: 20)),
                      "idle swung by 70")
    }

    func testASmallSwingIsNotDifferent() {
        let a = ProcessorUsage(user: 10, sys: 10, idle: 80)
        let b = ProcessorUsage(user: 20, sys: 15, idle: 65)
        XCTAssertFalse(a.isDifferent(from: b), "nothing moved by more than 50")
    }

    func testTheThresholdIsConfigurableAndExclusive() {
        let a = ProcessorUsage(user: 10, sys: 0, idle: 90)
        let b = ProcessorUsage(user: 30, sys: 0, idle: 70)

        XCTAssertFalse(a.isDifferent(from: b, by: 20), "a swing of exactly 20 is not more than 20")
        XCTAssertTrue(a.isDifferent(from: b, by: 19))
    }

    func testDifferenceIsSymmetric() {
        let a = ProcessorUsage(user: 5, sys: 5, idle: 90)
        let b = ProcessorUsage(user: 80, sys: 5, idle: 15)
        XCTAssertEqual(a.isDifferent(from: b), b.isDifferent(from: a))
    }

    // MARK: - withAdditional

    /// Used to pretend a cpu is busier than it measured, so the runner leaves headroom.  The shift
    /// is one core's worth expressed as a percentage of all cores.
    func testAddingCpusMovesUsageFromIdleToUser() {
        let calm = ProcessorUsage(user: 0, sys: 0, idle: 100)
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let loaded = calm.withAdditional(cpus: 1)

        XCTAssertEqual(loaded.user, 100 / cores, accuracy: 1e-9)
        XCTAssertEqual(loaded.idle, 100 - 100 / cores, accuracy: 1e-9)
        XCTAssertEqual(loaded.sys, 0, "system time is left alone")
    }

    func testAddingNoCpusChangesNothing() {
        let usage = ProcessorUsage(user: 20, sys: 10, idle: 70)
        let same = usage.withAdditional(cpus: 0)
        XCTAssertEqual(same.user, 20, accuracy: 1e-9)
        XCTAssertEqual(same.sys, 10, accuracy: 1e-9)
        XCTAssertEqual(same.idle, 70, accuracy: 1e-9)
    }

    /// The result goes back through the clamping initializer, so loading up far past capacity
    /// saturates rather than producing an impossible reading.
    func testAddingMoreCpusThanExistSaturatesRatherThanOverflowing() {
        let calm = ProcessorUsage(user: 0, sys: 0, idle: 100)
        let overloaded = calm.withAdditional(cpus: 1000)

        XCTAssertEqual(overloaded.user, 100, "user saturates at 100")
        XCTAssertEqual(overloaded.idle, 0, "idle floors at 0")
    }

    func testAddingCpusIsMonotonic() {
        let calm = ProcessorUsage(user: 0, sys: 0, idle: 100)
        var previousIdle = 100.0
        for cpus in [0.0, 0.5, 1.0, 2.0, 4.0] {
            let loaded = calm.withAdditional(cpus: cpus)
            XCTAssertLessThanOrEqual(loaded.idle, previousIdle,
                                     "idle should not rise as cpus are added")
            previousIdle = loaded.idle
        }
    }

    // MARK: - the observation timestamp

    func testEachReadingIsStampedWithRoughlyNow() {
        let before = Date().timeIntervalSince1970
        let usage = ProcessorUsage(user: 1, sys: 1, idle: 98)
        let after = Date().timeIntervalSince1970

        XCTAssertGreaterThanOrEqual(usage.date, before)
        XCTAssertLessThanOrEqual(usage.date, after)
    }
}
