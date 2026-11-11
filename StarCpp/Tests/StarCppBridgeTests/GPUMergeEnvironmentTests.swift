import XCTest
import StarCppBridge

/// `STAR_USE_GPU_FOR_MERGE` forces the CPU median merge. The environment is injected as a
/// dictionary; the process's own is never touched, and no GPU path is run.
final class GPUMergeEnvironmentTests: XCTestCase {

    private let variable = "STAR_USE_GPU_FOR_MERGE"

    func testForcedOffValues() {
        for v in ["0", "false", "no", "off", "FALSE", "No", "OFF", " 0 "] {
            XCTAssertTrue(GPUCapability.mergeForcedOff(environment: [variable: v]), "\(v) forces the CPU")
        }
        XCTAssertFalse(GPUCapability.mergeForcedOff(environment: [:]), "unset")
        for v in ["", "1", "true", "TRUE", "yes", "on"] {
            XCTAssertFalse(GPUCapability.mergeForcedOff(environment: [variable: v]), "\(v) leaves it alone")
        }
    }

    func testEffectiveUseGPU() {
        let off = [variable: "0"]
        XCTAssertFalse(GPUCapability.effectiveUseGPU(true, environment: off), "a caller's true is overridden")
        XCTAssertFalse(GPUCapability.effectiveUseGPU(false, environment: off))
        XCTAssertTrue(GPUCapability.effectiveUseGPU(true, environment: [:]), "unset: unchanged")
        XCTAssertFalse(GPUCapability.effectiveUseGPU(false, environment: [:]))
        XCTAssertTrue(GPUCapability.effectiveUseGPU(true, environment: [variable: "1"]))
    }
}
