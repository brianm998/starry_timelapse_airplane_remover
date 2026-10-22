import XCTest
@testable import StarCppBridge

/// The sky detector against the edge its own masking creates.
///
/// `toGray8UWithMask` blacks out everything outside the sky mask, so the eroded horizon
/// becomes a hard step from lit sky to black. The step follows the horizon, so it moves
/// with the ground, not the stars — and under moonlight the sky just above the horizon
/// is the brightest sky there is, which makes the step the strongest structure SIFT sees.
/// On a moving moonlit 24MP sequence it held 23-28% of the sky keypoints and half the
/// descriptor matches, RANSAC's 10px tolerance let the ground-locked ones in, and the
/// fitted homography bent between the stars and the horizon: stars survived in one
/// corner of the merge and were erased everywhere else.
///
/// These render that situation small: a sky brightening towards a bumpy horizon, stars
/// that move one way between frames and a ground that moves another.
final class SkyHorizonCutTests: XCTestCase {

    private let width = 1200
    private let height = 800
    private let skyHorizonExtension: Int32 = 40

    /// The ridge line, bumpy enough that a cut following it has corners SIFT can match.
    private func horizon(_ x: Double) -> Double {
        560 + 14 * sin(x / 41) + 7 * sin(x / 13 + 1) + 4 * sin(x / 5.3 + 2)
    }

    private struct Star { let x, y, sigma, peak: Double }

    private func stars() -> [Star] {
        var rand = Rand(seed: 20261022)
        return (0..<500).map { _ in
            Star(x: rand.unit() * Double(width),
                 y: rand.unit() * 520,
                 sigma: 1.0 + 0.6 * rand.unit(),
                 // mostly faint, a few bright, as star counts go
                 peak: 1500 + 28000 * pow(rand.unit(), 3))
        }
    }

    /// One 16-bit frame: stars displaced by `star`, horizon and ground by `ground`.
    private func frame(star: (x: Double, y: Double),
                       ground: (x: Double, y: Double)) -> MatWrapper {
        // each frame its own sensor noise; a shared pattern would vote for no motion
        var rand = Rand(seed: 7 &+ UInt64(star.x * 1000 + ground.x * 10))
        var pixels = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let h = horizon(Double(x) - ground.x) + ground.y
                if Double(y) < h {
                    // moonlit sky: dark overhead, bright just above the horizon
                    let t = Double(y) / h
                    pixels[y * width + x] = 3000 + 40000 * t * t * t + Double(rand.next(400))
                } else {
                    pixels[y * width + x] = 600 + Double(rand.next(900))  // textured ground
                }
            }
        }
        for s in stars() {
            let cx = s.x + star.x, cy = s.y + star.y
            let reach = Int((4 * s.sigma).rounded(.up))
            for y in max(0, Int(cy) - reach)...min(height - 1, Int(cy) + reach) {
                for x in max(0, Int(cx) - reach)...min(width - 1, Int(cx) + reach) {
                    let dx = Double(x) - cx, dy = Double(y) - cy
                    pixels[y * width + x] += s.peak * exp(-(dx * dx + dy * dy) / (2 * s.sigma * s.sigma))
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

    /// The horizon mask star stores: sky white, ground black.
    private func mask(ground: (x: Double, y: Double)) -> MatWrapper {
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        for y in 0..<height {
            for x in 0..<width {
                data[y * width + x] = Double(y) < horizon(Double(x) - ground.x) + ground.y ? 255 : 0
            }
        }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 1),
                          bytesPerRow: width, data: UnsafeMutableRawPointer(data), takeOwnership: true)
    }

    private func skyFeatures(_ image: MatWrapper, _ mask: MatWrapper) throws -> OCVFeatureSet {
        try XCTUnwrap(ImageAligner.findFeatures(baseImage: image, frameIndex: 0,
                                                matchMethod: .knnLowes, mask: mask,
                                                alignmentType: .sky, maxKeypoints: 2000,
                                                writeDebugImages: false,
                                                groundHorizonExtension: 100,
                                                skyHorizonExtension: skyHorizonExtension,
                                                baseImageDilateSize: 20,
                                                baseImageThresholdValue: 100))
    }

    /// No sky keypoint is allowed near the cut: past the erosion, a further
    /// `skyKeypointCutMargin` (40 detection pixels) has to separate it from the black.
    func testSkyKeypointsStayClearOfTheHorizonCut() throws {
        let still = (x: 0.0, y: 0.0)
        let features = try skyFeatures(frame(star: still, ground: still), mask(ground: still))
        XCTAssertGreaterThan(features.keypointCount, 100, "the stars have to be found at all")

        // Vertical distance to the horizon is never less than the true distance, so a
        // keypoint that clears it by the erosion plus the margin cleared the cut too.
        let clearance = Double(skyHorizonExtension) + 40 - 2
        let closest = features.keypointPositions().map { horizon($0.x) - $0.y }.min() ?? .infinity
        XCTAssertGreaterThan(closest, clearance,
                             "a sky keypoint sits \(closest)px above the horizon, inside the band "
                             + "the cut's step reaches")
    }

    /// The end-to-end property: on a pan, where the sky and the ground move differently,
    /// the sky homography is the stars' motion, not a compromise with the horizon's.
    func testSkyHomographyFollowsTheStarsNotTheHorizon() throws {
        let starShift = (x: 6.0, y: 2.0), groundShift = (x: 1.0, y: 0.0)
        let still = (x: 0.0, y: 0.0)
        let base = try skyFeatures(frame(star: still, ground: still), mask(ground: still))
        let neighbor = try skyFeatures(frame(star: starShift, ground: groundShift),
                                       mask(ground: groundShift))

        let result = try XCTUnwrap(
          ImageAligner.computeHomography(
            baseKeypoints: base, frameIndex: 0,
            neighbors: [AlignmentNeighborInfo(filename: "neighbor", maskFilename: nil,
                                              keypoints: neighbor, frameIndex: 1)],
            matchMethod: .knnLowes, alignmentType: .sky, maxKeypoints: 2000,
            writeDebugImages: false, handler: { _, _, _, _ in }))
        let warp = try XCTUnwrap(result.warpInfo.first)
        let h = try XCTUnwrap(warp.homography?.homographyValues)

        // The warp maps the neighbour onto the base, so a star the neighbour shows at p
        // belongs at p - starShift — everywhere in the sky, not just where stars cluster.
        var worst = 0.0
        for y in stride(from: 40.0, through: 500, by: 92) {
            for x in stride(from: 40.0, through: 1160, by: 112) {
                let w = h[6] * x + h[7] * y + h[8]
                let mx = (h[0] * x + h[1] * y + h[2]) / w
                let my = (h[3] * x + h[4] * y + h[5]) / w
                worst = max(worst, hypot(mx - (x - starShift.x), my - (y - starShift.y)))
            }
        }
        XCTAssertLessThan(worst, 0.5,
                          "the sky warp misplaces stars by up to \(worst)px — pulled towards the "
                          + "ground's motion by keypoints on the horizon cut")
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
