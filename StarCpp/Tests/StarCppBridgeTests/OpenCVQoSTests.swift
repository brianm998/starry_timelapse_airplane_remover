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
