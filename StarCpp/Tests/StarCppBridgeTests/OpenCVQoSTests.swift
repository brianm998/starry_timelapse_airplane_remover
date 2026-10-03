import XCTest
import StarCpp

/// opencv/build.sh patches cv::parallel_for_'s GCD branch to DISPATCH_APPLY_AUTO. Without it
/// OpenCV's workers always run at default QoS and lowering star's QoS (Balanced / Light in
/// "Use of this Mac") cannot yield the CPU to other apps through OpenCV's own loops.
final class OpenCVQoSTests: XCTestCase {

    /// [user-interactive, user-initiated, default, utility, background, unspecified]
    private func observe(at qos: QualityOfService) -> [Int32] {
        nonisolated(unsafe) var counts = [Int32](repeating: 0, count: 6)
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
