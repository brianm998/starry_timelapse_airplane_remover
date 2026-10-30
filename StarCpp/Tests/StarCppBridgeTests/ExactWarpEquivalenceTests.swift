import XCTest
@testable import StarCppBridge

/// The CPU warp the merge uses for 16-bit frames must return what `cv::warpPerspective` returns,
/// byte for byte, and the coverage plane the merge derives from its coordinates must be the one a
/// warp of a solid 8-bit probe draws.
///
/// `ExactWarp.hpp` reproduces OpenCV 4.12's coordinate generation, weight table, bilinear sum and
/// BORDER_TRANSPARENT rule so that a run of the merge returns the same bytes it always did — the
/// whole reason it is allowed to replace the call.  A C++ harness holds it to OpenCV over 90
/// million pixel-channels while it is being written; this keeps holding it to the OpenCV that is
/// in the tree, which is the one thing that can change under it: a new OpenCV is a new rule for
/// the partly covered edge, or a new rounding, and nothing else would notice.
///
/// On a machine without the exact warp (Apple silicon) both settings run OpenCV and there is
/// nothing to compare, so the tests skip.
final class ExactWarpEquivalenceTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ExactWarpEquivalenceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        ImageCache.setLoader { MatWrapper.load(fromFilename: $0) }
    }

    override func tearDownWithError() throws {
        ImageAligner.debugSetExactWarp(enabled: true)
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
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
        mutating func uniform(_ low: Double, _ high: Double) -> Double {
            low + (high - low) * Double(next() >> 11) / Double(1 << 53)
        }
    }

    private func makeMat(width: Int, height: Int, channels: Int,
                         _ sample: (Int, Int, Int) -> UInt16) -> MatWrapper {
        let rowBytes = width * channels * 2
        let data = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * height, alignment: 16)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<channels {
                    data.advanced(by: y * rowBytes + (x * channels + c) * 2)
                        .storeBytes(of: sample(x, y, c), as: UInt16.self)
                }
            }
        }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 16,
                                                    componentsPerPixel: Int32(channels)),
                          bytesPerRow: rowBytes, data: data, takeOwnership: true)
    }

    private func bytes(of mat: MatWrapper) -> [UInt8] {
        let base = mat.dataPtr!
        let rowBytes = mat.cols * mat.channels * (mat.bitsPerComponent / 8)
        return (0..<mat.rows).flatMap { y -> [UInt8] in
            let row = base.advanced(by: y * mat.step).assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: row, count: rowBytes))
        }
    }

    /// A homography of one of the kinds a merge meets, and the ones that stress the rule:
    /// whole and fractional shifts, the near-identity fits star stores, rotations, strong
    /// perspective, shifts that leave a partly covered frame, a mirror, and exact halves.
    private func homography(kind: Int, width: Int, height: Int, rng: inout Rng) -> MatWrapper {
        var h: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        switch kind {
        case 0: break
        case 1: h[2] = Double(rng.below(15) - 7); h[5] = Double(rng.below(15) - 7)
        case 2: h[2] = rng.uniform(-9, 9); h[5] = rng.uniform(-9, 9)
        case 3:
            h = [1 + rng.uniform(-2e-4, 2e-4), rng.uniform(-3e-4, 3e-4), rng.uniform(-12, 12),
                 rng.uniform(-3e-4, 3e-4), 1 + rng.uniform(-2e-4, 2e-4), rng.uniform(-12, 12),
                 rng.uniform(-1e-8, 1e-8), rng.uniform(-1e-8, 1e-8), 1]
        case 4:
            let a = rng.uniform(-0.05, 0.05), s = 1 + rng.uniform(-0.05, 0.05)
            let cx = Double(width) / 2, cy = Double(height) / 2
            h = [s * cos(a), -s * sin(a), 0, s * sin(a), s * cos(a), 0, 0, 0, 1]
            h[2] = cx - (h[0] * cx + h[1] * cy) + rng.uniform(-4, 4)
            h[5] = cy - (h[3] * cx + h[4] * cy) + rng.uniform(-4, 4)
        case 5:
            h = [1 + rng.uniform(-0.2, 0.2), rng.uniform(-0.1, 0.1), rng.uniform(-20, 20),
                 rng.uniform(-0.1, 0.1), 1 + rng.uniform(-0.2, 0.2), rng.uniform(-20, 20),
                 rng.uniform(-2e-3, 2e-3), rng.uniform(-2e-3, 2e-3), 1]
        case 6: h[2] = rng.uniform(-0.6, 0.6) * Double(width); h[5] = rng.uniform(-0.6, 0.6) * Double(height)
        case 7: h[0] = -1; h[2] = Double(width - 1) + rng.uniform(-1, 1)
        case 8: h[2] = 0.5; h[5] = 0.5
        default: h[2] = 0.03125 * Double(rng.below(81) - 40); h[5] = 0.03125 * Double(rng.below(81) - 40)
        }
        return MatWrapper(homographyValues: h)
    }

    func testTheExactWarpReturnsOpenCVsBytes() throws {
        try XCTSkipUnless(ImageAligner.debugExactWarpIsAvailable,
                          "no exact warp on this machine; nothing to compare")

        var rng = Rng(state: 0x5EED_0A01)
        let sizes = [(1, 1), (3, 7), (16, 1), (17, 9), (63, 15), (64, 16), (65, 17), (100, 33),
                     (257, 129), (513, 31), (1200, 40)]
        var compared = 0
        for trial in 0..<150 {
            let (width, height) = sizes[rng.below(sizes.count)]
            let channels = rng.below(2) == 0 ? 1 : 3
            let fill = rng.below(3)
            let source = makeMat(width: width, height: height, channels: channels) { x, y, c in
                switch fill {
                case 0:
                    return UInt16(truncatingIfNeeded: rng.next())
                case 1:
                    let ramp: Int = 1000 + (x * 7 + y * 13 + c) % 30
                    return UInt16(ramp)
                default:
                    let coin: Int = rng.below(2)
                    return coin == 0 ? 65535 : 0
                }
            }
            let h = homography(kind: rng.below(10), width: width, height: height, rng: &rng)

            ImageAligner.debugSetExactWarp(enabled: false)
            let reference = try XCTUnwrap(ImageAligner.debugWarp(source, homography: h, useGPU: false))
            ImageAligner.debugSetExactWarp(enabled: true)
            let exact = try XCTUnwrap(ImageAligner.debugWarp(source, homography: h, useGPU: false))
            XCTAssertEqual(bytes(of: reference), bytes(of: exact),
                           "trial \(trial): \(width)x\(height)x\(channels) fill \(fill)")
            compared += width * height * channels
        }
        XCTAssertGreaterThan(compared, 100_000)
    }

    /// The merge's own use: each neighbour warped, and a plane of how many sources reached
    /// each pixel built from where the warps landed — here from the exact warp's own marks —
    /// then the sigma-clipped median over all of it.  Neighbours slid by fractions of a pixel
    /// in both directions leave uncovered edges on every side.
    func testAnAlignedMergeIsTheSameWithTheExactWarp() throws {
        try XCTSkipUnless(ImageAligner.debugExactWarpIsAvailable,
                          "no exact warp on this machine; nothing to compare")

        var rng = Rng(state: 0x5EED_0A02)
        for trial in 0..<12 {
            let width = 70 + rng.below(60), height = 20 + rng.below(30)
            let channels = trial % 2 == 0 ? 3 : 1
            let neighbourCount = 4 + rng.below(6)
            let base = makeMat(width: width, height: height, channels: channels) { x, y, c in
                let value: Int = 20000 + (x * 31 + y * 17 + c * 5) % 400
                return UInt16(value)
            }
            var infos: [AlignmentNeighborInfo] = []
            var homographies: [Int: MatWrapper] = [:]
            for k in 0..<neighbourCount {
                let source = makeMat(width: width, height: height, channels: channels) { x, y, c in
                    let value: Int = 20000 + (x * 31 + y * 17 + c * 5 + k * 3) % 400
                    return UInt16(value)
                }
                let path = scratch.appendingPathComponent("trial\(trial)-\(k).tiff").path
                XCTAssertTrue(source.write(to: path))
                infos.append(AlignmentNeighborInfo(filename: path, maskFilename: nil,
                                                   keypoints: nil, frameIndex: Int32(k + 1)))
                homographies[k + 1] = homography(kind: 2 + rng.below(4), width: width,
                                                 height: height, rng: &rng)
            }

            func merge(exact: Bool) throws -> [UInt8] {
                ImageAligner.debugSetExactWarp(enabled: exact)
                let result = try XCTUnwrap(ImageAligner.alignAndMedianMerge(
                    baseImage: base, baseFrameIndex: 0, neighbors: infos,
                    homography: homographies, outlierThreshold: 1.2, includeAll: false,
                    loadConcurrency: 1))
                XCTAssertEqual(result.warpCount, neighbourCount)
                return bytes(of: result.merged)
            }
            let reference = try merge(exact: false)
            let exact = try merge(exact: true)
            XCTAssertEqual(reference, exact,
                           "trial \(trial): \(width)x\(height)x\(channels), \(neighbourCount) neighbours")
        }
    }
}
