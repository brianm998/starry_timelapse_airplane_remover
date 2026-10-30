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

    /// A band of the merge — what the final composite asks of the earth merge, every row from the
    /// horizon down — is exactly those rows of the whole merge, and the rest of the frame the base
    /// frame's own.  Bands that start at the top, end at the bottom, are one row, or cover the
    /// frame; one and three channels; neighbours with perspective, shifts, rotations, a frame
    /// missing its homography, and the exact warp off (which merges the whole frame, so the
    /// rows asked for are still right).
    func testABandOfTheMergeIsTheRowsOfTheWholeMerge() throws {
        try XCTSkipUnless(ImageAligner.debugExactWarpIsAvailable,
                          "no exact warp on this machine; the band path is not taken")

        var rng = Rng(state: 0x5EED_0A03)
        for trial in 0..<10 {
            let width = 90 + rng.below(70), height = 40 + rng.below(40)
            let channels = trial % 2 == 0 ? 3 : 1
            let neighbourCount = 4 + rng.below(5)
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
                let path = scratch.appendingPathComponent("band\(trial)-\(k).tiff").path
                XCTAssertTrue(source.write(to: path))
                infos.append(AlignmentNeighborInfo(filename: path, maskFilename: nil,
                                                   keypoints: nil, frameIndex: Int32(k + 1)))
                // one neighbour in five has no homography at all
                if k % 5 != 4 {
                    homographies[k + 1] = homography(kind: 2 + rng.below(4), width: width,
                                                     height: height, rng: &rng)
                }
            }

            func merge(rows: Range<Int>?) throws -> (bytes: [UInt8], warps: Int) {
                let result = try XCTUnwrap(ImageAligner.alignAndMedianMerge(
                    baseImage: base, baseFrameIndex: 0, neighbors: infos,
                    homography: homographies, outlierThreshold: 1.2, includeAll: false,
                    loadConcurrency: 1, useGPU: false, rows: rows))
                return (bytes(of: result.merged), result.warpCount)
            }
            let whole = try merge(rows: nil)
            let baseBytes = bytes(of: base)
            let rowBytes = width * channels * 2

            let bands: [Range<Int>] = [0..<(height / 2), (height / 3)..<height, (height / 2)..<(height / 2 + 1),
                                       0..<height, 1..<(height - 1), (height - 1)..<height]
            for band in bands {
                let banded = try merge(rows: band)
                XCTAssertEqual(banded.warps, whole.warps, "trial \(trial) band \(band)")
                let inside = (band.lowerBound * rowBytes)..<(band.upperBound * rowBytes)
                XCTAssertEqual(Array(banded.bytes[inside]), Array(whole.bytes[inside]),
                               "trial \(trial) \(width)x\(height)x\(channels): the rows of band \(band)")
                if band.count < height {
                    let above = 0..<(band.lowerBound * rowBytes)
                    let below = (band.upperBound * rowBytes)..<(height * rowBytes)
                    XCTAssertEqual(Array(banded.bytes[above]), Array(baseBytes[above]),
                                   "trial \(trial): above band \(band) is the base frame")
                    XCTAssertEqual(Array(banded.bytes[below]), Array(baseBytes[below]),
                                   "trial \(trial): below band \(band) is the base frame")
                }
            }

            // exact warp off: the whole frame is merged, and the rows asked for are right
            ImageAligner.debugSetExactWarp(enabled: false)
            defer { ImageAligner.debugSetExactWarp(enabled: true) }
            let fallback = try merge(rows: (height / 3)..<height)
            let inside = ((height / 3) * rowBytes)..<(height * rowBytes)
            XCTAssertEqual(Array(fallback.bytes[inside]), Array(whole.bytes[inside]),
                           "trial \(trial): with the exact warp off")
        }
    }

    func testTheFirstRowBelowFindsTheFirstRowThatIsNotAll255() throws {
        func mask(width: Int, height: Int, _ value: (Int, Int) -> UInt8) -> MatWrapper {
            let data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
            for y in 0..<height { for x in 0..<width { data[y * width + x] = value(x, y) } }
            return MatWrapper(width: width, height: height,
                              cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 1),
                              bytesPerRow: width, data: UnsafeMutableRawPointer(data), takeOwnership: true)
        }
        // all 255: no row
        XCTAssertEqual(ImageAligner.firstRow(of: mask(width: 40, height: 30) { _, _ in 255 }, below: 255), 30)
        // one pixel at 254 in row 17, and a ramp below
        let ramped = mask(width: 40, height: 30) { x, y in
            if y == 17 && x == 23 { return 254 }
            return y > 20 ? 254 : 255
        }
        XCTAssertEqual(ImageAligner.firstRow(of: ramped, below: 255), 17)
        // the first row already holds a 0
        let leftEdge = mask(width: 40, height: 30) { x, _ in
            return x == 0 ? 0 : 255
        }
        XCTAssertEqual(ImageAligner.firstRow(of: leftEdge, below: 255), 0)
        // a mask that is not a plain 8-bit plane asks for every row
        let colour = MatWrapper(width: 8, height: 8,
                                cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 3),
                                bytesPerRow: 24,
                                data: UnsafeMutableRawPointer.allocate(byteCount: 192, alignment: 16),
                                takeOwnership: true)
        XCTAssertEqual(ImageAligner.firstRow(of: colour, below: 255), 0)
    }

    /// The same for the static camera's earth merge, a median of the base and its sources with no
    /// warping: the rows asked for are the whole merge's rows and the rest is the base's own — and
    /// sources of another size, or the GPU, are merged whole with the rows asked for still right.
    func testABandOfTheStaticMergeIsTheRowsOfTheWholeMerge() throws {
        var rng = Rng(state: 0x5EED_0A04)
        for trial in 0..<8 {
            let width = 80 + rng.below(60), height = 36 + rng.below(40)
            let channels = trial % 2 == 0 ? 3 : 1
            let count = 3 + rng.below(14)
            let base = makeMat(width: width, height: height, channels: channels) { x, y, c in
                let value: Int = 20000 + (x * 29 + y * 13 + c * 7) % 500
                return UInt16(value)
            }
            var filenames: [String] = []
            for k in 0..<count {
                let source = makeMat(width: width, height: height, channels: channels) { x, y, c in
                    let value: Int = 20000 + (x * 29 + y * 13 + c * 7 + k * 11) % 500
                    return UInt16(value)
                }
                let path = scratch.appendingPathComponent("static\(trial)-\(k).tiff").path
                XCTAssertTrue(source.write(to: path))
                filenames.append(path)
            }
            func merge(_ names: [String], rows: Range<Int>?, useGPU: Bool = false) throws -> [UInt8] {
                let result = try XCTUnwrap(ImageAligner.medianMergeImage(
                    base, withFilenames: names, outlierThreshold: 1.2, includeAll: false,
                    loadConcurrency: 1, useGPU: useGPU, rows: rows))
                return result.rows == 0 ? [] : bytes(of: result)     // a refused merge is an empty image
            }
            let whole = try merge(filenames, rows: nil)
            let baseBytes = bytes(of: base)
            let rowBytes = width * channels * 2
            for band in [0..<(height / 2), (height / 3)..<height, (height / 2)..<(height / 2 + 1), 0..<height] {
                let banded = try merge(filenames, rows: band)
                let inside = (band.lowerBound * rowBytes)..<(band.upperBound * rowBytes)
                XCTAssertEqual(Array(banded[inside]), Array(whole[inside]), "trial \(trial) band \(band)")
                if band.count < height {
                    let above = 0..<(band.lowerBound * rowBytes)
                    let below = (band.upperBound * rowBytes)..<(height * rowBytes)
                    XCTAssertEqual(Array(banded[above]), Array(baseBytes[above]), "trial \(trial) above \(band)")
                    XCTAssertEqual(Array(banded[below]), Array(baseBytes[below]), "trial \(trial) below \(band)")
                }
            }

            // a source of another size: the whole merge's answer (the geometry is not the band's to settle)
            let odd = makeMat(width: width + 3, height: height, channels: channels) { x, y, c in
                let value: Int = 20000 + (x + y + c) % 300
                return UInt16(value)
            }
            let oddPath = scratch.appendingPathComponent("static\(trial)-odd.tiff").path
            XCTAssertTrue(odd.write(to: oddPath))
            let mixed = filenames + [oddPath]
            let band = (height / 3)..<height
            let mixedWhole = try merge(mixed, rows: nil)
            let mixedBand = try merge(mixed, rows: band)
            XCTAssertEqual(mixedBand.isEmpty, mixedWhole.isEmpty,
                           "trial \(trial): a mismatched source is the whole merge's to refuse")
            if !mixedWhole.isEmpty && !mixedBand.isEmpty {
                let inside = (band.lowerBound * rowBytes)..<(band.upperBound * rowBytes)
                XCTAssertEqual(Array(mixedBand[inside]), Array(mixedWhole[inside]))
            }
        }
    }
}
