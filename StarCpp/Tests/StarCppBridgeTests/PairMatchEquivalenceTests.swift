import XCTest
@testable import StarCppBridge

/// The descriptor matching of the alignment ops must return what OpenCV's BFMatcher returns.
///
/// Every frame is matched against the ones around it, which on a moving sequence matches each
/// pair twice — A's op asks for B's descriptors against A's, B's op for A's against B's.
/// `PairMatch.hpp` computes the pair's distance matrix once, in the first op to ask, and keeps
/// the other direction for the second.  The result is only allowed to be the same: the two
/// directions are rows and columns of one matrix and OpenCV's distances are symmetric to the bit,
/// but "the two nearest, ties to the lower index, an infinite distance never chosen" is a rule
/// that has to be reproduced exactly, and what follows it — Lowe's ratio test, RANSAC, the
/// homography — would carry any difference into every frame.
///
/// `KernelHarness/match_bench` holds it to BFMatcher over millions of pairs; these are the
/// versions that run with the suite.
final class PairMatchEquivalenceTests: XCTestCase {

    override func tearDown() {
        ImageAligner.debugSetPairMatch(enabled: true)
        _ = ImageAligner.debugPairMatchWaiting(clear: true)
        super.tearDown()
    }

    /// Random descriptors of both kinds, with many equal distances, rows that are all equal, and
    /// squared sums that overflow to infinity, through `knn2` and its cache against BFMatcher
    /// in both directions.
    func testPairMatchingReturnsBFMatchersResults() {
        XCTAssertEqual(ImageAligner.debugPairMatchSelfTest(trials: 400, seed: 7), 0)
        XCTAssertEqual(ImageAligner.debugPairMatchSelfTest(trials: 400, seed: 20261030), 0)
    }

    // MARK: - a pair of frames, aligned both ways

    private let width = 1200
    private let height = 800

    private struct Star { let x, y, sigma, peak: Double }

    /// A few hundred stars of mixed brightness, the same field every time.
    private func stars() -> [Star] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        return (0..<600).map { _ in
            Star(x: next() * Double(width), y: next() * Double(height), sigma: 1.0 + 0.6 * next(),
                 peak: 1500 + 28000 * pow(next(), 3))
        }
    }

    /// The star field shifted by (dx, dy), on a sky with its own noise.
    private func frame(dx: Double, dy: Double, noiseSeed: UInt64) -> MatWrapper {
        var state = noiseSeed
        var pixels = [Double](repeating: 0, count: width * height)
        for i in 0..<pixels.count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            pixels[i] = 4000 + Double((state >> 33) % 400)
        }
        for s in stars() {
            let cx = s.x + dx, cy = s.y + dy
            let reach = Int((4 * s.sigma).rounded(.up))
            let y0 = max(0, Int(cy) - reach), y1 = min(height - 1, Int(cy) + reach)
            let x0 = max(0, Int(cx) - reach), x1 = min(width - 1, Int(cx) + reach)
            if y0 > y1 || x0 > x1 { continue }
            for y in y0...y1 {
                for x in x0...x1 {
                    let ddx = Double(x) - cx, ddy = Double(y) - cy
                    pixels[y * width + x] += s.peak * exp(-(ddx * ddx + ddy * ddy) / (2 * s.sigma * s.sigma))
                }
            }
        }
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: width * height)
        for i in 0..<(width * height) { data[i] = UInt16(clamping: Int(pixels[i].rounded())) }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 16, componentsPerPixel: 1),
                          bytesPerRow: width * MemoryLayout<UInt16>.size,
                          data: UnsafeMutableRawPointer(data), takeOwnership: true)
    }

    private func skySet(_ image: MatWrapper) throws -> OCVFeatureSet {
        try XCTUnwrap(ImageAligner.findFeatures(baseImage: image, frameIndex: 0,
                                                matchMethod: .knnLowes, mask: nil,
                                                alignmentType: .sky, maxKeypoints: 2000,
                                                writeDebugImages: false,
                                                groundHorizonExtension: 100,
                                                skyHorizonExtension: 0,
                                                baseImageDilateSize: 20,
                                                baseImageThresholdValue: 100))
    }

    private func homography(base: OCVFeatureSet, baseIndex: Int32, neighbor: OCVFeatureSet,
                            neighborIndex: Int32) throws -> [Double] {
        let result = try XCTUnwrap(
          ImageAligner.computeHomography(
            baseKeypoints: base, frameIndex: baseIndex,
            neighbors: [AlignmentNeighborInfo(filename: "neighbor", maskFilename: nil,
                                              keypoints: neighbor, frameIndex: neighborIndex)],
            matchMethod: .knnLowes, alignmentType: .sky, maxKeypoints: 2000,
            writeDebugImages: false,
            imageWidth: Int32(width), imageHeight: Int32(height),
            handler: { _, _, _, _ in }))
        let warp = try XCTUnwrap(result.warpInfo.first)
        return try XCTUnwrap(warp.homography?.homographyValues)
    }

    /// Frame A aligned against B, then B against A: with the pair sharing on, the second finds its
    /// match waiting; with it off, each is BFMatcher's own.  The homographies are the same
    /// numbers, in either order, and the cache is empty again afterwards.
    func testAlignmentsOfAPairBothWaysAreTheSameWithTheSharedMatch() throws {
        let a = try skySet(frame(dx: 0, dy: 0, noiseSeed: 11))
        let b = try skySet(frame(dx: 6, dy: 2, noiseSeed: 12))
        XCTAssertGreaterThan(a.keypointCount, 100)
        XCTAssertGreaterThan(b.keypointCount, 100)

        ImageAligner.debugSetPairMatch(enabled: false)
        let referenceAB = try homography(base: a, baseIndex: 0, neighbor: b, neighborIndex: 1)
        let referenceBA = try homography(base: b, baseIndex: 1, neighbor: a, neighborIndex: 0)

        ImageAligner.debugSetPairMatch(enabled: true)
        _ = ImageAligner.debugPairMatchWaiting(clear: true)
        let firstAB = try homography(base: a, baseIndex: 0, neighbor: b, neighborIndex: 1)
        XCTAssertEqual(ImageAligner.debugPairMatchWaiting(), 1, "the first op leaves the other direction waiting")
        let thenBA = try homography(base: b, baseIndex: 1, neighbor: a, neighborIndex: 0)
        XCTAssertEqual(ImageAligner.debugPairMatchWaiting(), 0, "the second takes it")
        XCTAssertEqual(firstAB, referenceAB)
        XCTAssertEqual(thenBA, referenceBA)

        // and the other order
        let firstBA = try homography(base: b, baseIndex: 1, neighbor: a, neighborIndex: 0)
        let thenAB = try homography(base: a, baseIndex: 0, neighbor: b, neighborIndex: 1)
        XCTAssertEqual(ImageAligner.debugPairMatchWaiting(), 0)
        XCTAssertEqual(firstBA, referenceBA)
        XCTAssertEqual(thenAB, referenceAB)
    }
}
