import XCTest
import StarCore
@testable import star

/// The cli records `gpuMergeEnabled` in its run marker so that, after a run dies in a merge phase,
/// the next launch can tell whether a GPU merge was going on and turn GPU merge off. These tests
/// inject the environment and the GPU's presence, so they never touch the GPU or the process's own
/// `STAR_USE_GPU_FOR_MERGE` (and `useGPUForMerge` is set explicitly in every case).
final class CliRunMarkerGPUMergeTests: XCTestCase {

    private func config(useGPUForMerge: Bool) -> Config {
        var c = Config()
        c.useGPUForMerge = useGPUForMerge
        return c
    }

    func testRecordedOnlyWhenRequestedAndAGPUIsPresent() {
        XCTAssertTrue(runMarkerGPUMergeEnabled(config(useGPUForMerge: true),
                                               environment: [:], gpuAvailable: { true }))
        XCTAssertFalse(runMarkerGPUMergeEnabled(config(useGPUForMerge: true),
                                                environment: [:], gpuAvailable: { false }),
                       "no GPU: the merge runs on the CPU, so a crash is not a GPU merge crash")
        XCTAssertFalse(runMarkerGPUMergeEnabled(config(useGPUForMerge: false),
                                                environment: [:], gpuAvailable: { true }),
                       "GPU merge turned off in the config")
    }

    func testEnvironmentForcingCPUMergeIsRecordedAsOff() {
        for value in ["0", "false", "NO", "off"] {
            XCTAssertFalse(runMarkerGPUMergeEnabled(
                             config(useGPUForMerge: true),
                             environment: ["STAR_USE_GPU_FOR_MERGE": value],
                             gpuAvailable: { true }),
                           "STAR_USE_GPU_FOR_MERGE=\(value) forces the CPU merge")
        }
        XCTAssertTrue(runMarkerGPUMergeEnabled(config(useGPUForMerge: true),
                                               environment: ["STAR_USE_GPU_FOR_MERGE": "1"],
                                               gpuAvailable: { true }))
    }
}
