import XCTest
import StarCpp
@testable import StarCppBridge

/// WGPUOps_C.h's availability contract, which holds on every build and touches no GPU driver: the
/// backend is opt-in (STAR_WGPU), and a build without wgpu-native, or a process that did not opt in,
/// gets an answer of "not available" from every entry point instead of a device. This is what keeps
/// the CPU path in charge on a machine where nobody asked for wgpu, so unlike the rest of this target
/// it runs (never skips) whether or not wgpu/fetch.sh has put wgpu-native in place.
final class WGPUAvailabilityTests: XCTestCase {

    func testOptInNeedsTheBackendCompiledIn() {
        if !wgpu_ops_compiled_in() {
            XCTAssertFalse(wgpu_ops_opted_in(), "a build without wgpu-native cannot be opted in")
        }
    }

    func testWithoutTheBackendOrTheOptInNothingIsAvailable() throws {
        // With wgpu-native compiled in and STAR_WGPU set, the device tests (WGPUOpsTests) cover this.
        let backendInUse = wgpu_ops_compiled_in() && wgpu_ops_opted_in()
        try XCTSkipIf(backendInUse, "the wgpu backend is compiled in and opted in: WGPUOpsTests covers it")

        XCTAssertFalse(wgpu_ops_available())
        XCTAssertNil(wgpu_ops_device_description())
        XCTAssertFalse(wgpu_ops_aligned_merge_supported())
        XCTAssertFalse(wgpu_ops_median_merge_supported())
        var seconds = [Double](repeating: -1, count: 6)
        XCTAssertFalse(wgpu_ops_last_timing(&seconds), "nothing has run, so there is no timing")
        XCTAssertEqual(seconds, [Double](repeating: -1, count: 6), "a refused timing query writes nothing")
        wgpu_ops_trim_pool()   // must be a no-op that does not start a backend
        XCTAssertFalse(wgpu_ops_available(), "trimming the pool must not start the backend")
        XCTAssertFalse(wgpu_ops_register(), "without the opt-in no handler is registered")
    }
}
