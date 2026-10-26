import XCTest
@testable import StarCppBridge

/// The sky homography refined against star centroids.
///
/// SIFT matches stars badly: they all look alike, so their descriptors collide and
/// Lowe's ratio test throws most of them away. In twilight that left 7-18 RANSAC inliers
/// per pair and fits up to 32px wrong, while the same frames held thousands of stars that
/// match by position alone. These render the extreme of that — every star identical — and
/// require the fit to come from the stars.
final class SkyStarRefinementTests: XCTestCase {

    private let width = 900
    private let height = 700

    private struct Star { let x, y: Double }

    private func stars() -> [Star] {
        var rand = Rand(seed: 31)
        return (0..<600).map { _ in
            Star(x: 20 + rand.unit() * Double(width - 40), y: 20 + rand.unit() * Double(height - 40))
        }
    }

    /// The neighbour's motion: a few pixels of pan and a small rotation about the centre,
    /// the size of what four frames of a moving sequence do.
    private let shift = (x: 7.3, y: -3.6)
    private let rotation = 0.002

    private func moved(_ s: Star) -> (x: Double, y: Double) {
        let cx = Double(width) / 2, cy = Double(height) / 2
        let dx = s.x - cx, dy = s.y - cy
        return (x: cx + dx * cos(rotation) - dy * sin(rotation) + shift.x,
                y: cy + dx * sin(rotation) + dy * cos(rotation) + shift.y)
    }

    /// Identical faint stars on a flat twilight sky with sensor noise.
    private func frame(_ positions: [(x: Double, y: Double)], noiseSeed: UInt64) -> MatWrapper {
        var rand = Rand(seed: noiseSeed)
        var pixels = (0..<(width * height)).map { _ in 9000 + Double(rand.next(600)) }
        for p in positions {
            for y in max(0, Int(p.y) - 6)...min(height - 1, Int(p.y) + 6) {
                for x in max(0, Int(p.x) - 6)...min(width - 1, Int(p.x) + 6) {
                    let dx = Double(x) - p.x, dy = Double(y) - p.y
                    pixels[y * width + x] += 2500 * exp(-(dx * dx + dy * dy) / (2 * 1.3 * 1.3))
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

    private func skyFeatures(_ image: MatWrapper) throws -> OCVFeatureSet {
        try XCTUnwrap(ImageAligner.findFeatures(baseImage: image, frameIndex: 0,
                                                matchMethod: .knnLowes, mask: nil,
                                                alignmentType: .sky, maxKeypoints: 2000,
                                                writeDebugImages: false,
                                                groundHorizonExtension: 100,
                                                skyHorizonExtension: 40,
                                                baseImageDilateSize: 20,
                                                baseImageThresholdValue: 100))
    }

    func testTheSkyKeepsItsStarCentroids() throws {
        let features = try skyFeatures(frame(stars().map { (x: $0.x, y: $0.y) }, noiseSeed: 1))
        XCTAssertGreaterThan(features.starCount, 500, "most of the 600 stars have to be found")
    }

    /// The stars are cached with the keypoints, so a resumed run refines from them too.
    func testStarsSurviveTheFeatureFile() throws {
        let features = try skyFeatures(frame(stars().map { (x: $0.x, y: $0.y) }, noiseSeed: 1))
        let path = NSTemporaryDirectory() + "SkyStarRefinementTests-\(UUID().uuidString).yaml"
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(features.write(toFilename: path))
        let loaded = try XCTUnwrap(OCVFeatureSet.load(fromFilename: path))
        XCTAssertEqual(loaded.starCount, features.starCount)
        XCTAssertEqual(loaded.keypointCount, features.keypointCount)
    }

    /// Where the keypoints cannot say how the sky moved, the stars do — to a fraction of
    /// a pixel everywhere in the frame.
    func testIdenticalStarsAlignByTheirPositions() throws {
        let base = try skyFeatures(frame(stars().map { (x: $0.x, y: $0.y) }, noiseSeed: 1))
        let neighbor = try skyFeatures(frame(stars().map(moved), noiseSeed: 2))

        let result = try XCTUnwrap(
          ImageAligner.computeHomography(
            baseKeypoints: base, frameIndex: 0,
            neighbors: [AlignmentNeighborInfo(filename: "neighbor", maskFilename: nil,
                                              keypoints: neighbor, frameIndex: 1)],
            matchMethod: .knnLowes, alignmentType: .sky, maxKeypoints: 2000,
            writeDebugImages: false,
            imageWidth: Int32(width), imageHeight: Int32(height),
            handler: { _, _, _, _ in }))
        let warp = try XCTUnwrap(result.warpInfo.first)
        XCTAssertEqual(warp.alignmentState, .homographySuccess)
        let h = try XCTUnwrap(warp.homography?.homographyValues)

        // The warp maps the neighbour onto the base: a star the neighbour shows at
        // moved(s) belongs at s.
        var worst = 0.0
        for s in stars() {
            let p = moved(s)
            let w = h[6] * p.x + h[7] * p.y + h[8]
            let mx = (h[0] * p.x + h[1] * p.y + h[2]) / w
            let my = (h[3] * p.x + h[4] * p.y + h[5]) / w
            worst = max(worst, hypot(mx - s.x, my - s.y))
        }
        XCTAssertLessThan(worst, 0.1, "the sky warp misplaces stars by up to \(worst)px")
    }

    /// A keypoint fit the stars cannot confirm is not passed off as the sky's motion.
    ///
    /// The two frames' star fields are unrelated, so nothing in the stars agrees with any
    /// fit, but both carry the same dozen soft blobs at the same places — dust on the
    /// sensor — which SIFT matches readily, and its fit says the sky did not move. In
    /// deep twilight such thinly supported fits were 170-2400px wrong every time they
    /// were measured; kept, one of them made validation repair the frame's whole set.
    func testAThinKeypointFitTheStarsRefuseIsDropped() throws {
        var rand = Rand(seed: 77)
        func field(_ count: Int) -> [(x: Double, y: Double)] {
            (0..<count).map { _ in (x: 20 + rand.unit() * Double(width - 40),
                                    y: 20 + rand.unit() * Double(height - 40)) }
        }
        let dust = (0..<12).map { i in
            (x: 80 + Double(i % 4) * 230, y: 110 + Double(i / 4) * 230,
             sigma: 3.0 + Double(i % 3), peak: 1500 + 300 * Double(i % 5))
        }
        func frame(stars: [(x: Double, y: Double)], noiseSeed: UInt64) -> MatWrapper {
            var noise = Rand(seed: noiseSeed)
            var pixels = (0..<(width * height)).map { _ in 9000 + Double(noise.next(600)) }
            func blob(_ cx: Double, _ cy: Double, _ sigma: Double, _ peak: Double) {
                let reach = Int(4 * sigma)
                for y in max(0, Int(cy) - reach)...min(height - 1, Int(cy) + reach) {
                    for x in max(0, Int(cx) - reach)...min(width - 1, Int(cx) + reach) {
                        let dx = Double(x) - cx, dy = Double(y) - cy
                        pixels[y * width + x] += peak * exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
                    }
                }
            }
            for s in stars { blob(s.x, s.y, 1.3, 2500) }
            for d in dust { blob(d.x, d.y, d.sigma, d.peak); blob(d.x + 2.5 * d.sigma, d.y, d.sigma / 2, d.peak) }
            let data = UnsafeMutablePointer<UInt16>.allocate(capacity: width * height)
            for i in 0..<(width * height) { data[i] = UInt16(clamping: Int(pixels[i].rounded())) }
            return MatWrapper(width: width, height: height,
                              cvType: MatWrapper.cvType(forBitsPerComponent: 16, componentsPerPixel: 1),
                              bytesPerRow: width * MemoryLayout<UInt16>.size,
                              data: UnsafeMutableRawPointer(data), takeOwnership: true)
        }
        let base = try skyFeatures(frame(stars: field(1500), noiseSeed: 1))
        let neighbor = try skyFeatures(frame(stars: field(1500), noiseSeed: 2))
        XCTAssertGreaterThan(base.starCount, 1000, "precondition: a sky full of stars")
        XCTAssertGreaterThan(neighbor.starCount, 1000, "precondition: a sky full of stars")

        let result = try XCTUnwrap(
          ImageAligner.computeHomography(
            baseKeypoints: base, frameIndex: 0,
            neighbors: [AlignmentNeighborInfo(filename: "neighbor", maskFilename: nil,
                                              keypoints: neighbor, frameIndex: 1)],
            matchMethod: .knnLowes, alignmentType: .sky, maxKeypoints: 2000,
            writeDebugImages: false,
            imageWidth: Int32(width), imageHeight: Int32(height),
            handler: { _, _, _, _ in }))
        let warp = try XCTUnwrap(result.warpInfo.first)
        XCTAssertNil(warp.homography,
                     "a fit only the dust supports was reported as the sky's motion")
        XCTAssertNotEqual(warp.alignmentState, .homographySuccess)
    }

    private struct Rand {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next(_ bound: UInt32) -> UInt32 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt32(truncatingIfNeeded: state >> 33) % bound
        }
        mutating func unit() -> Double { Double(next(1 << 30)) / Double(1 << 30) }
    }
}
