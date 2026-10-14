import XCTest
import Darwin
@testable import StarCppBridge

/// Measures the peak memory of ONE real `ia_find_features` call, for sizing
/// `Config.keypointMemoryMultiplier` per detector path (sky/SIFT, earth/AKAZE; GPU port or
/// OpenCV) — the method the multiplier's own doc comment prescribes: one op per fresh
/// process, so nothing else's footprint is in the number.
///
/// Not a pass/fail test; it prints a `KPMEASURE` line. Skipped unless `STAR_KP_MEASURE=1`:
///
///     STAR_KP_MEASURE=1 STAR_KP_MP=33 STAR_KP_TYPE=sky STAR_KP_GPU=1 STAR_KP_DIVISOR=1.5 \
///       swift test -c release --filter KeypointFootprintMeasurement
///
/// `STAR_KP_MP` is 33 (7008x4672) or 42 (7952x5304);
/// `STAR_KP_TYPE` sky|earth; `STAR_KP_GPU` 0|1; `STAR_KP_DIVISOR` >= 1.
///
/// The reported multiple is (peak footprint - footprint before the frame existed) divided by
/// the 16-bit RGB frame's bytes, i.e. the same unit as `workingFrameBytes`.
final class KeypointFootprintMeasurement: XCTestCase {

    func testOneFindFeaturesCall() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["STAR_KP_MEASURE"] == "1", "set STAR_KP_MEASURE=1")
        try XCTSkipIf(_isDebugAssertConfiguration(), "run with 'swift test -c release'")

        let mp = Int(env["STAR_KP_MP"] ?? "33") ?? 33
        let (width, height) = mp >= 40 ? (7952, 5304) : (7008, 4672)
        let isEarth = (env["STAR_KP_TYPE"] ?? "sky") == "earth"
        let gpu = (env["STAR_KP_GPU"] ?? "0") == "1"
        let divisor = Double(env["STAR_KP_DIVISOR"] ?? "1") ?? 1
        let scale = divisor > 1 ? 1 / divisor : 1.0
        let channels = 3

        // The GPU backend is registered by StarCore's ImageCache.init in the app; a bare
        // test process has to do it itself, or `useGPUForSift` silently measures OpenCV.
        let gpuActive = gpu && GPUOps.registerIfAvailable()
        try XCTSkipIf(gpu && !gpuActive, "no GPU backend on this machine")

        let before = Self.physFootprint()
        let count = width * height * channels
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: count)
        nonisolated(unsafe) let pixels = data
        DispatchQueue.concurrentPerform(iterations: height) { y in
            var h = UInt32(truncatingIfNeeded: y) &* 2_654_435_761 &+ 12345
            let row = pixels.advanced(by: y * width * channels)
            for x in 0..<width {
                for c in 0..<channels {
                    h ^= h << 13; h ^= h >> 17; h ^= h << 5
                    let sky = 6000 + (x * 7 + y * 5) % 3000 + c * 500
                    row[x * channels + c] = (x * 31 + y * 17) % 997 == 0
                        ? 50000 : UInt16(sky + Int(h % 600))
                }
            }
        }
        let frame = MatWrapper(width: width, height: height,
                               cvType: MatWrapper.cvType(forBitsPerComponent: 16,
                                                         componentsPerPixel: Int32(channels)),
                               bytesPerRow: width * channels * 2,
                               data: UnsafeMutableRawPointer(data), takeOwnership: true)
        // top 70% sky, bottom 30% earth: 255 = sky
        let maskData = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        for y in 0..<height {
            memset(maskData.advanced(by: y * width), y < height * 7 / 10 ? 255 : 0, width)
        }
        let mask = MatWrapper(width: width, height: height, cvType: 0 /* CV_8UC1 */,
                              bytesPerRow: width, data: UnsafeMutableRawPointer(maskData),
                              takeOwnership: true)

        let frameBytes = UInt64(width * height * channels * 2)
        let start = Self.physFootprint()

        final class Sampler: @unchecked Sendable {
            let lock = NSLock(); var running = true; var peak: UInt64 = 0
        }
        let sampler = Sampler()
        let thread = Thread {
            while sampler.lock.withLock({ sampler.running }) {
                let now = KeypointFootprintMeasurement.physFootprint()
                sampler.lock.withLock { sampler.peak = max(sampler.peak, now) }
                usleep(2000)
            }
        }
        thread.start()
        let t0 = Date()
        let features = ImageAligner.findFeatures(
          baseImage: frame, frameIndex: 0, matchMethod: .knnLowes, mask: mask,
          alignmentType: isEarth ? .earth : .sky,
          maxKeypoints: 2000, writeDebugImages: false,
          groundHorizonExtension: 100, skyHorizonExtension: 40,
          baseImageDilateSize: 20, baseImageThresholdValue: 100,
          detectionScale: scale, useGPUForSift: gpu, useGPUForAKAZE: gpu)
        let seconds = Date().timeIntervalSince(t0)
        sampler.lock.withLock { sampler.running = false }
        while !thread.isFinished { usleep(500) }
        let peak = sampler.lock.withLock { sampler.peak }

        let wholeOp = Double(peak &- before) / Double(frameBytes)
        let detectorOnly = Double(peak &- start) / Double(frameBytes)
        print(String(format: "KPMEASURE %dMP %@ gpu=%d divisor=%.1f: %.2fs keypoints=%d frame=%.0fMB "
                     + "whole-op peak +%.0fMB = %.1fx, detector alone +%.0fMB = %.1fx",
                     mp, isEarth ? "earth" : "sky", gpu ? 1 : 0, divisor, seconds,
                     features?.keypointCount ?? -1, Double(frameBytes) / 1_048_576,
                     Double(peak &- before) / 1_048_576, wholeOp,
                     Double(peak &- start) / 1_048_576, detectorOnly))
        XCTAssertNotNil(features)
    }

    private static func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
