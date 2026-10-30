import XCTest
@testable import StarCppBridge

/// The CPU median merge has two kernels, and they must return the same bytes.
///
/// The Welford kernel is the reference: eight pixel-channels at a time, each lane running the
/// recurrence that has always defined the sigma-clip threshold.  On x86-64 with AVX2 the merge
/// runs an exact-statistics kernel instead (see `MedianMerge.hpp`) — integer sums instead of
/// the recurrence, 16-bit sorting and counting, and a hand-back to the recurrence for any
/// pixel whose threshold lands within a hair of a sample.  It is seven times faster and has no
/// business changing a single sample of any output, so this holds one to the other over the
/// shapes where a difference would show: every source count the register kernel is
/// specialised for and the ones either side of it, one and three channels, widths that leave
/// a scalar tail, coverage holes, and data built to put the threshold exactly on a sample.
///
/// On a machine with no exact kernel (Apple silicon, Rosetta, anything without AVX2) both
/// settings run the reference and there is nothing to compare, so the test skips rather than
/// pass for the wrong reason.
final class MedianKernelEquivalenceTests: XCTestCase {

    override func tearDown() {
        ImageAligner.debugSetMedianKernel(forceReference: false)
        super.tearDown()
    }

    /// SplitMix64 — deterministic, so a failure names a case that can be reproduced.
    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    private func makeMat(width: Int, height: Int, channels: Int, bits: Int,
                         _ sample: (Int, Int, Int) -> Int) -> MatWrapper {
        let bytes = bits / 8
        let rowBytes = width * channels * bytes
        let data = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * height, alignment: 16)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<channels {
                    let v = min(max(sample(x, y, c), 0), (1 << bits) - 1)
                    let p = data.advanced(by: y * rowBytes + (x * channels + c) * bytes)
                    if bytes == 1 { p.storeBytes(of: UInt8(v), as: UInt8.self) }
                    else { p.storeBytes(of: UInt16(v), as: UInt16.self) }
                }
            }
        }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: Int32(bits),
                                                    componentsPerPixel: Int32(channels)),
                          bytesPerRow: rowBytes, data: data, takeOwnership: true)
    }

    private func bytes(of mat: MatWrapper) -> [UInt8] {
        let base = mat.dataPtr!
        return (0..<mat.rows).flatMap { y -> [UInt8] in
            let row = base.advanced(by: y * mat.step).assumingMemoryBound(to: UInt8.self)
            let rowBytes = mat.cols * mat.channels * (mat.bitsPerComponent / 8)
            return Array(UnsafeBufferPointer(start: row, count: rowBytes))
        }
    }

    /// Sample generators.  The structured ones are the point: two- and three-point
    /// distributions put `mean + k * sd` exactly on a sample (four values {0, 0, 2, 2} at
    /// k = 1 have a threshold of exactly 2), which is where a one-ulp difference between two
    /// ways of computing the statistics would pick another source's value.
    private func sample(mode: Int, maxValue: Int, x: Int, rng: inout Rng) -> Int {
        switch mode {
        case 0: return rng.below(maxValue + 1)                                   // full range
        case 1: return 1000 + rng.below(4)                                       // four values
        case 2: return rng.below(10) < 4 ? 0 : rng.below(maxValue + 1)           // zeros mixed in
        case 3: return rng.below(10) < 5 ? maxValue : rng.below(maxValue + 1)    // saturated
        case 4: return maxValue / 2 + rng.below(40) - 20                         // noise around mid
        case 5: return maxValue / 3 + 2 * rng.below(3) * (1 + rng.below(4))      // exact-tie prone
        case 6: return maxValue / 4 + rng.below(2) * 2 * (1 + (x / 7) % 5)       // balanced two-point
        default: return (x % 3 == 0) ? 7 : maxValue / 2                          // equal runs
        }
    }

    private func mergeBoth(sources: [MatWrapper], misses: MatWrapper?, k: Double,
                           includeAll: Bool) throws -> (reference: [UInt8], machine: [UInt8]) {
        ImageAligner.debugSetMedianKernel(forceReference: true)
        let reference = try XCTUnwrap(ImageAligner.debugMedianMerge(
            sources, misses: misses, outlierThreshold: k, includeAll: includeAll, useGPU: false))
        ImageAligner.debugSetMedianKernel(forceReference: false)
        let machine = try XCTUnwrap(ImageAligner.debugMedianMerge(
            sources, misses: misses, outlierThreshold: k, includeAll: includeAll, useGPU: false))
        return (bytes(of: reference), bytes(of: machine))
    }

    func testExactKernelReturnsTheReferenceKernelsBytes() throws {
        try XCTSkipUnless(ImageAligner.debugMedianKernelIsExact,
                          "no exact-statistics kernel on this machine; nothing to compare")

        var rng = Rng(state: 0x5EED_0001)
        let sourceCounts = [2, 3, 4, 5, 8, 9, 9, 9, 12, 16, 17, 17, 17, 18, 33]
        let thresholds = [0.0, 0.5, 1.0, 1.0, 1.2, 2.0, 2.0, 3.5, 100.0]
        var compared = 0

        for trial in 0..<400 {
            let n = sourceCounts[rng.below(sourceCounts.count)]
            let channels = rng.below(2) == 0 ? 1 : 3
            let bits = rng.below(5) == 0 ? 8 : 16
            let width = 1 + rng.below(90)
            let height = 2 + rng.below(3)
            let mode = rng.below(8)
            let k = thresholds[rng.below(thresholds.count)]
            let includeAll = rng.below(8) == 0
            let maxValue = bits == 8 ? 255 : 65535

            var sources: [MatWrapper] = []
            for _ in 0..<n {
                sources.append(makeMat(width: width, height: height, channels: channels,
                                       bits: bits) { x, _, _ in
                    self.sample(mode: mode, maxValue: maxValue, x: x, rng: &rng)
                })
            }

            // Coverage holes, the honest way: the first `miss` sources have no sample at a
            // pixel, and read zero there.
            var misses: MatWrapper?
            if rng.below(3) != 0 {
                var counts = [Int](repeating: 0, count: width * height)
                for i in counts.indices {
                    let r = rng.below(100)
                    counts[i] = r < 70 ? 0 : (r < 90 ? 1 + rng.below(3) : rng.below(n + 3))
                }
                misses = makeMat(width: width, height: height, channels: 1, bits: 8) { x, y, _ in
                    counts[y * width + x]
                }
                sources = (0..<n).map { i in
                    makeMat(width: width, height: height, channels: channels, bits: bits) { x, y, c in
                        if counts[y * width + x] > i { return 0 }
                        let p = sources[i].dataPtr!.advanced(
                            by: y * sources[i].step + (x * channels + c) * (bits / 8))
                        return bits == 8 ? Int(p.load(as: UInt8.self)) : Int(p.load(as: UInt16.self))
                    }
                }
            }

            let (reference, machine) = try mergeBoth(sources: sources, misses: misses, k: k,
                                                     includeAll: includeAll)
            XCTAssertEqual(reference, machine,
                           "trial \(trial): n=\(n) \(width)x\(height)x\(channels) \(bits)-bit " +
                           "mode=\(mode) k=\(k) includeAll=\(includeAll) holes=\(misses != nil)")
            compared += reference.count
        }
        XCTAssertGreaterThan(compared, 100_000)
    }

    /// The register kernel's own working shape — 9 and 17 sources of wide 16-bit rows with
    /// holes down the left edge — at a size that runs many blocks per row.
    func testWideRowsWithEdgeHolesMatchTheReferenceKernel() throws {
        try XCTSkipUnless(ImageAligner.debugMedianKernelIsExact,
                          "no exact-statistics kernel on this machine; nothing to compare")

        var rng = Rng(state: 0x5EED_0002)
        for n in [9, 17] {
            let width = 1000, height = 8, channels = 3
            let sources = (0..<n).map { i in
                makeMat(width: width, height: height, channels: channels, bits: 16) { x, _, _ in
                    // the first (x / 4) % 4 sources have no sample in the leftmost columns
                    (x < 40 && i < 1 + x % 3) ? 0 : 20000 + rng.below(300)
                }
            }
            let misses = makeMat(width: width, height: height, channels: 1, bits: 8) { x, _, _ in
                x < 40 ? 1 + x % 3 : 0
            }
            let (reference, machine) = try mergeBoth(sources: sources, misses: misses, k: 1.2,
                                                     includeAll: false)
            XCTAssertEqual(reference, machine, "n=\(n)")
        }
    }
}
