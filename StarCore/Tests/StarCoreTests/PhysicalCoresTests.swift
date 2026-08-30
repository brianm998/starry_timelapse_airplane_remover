import XCTest
import StarCoreC
@testable import StarCore

/// How many frames star works on at once by default.
///
/// The count itself is the machine's, so there is no fixed number to assert — what is
/// checked here is the relationship to the logical count, which is what went wrong: the
/// default was `ProcessInfo.processorCount`, and on a hyperthreaded machine that is twice
/// the cores.  Every concurrent frame reserves a working frame's worth of RAM and the
/// memory gating is sized from this number, so counting the hyperthreads asked the budget
/// to cover twice the frames the machine could usefully work on.
final class PhysicalCoresTests: XCTestCase {

    private var logical: Int { ProcessInfo.processInfo.processorCount }

    func testThereIsAlwaysAtLeastOne() {
        XCTAssertGreaterThanOrEqual(PhysicalCores.count, 1)
    }

    /// The point of the whole exercise: never more concurrency than the machine admits to
    /// having, even if the OS says something strange.
    func testItNeverExceedsTheLogicalCount() {
        XCTAssertLessThanOrEqual(PhysicalCores.count, logical)
    }

    /// SMT at most doubles the threads per core on anything star runs on, so a physical
    /// count below half the logical one means the probe has miscounted rather than that the
    /// machine is unusual.
    func testItIsNotWildlyBelowTheLogicalCount() {
        XCTAssertGreaterThanOrEqual(PhysicalCores.count * 2, logical,
                                    "\(PhysicalCores.count) physical cores against "
                                    + "\(logical) logical is more than SMT can explain")
    }

    /// Computed once and reused; two reads that disagreed would mean two `Config`s built a
    /// second apart could disagree on how much of the machine to use.
    func testItIsStable() {
        XCTAssertEqual(PhysicalCores.count, PhysicalCores.count)
    }

    /// The C probe's own contract: a real answer, or 0 meaning "cannot tell".  Anything
    /// else and the fallback in `PhysicalCores` is reading garbage as a core count.
    func testTheProbeEitherAnswersOrSaysItCannot() {
        let probed = Int(star_physical_core_count())
        XCTAssertGreaterThanOrEqual(probed, 0)
        if probed > 0 {
            XCTAssertEqual(PhysicalCores.count, min(probed, logical))
        } else {
            XCTAssertEqual(PhysicalCores.count, logical)
        }
    }

    /// Where this actually lands.  A `Config` nobody has configured is what a new sequence
    /// starts from, in every client.
    func testAFreshConfigDefaultsToIt() {
        XCTAssertEqual(Config().numberOfFramesToProcessConcurrently, PhysicalCores.count)
    }
}
