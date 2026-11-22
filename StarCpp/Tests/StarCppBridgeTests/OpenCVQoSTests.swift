import XCTest
import StarCpp

/// opencv/build.sh patches cv::parallel_for_'s GCD branch to DISPATCH_APPLY_AUTO. Without it
/// OpenCV's workers always run at default QoS and lowering star's QoS (Balanced / Light in
/// "Use of this Mac") cannot yield the CPU to other apps through OpenCV's own loops.
///
/// Measured when the patch was written (macOS 27, M5 Max): the premise is only half right.
/// Even *unpatched*, GCD's `dispatch_apply` on the global default queue ran the bodies at the
/// caller's QoS, so the two inherit tests below pass either way — they guard against a
/// regression, they do not prove the patch. What the patch does change is the width: with
/// `DISPATCH_APPLY_AUTO` a `.background` caller got 6 worker threads where the unpatched
/// queue spread the same work across all 18, so Light actually takes fewer cores.
/// `testLowQoSUsesFewerWorkersThanNormalQoS` is the one that fails without the patch.
///
/// That width test is only meaningful on Apple silicon, the only hardware the narrowing has
/// been measured on. On x86_64 (an iMac Pro, macOS 15.8) GCD gives `.background` the same
/// worker count as `.utility` (36 vs 36) even with the patch compiled in, so the test is
/// skipped there. The inheritance tests do not prove the patch, so on Intel nothing in this
/// file guards it; `testParallelForUsesMoreThanTheCallingThread` only makes sure the
/// inheritance tests are not passing because the loop never left the calling thread.
final class OpenCVQoSTests: XCTestCase {

    /// [user-interactive, user-initiated, default, utility, background, unspecified, threads]
    private func observe(at qos: QualityOfService) -> [Int32] {
        nonisolated(unsafe) var counts = [Int32](repeating: 0, count: 7)
        nonisolated(unsafe) var total: Int32 = 0
        let done = expectation(description: "probe")
        let thread = Thread {
            total = counts.withUnsafeMutableBufferPointer { star_debug_parallel_qos(256, $0.baseAddress) }
            done.fulfill()
        }
        thread.qualityOfService = qos
        thread.start()
        wait(for: [done], timeout: 60)
        XCTAssertEqual(total, 256, "every body must have run")
        return counts
    }

    func testLowQoSUsesFewerWorkersThanNormalQoS() throws {
        #if !os(macOS)
        throw XCTSkip("QoS classes are Apple-only")
        #elseif arch(x86_64)
        throw XCTSkip("GCD's width narrowing for DISPATCH_APPLY_AUTO was only measured on Apple "
                      + "silicon; on Intel it gives .background the same worker count as .utility, "
                      + "so this test cannot tell whether the OpenCV patch is present")
        #else
        guard ProcessInfo.processInfo.activeProcessorCount >= 8 else {
            throw XCTSkip("too few cores for the worker counts to differ")
        }
        let utility = observe(at: .utility)
        let background = observe(at: .background)
        XCTAssertLessThan(background[6], utility[6],
                          "a .background caller should get a narrower worker set than .utility "
                          + "(DISPATCH_APPLY_AUTO); equal means the OpenCV patch is missing: "
                          + "utility \(utility[6]) threads, background \(background[6])")
        #endif
    }

    /// The inheritance tests pass vacuously if `cv::parallel_for_` runs every stripe on the
    /// calling thread (an OpenCV built without its GCD backend, or with the parallel loop
    /// collapsed): the caller's own QoS is then all they see. This one runs on every Mac,
    /// Intel included, and checks the work really is spread over GCD workers.
    func testParallelForUsesMoreThanTheCallingThread() throws {
        #if !os(macOS)
        throw XCTSkip("QoS classes are Apple-only")
        #else
        guard ProcessInfo.processInfo.activeProcessorCount >= 2 else {
            throw XCTSkip("a single core cannot show more than one worker")
        }
        let c = observe(at: .utility)
        XCTAssertGreaterThan(c[6], 1,
                             "cv::parallel_for_ ran all 256 stripes on one thread, so the QoS "
                             + "inheritance tests prove nothing: \(c)")
        #endif
    }

    func testWorkersInheritAUtilityCaller() throws {
        #if !os(macOS)
        throw XCTSkip("QoS classes are Apple-only")
        #else
        let c = observe(at: .utility)
        XCTAssertEqual(c[0] + c[1] + c[2], 0,
                       "workers ran above .utility — the OpenCV GCD QoS patch is not in this build: \(c)")
        XCTAssertGreaterThan(c[3], 0, "\(c)")
        #endif
    }

    /// The other direction: a raised caller (Full in "Use of this Mac", the gui's foreground
    /// work) must not have its OpenCV loops dropped to a lower class, nor raised past it.
    /// Runs on every Mac, Intel included, unlike the width test.
    func testWorkersInheritAUserInitiatedCaller() throws {
        #if !os(macOS)
        throw XCTSkip("QoS classes are Apple-only")
        #else
        let c = observe(at: .userInitiated)
        XCTAssertEqual(c[0], 0,
                       "workers ran above .userInitiated: \(c)")
        XCTAssertEqual(c[3] + c[4], 0,
                       "workers of a .userInitiated caller ran at .utility or .background: \(c)")
        XCTAssertGreaterThan(c[1], 0, "\(c)")
        #endif
    }

    func testWorkersInheritABackgroundCaller() throws {
        #if !os(macOS)
        throw XCTSkip("QoS classes are Apple-only")
        #else
        let c = observe(at: .background)
        XCTAssertEqual(c[0] + c[1] + c[2] + c[3], 0,
                       "workers ran above .background — the OpenCV GCD QoS patch is not in this build: \(c)")
        XCTAssertGreaterThan(c[4], 0, "\(c)")
        #endif
    }
}
