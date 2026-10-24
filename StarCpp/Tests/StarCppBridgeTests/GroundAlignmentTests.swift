import XCTest
@testable import StarCppBridge

/// Coverage for the two things that decide whether a dark foreground can be aligned at
/// all: the contrast stretch that hands the detector its pixels, and the check that
/// refuses a homography the correspondences do not support.
///
/// Both were written for one failure.  A sequence extracted from an already-encoded
/// 10-bit video arrived with its ground clipped to black — 98.4% of the ground pixels
/// were exactly 0 — while one distant light in the same region sat at 65448 of 65535.
/// The stretch took its range from that light, so the whole ground quantised to 8-bit 0
/// and the detector found almost nothing; RANSAC then fitted eight degrees of freedom to
/// what noise was left and reported near-180-degree rotations as successes, which the
/// merge dutifully warped every neighbour by.  The first half of that is what
/// `maskedStretchToGray8` covers here, the second what `computeHomography` covers.
final class GroundAlignmentTests: XCTestCase {

    // MARK: - building test images

    /// A 16-bit single-channel MatWrapper from `value(x, y)`.
    private func mat16(width: Int, height: Int,
                       _ value: (Int, Int) -> UInt16) -> MatWrapper {
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: width * height)
        for y in 0..<height {
            for x in 0..<width { data[y * width + x] = value(x, y) }
        }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 16,
                                                    componentsPerPixel: 1),
                          bytesPerRow: width * MemoryLayout<UInt16>.size,
                          data: UnsafeMutableRawPointer(data),
                          takeOwnership: true)
    }

    /// An 8-bit single-channel MatWrapper from `value(x, y)`.  Masks are this type, and
    /// so is a frame that came from a jpeg.
    private func mat8(width: Int, height: Int,
                      _ value: (Int, Int) -> UInt8) -> MatWrapper {
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        for y in 0..<height {
            for x in 0..<width { data[y * width + x] = value(x, y) }
        }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 8,
                                                    componentsPerPixel: 1),
                          bytesPerRow: width,
                          data: UnsafeMutableRawPointer(data),
                          takeOwnership: true)
    }

    private func pixels8(of mat: MatWrapper) throws -> [[UInt8]] {
        let base = try XCTUnwrap(mat.dataPtr)
        let step = mat.step
        return (0..<mat.rows).map { y in
            let row = base.advanced(by: y * step).assumingMemoryBound(to: UInt8.self)
            return (0..<mat.cols).map { row[$0] }
        }
    }

    /// Reproducible noise.  `Int.random` would make a failure impossible to look at
    /// twice, and these tests are about what a detector does with a specific image.
    private struct Rand {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next(_ bound: UInt32) -> UInt32 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt32(truncatingIfNeeded: state >> 33) % bound
        }
    }

    // MARK: - the contrast stretch

    private let width = 200
    private let height = 100
    /// The selection the stretch is asked about, which is the ground: white below the
    /// horizon, black above.  That is the inverse of a horizon mask as star stores it —
    /// `ia_find_features` does the inverting, and this entry point is below that, so it
    /// takes the region directly.
    private func groundSelection() -> MatWrapper {
        mat8(width: width, height: height) { _, y in y < 50 ? 0 : 255 }
    }

    /// The failure in miniature: a ground whose real content spans 0-199 out of 65535,
    /// with one pixel of it at 65000.
    ///
    /// Under min/max that one pixel sets the scale at 255/65000, and every real value in
    /// the ground lands on 8-bit 0 or 1 — two levels for the whole foreground, which is
    /// nothing for CLAHE to stretch or for a detector to lock onto.  Under the shipped
    /// percentile range the same ramp spans the full 0-255.
    func testOneBrightPixelDoesNotFlattenTheGround() throws {
        let image = mat16(width: width, height: height) { x, y in
            if y < 50 { return 30000 }                 // sky, outside the mask
            if x == 0 && y == 50 { return 65000 }      // the light
            return UInt16(x)                           // ground: a 0-199 ramp
        }
        let stretched = try XCTUnwrap(
          ImageAligner.maskedStretchToGray8(image, mask: groundSelection())
        )
        let rows = try pixels8(of: stretched)

        // The sky is outside the mask and is zeroed, as it always was.
        XCTAssertTrue(rows[0].allSatisfy { $0 == 0 })
        XCTAssertTrue(rows[49].allSatisfy { $0 == 0 })

        // The ramp now spans the range instead of collapsing onto 0 and 1.
        let ground = rows[60]
        XCTAssertEqual(ground[0], 0)
        XCTAssertEqual(ground[width - 1], 255)
        XCTAssertGreaterThan(Set(ground).count, 150,
                             "the ground's 200 distinct values should survive the "
                             + "8-bit conversion; min/max left 2")

        // The light itself is not lost, it saturates.
        XCTAssertEqual(rows[50][0], 255)
    }

    /// The same for an 8-bit source, which is the whole of what a jpeg sequence has.
    /// The histogram takes a different branch for CV_8U and the compression is milder,
    /// but a foreground pinned to the bottom sixth of the range is still a foreground
    /// with nothing in it once CLAHE and the detector have had their turn.
    func testEightBitGroundIsStretchedToo() throws {
        let image = mat8(width: width, height: height) { x, y in
            if y < 50 { return 120 }                   // sky, outside the mask
            if x == 0 && y == 50 { return 255 }        // the light
            return UInt8(x / 5)                        // ground: a 0-39 ramp
        }
        let stretched = try XCTUnwrap(
          ImageAligner.maskedStretchToGray8(image, mask: groundSelection())
        )
        let ground = try pixels8(of: stretched)[60]
        XCTAssertEqual(ground[0], 0)
        XCTAssertEqual(ground[width - 1], 255)
        XCTAssertGreaterThan(Set(ground).count, 30)
    }

    /// A mask selecting one single value has no percentile range to offer.  It must
    /// fall through to the old behaviour rather than divide by a zero span.
    func testUniformGroundDoesNotDivideByZero() throws {
        let image = mat16(width: width, height: height) { _, y in y < 50 ? 30000 : 700 }
        let stretched = try XCTUnwrap(
          ImageAligner.maskedStretchToGray8(image, mask: groundSelection())
        )
        let rows = try pixels8(of: stretched)
        XCTAssertTrue(rows[0].allSatisfy { $0 == 0 })
        // Whatever a flat region maps to, it maps there without crashing and stays flat.
        XCTAssertEqual(Set(rows[60]).count, 1)
    }

    /// A selection too small for 0.1% of it to be a whole pixel still has to answer
    /// with a value that is in it.  The low bound rounds its share down to nothing
    /// there, and a target of zero is satisfied by the first bin looked at — which
    /// would put the black point at 0 for a region whose darkest pixel is 8000.
    func testATinySelectionStillTakesItsRangeFromItsOwnPixels() throws {
        // 20 pixels: one row, twenty columns, values 8000 up to 8000 + 19 * 100.
        let image = mat16(width: 20, height: 3) { x, y in
            y == 1 ? UInt16(8000 + x * 100) : 60000
        }
        let selection = mat8(width: 20, height: 3) { _, y in y == 1 ? 255 : 0 }
        let stretched = try XCTUnwrap(
          ImageAligner.maskedStretchToGray8(image, mask: selection)
        )
        let row = try pixels8(of: stretched)[1]
        XCTAssertEqual(row[0], 0)
        XCTAssertEqual(row[19], 255)
        XCTAssertGreaterThan(Set(row).count, 15,
                             "the 20 values should still spread across the range")
    }

    /// With no mask there is no selection to take percentiles of, and the plain
    /// whole-image conversion is what runs — unchanged by any of this.
    func testNoMaskKeepsThePlainConversion() throws {
        let image = mat16(width: width, height: height) { x, _ in UInt16(x * 300) }
        let stretched = try XCTUnwrap(ImageAligner.maskedStretchToGray8(image, mask: nil))
        let row = try pixels8(of: stretched)[0]
        // toGray8U on CV_16U is a straight >> 8, not a stretch.
        XCTAssertEqual(row[1], UInt8(300 / 256))
        XCTAssertEqual(row[100], UInt8((100 * 300) / 256))
    }

    // MARK: - the ground consensus check

    private let alignWidth = 480
    private let alignHeight = 320
    private let alignHorizon = 200

    private func alignMask() -> MatWrapper {
        mat8(width: alignWidth, height: alignHeight) { _, y in
            y < self.alignHorizon ? 255 : 0
        }
    }

    /// A frame whose ground carries real texture, optionally shifted — a neighbour of
    /// itself, the way consecutive frames of a pan are.
    private func texturedGround(shiftX: Int, shiftY: Int) -> MatWrapper {
        var rand = Rand(seed: 20260829)
        var texture = [[UInt16]](repeating: [UInt16](repeating: 0, count: alignWidth),
                                 count: alignHeight)
        for y in 0..<alignHeight {
            for x in 0..<alignWidth { texture[y][x] = UInt16(rand.next(24000) + 4000) }
        }
        return mat16(width: alignWidth, height: alignHeight) { x, y in
            if y < self.alignHorizon { return 30000 }
            let sx = min(max(x - shiftX, 0), self.alignWidth - 1)
            let sy = min(max(y - shiftY, 0), self.alignHeight - 1)
            return texture[sy][sx]
        }
    }

    /// A frame whose ground is black apart from sensor noise — the shape the video
    /// intermediate arrived in.  Each call gets its own noise, so two of them share no
    /// real content and any correspondence between them is a coincidence.
    private func blackGround(seed: UInt64) -> MatWrapper {
        var rand = Rand(seed: seed)
        var noise = [[UInt16]](repeating: [UInt16](repeating: 0, count: alignWidth),
                               count: alignHeight)
        for y in 0..<alignHeight {
            for x in 0..<alignWidth { noise[y][x] = UInt16(rand.next(3)) }
        }
        return mat16(width: alignWidth, height: alignHeight) { x, y in
            y < self.alignHorizon ? 30000 : noise[y][x]
        }
    }

    private func earthFeatures(of image: MatWrapper, mask: MatWrapper? = nil) -> OCVFeatureSet? {
        ImageAligner.findFeatures(baseImage: image,
                                  frameIndex: 0,
                                  matchMethod: .knnLowes,
                                  mask: mask ?? alignMask(),
                                  alignmentType: .earth,
                                  maxKeypoints: 2000,
                                  writeDebugImages: false,
                                  groundHorizonExtension: 100,
                                  skyHorizonExtension: 40,
                                  baseImageDilateSize: 20,
                                  baseImageThresholdValue: 100)
    }

    /// The masks and size default to the 480x320 frames above.
    private func groundHomography(base: MatWrapper, baseMask: MatWrapper? = nil,
                                  neighbor: MatWrapper, neighborMask: MatWrapper? = nil,
                                  width: Int? = nil, height: Int? = nil)
      throws -> AlignmentWarpInfo
    {
        let baseFeatures = try XCTUnwrap(earthFeatures(of: base, mask: baseMask))
        let neighborFeatures = try XCTUnwrap(earthFeatures(of: neighbor, mask: neighborMask))
        let result = try XCTUnwrap(
          ImageAligner.computeHomography(
            baseKeypoints: baseFeatures,
            frameIndex: 0,
            neighbors: [AlignmentNeighborInfo(filename: "neighbor",
                                              maskFilename: nil,
                                              keypoints: neighborFeatures,
                                              frameIndex: 1)],
            matchMethod: .knnLowes,
            alignmentType: .earth,
            maxKeypoints: 2000,
            writeDebugImages: false,
            imageWidth: Int32(width ?? alignWidth),
            imageHeight: Int32(height ?? alignHeight),
            handler: { _, _, _, _ in })
        )
        return try XCTUnwrap(result.warpInfo.first)
    }

    /// The check must not cost a ground that has something in it.  A textured
    /// foreground shifted by a few pixels is the ordinary case, and it goes through.
    func testTrackableGroundStillGetsItsHomography() throws {
        let warp = try groundHomography(base: texturedGround(shiftX: 0, shiftY: 0),
                                        neighbor: texturedGround(shiftX: 4, shiftY: 3))
        XCTAssertEqual(warp.alignmentState, .homographySuccess)
        let homography = try XCTUnwrap(warp.homography)
        let values = try XCTUnwrap(homography.homographyValues)

        // It found the shift it was given: the ground of the neighbour maps back onto
        // the base's, so the translation is the shift with its sign flipped.
        XCTAssertEqual(values[2], -4, accuracy: 1.5)
        XCTAssertEqual(values[5], -3, accuracy: 1.5)
    }

    /// A ground with nothing in it produces no homography rather than a wrong one.
    ///
    /// The two frames share no ground content, so every correspondence between them is
    /// descriptor noise.  Before the check, RANSAC's four-point consensus came back as
    /// `homographySuccess` and the merge warped by it.  The state may be
    /// `notEnoughKeypoints` or `noHomographyFound` depending on how much noise the
    /// detector finds, and either is fine — what matters downstream is only that there
    /// is no matrix, because that is what makes the merge drop the neighbour instead of
    /// smearing the ground with it.
    func testUntrackableGroundYieldsNoHomography() throws {
        let warp = try groundHomography(base: blackGround(seed: 1),
                                        neighbor: blackGround(seed: 2))
        XCTAssertNil(warp.homography,
                     "a ground with no shared content must not produce a warp")
        XCTAssertNotEqual(warp.alignmentState, .homographySuccess)
    }

    // MARK: - a panning camera

    /// A ground with structure a few pixels across, which a warp can carry from one frame
    /// to the next where per-pixel noise would be resampled away: random levels on a
    /// 4px lattice, bilinearly interpolated.  Defined well beyond the frame, so that a
    /// neighbour rendered through a rotation has ground everywhere it looks.
    private struct GroundScene {
        private let spacing = 4.0
        private let originX = -256.0, originY = 256.0
        private let columns = 448, rows = 160
        private var levels: [Double]

        init(seed: UInt64) {
            var rand = Rand(seed: seed)
            levels = (0..<(columns * rows)).map { _ in 4000 + Double(rand.next(24000)) }
        }

        /// The scene at (x, y) of the base frame: sky above `horizon`, ground below.
        func value(_ x: Double, _ y: Double, horizon: Int) -> UInt16 {
            if y < Double(horizon) { return 30000 }
            let u = (x - originX) / spacing, v = (y - originY) / spacing
            let i = min(max(Int(u.rounded(.down)), 0), columns - 2)
            let j = min(max(Int(v.rounded(.down)), 0), rows - 2)
            let fu = min(max(u - Double(i), 0), 1), fv = min(max(v - Double(j), 0), 1)
            let a = levels[j * columns + i], b = levels[j * columns + i + 1]
            let c = levels[(j + 1) * columns + i], d = levels[(j + 1) * columns + i + 1]
            let top = a + (b - a) * fu, bottom = c + (d - c) * fu
            return UInt16((top + (bottom - top) * fv).rounded())
        }
    }

    /// K R K^-1, row-major, for a camera centred on the frame that pans by `pan` about its
    /// vertical axis and tilts by `tilt` about its horizontal one.
    private func cameraRotation(pan: Double, tilt: Double,
                                f: Double, cx: Double, cy: Double) -> [Double] {
        let yaw: [[Double]] = [[cos(pan), 0, sin(pan)], [0, 1, 0], [-sin(pan), 0, cos(pan)]]
        let pitch: [[Double]] = [[1, 0, 0], [0, cos(tilt), -sin(tilt)], [0, sin(tilt), cos(tilt)]]
        let k: [[Double]] = [[f, 0, cx], [0, f, cy], [0, 0, 1]]
        let kInverse: [[Double]] = [[1 / f, 0, -cx / f], [0, 1 / f, -cy / f], [0, 0, 1]]
        let h = multiply(multiply(k, multiply(pitch, yaw)), kInverse)
        return h.flatMap { $0 }.map { $0 / h[2][2] }
    }

    private func multiply(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        (0..<3).map { r in (0..<3).map { c in (0..<3).reduce(0.0) { $0 + a[r][$1] * b[$1][c] } } }
    }

    private func inverse(_ h: [Double]) -> [Double] {
        let m = [[h[0], h[1], h[2]], [h[3], h[4], h[5]], [h[6], h[7], h[8]]]
        let cofactor: (Int, Int) -> Double = { r, c in
            let rows = (0..<3).filter { $0 != r }, cols = (0..<3).filter { $0 != c }
            let minor = m[rows[0]][cols[0]] * m[rows[1]][cols[1]]
              - m[rows[0]][cols[1]] * m[rows[1]][cols[0]]
            return ((r + c) % 2 == 0 ? 1 : -1) * minor
        }
        let det = (0..<3).reduce(0.0) { $0 + m[0][$1] * cofactor(0, $1) }
        return (0..<3).flatMap { r in (0..<3).map { c in cofactor(c, r) / det } }
    }

    private func apply(_ h: [Double], _ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let w = h[6] * x + h[7] * y + h[8]
        return ((h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w)
    }

    /// The least-squares similarity — rotation, uniform scale, translation — taking each
    /// `from` onto its `to`, as row-major 3x3.  The closed form: with both sets centred,
    /// [a -b; b a] is fixed by two sums.
    private func bestSimilarity(_ pairs: [(from: (x: Double, y: Double),
                                           to: (x: Double, y: Double))]) -> [Double] {
        let n = Double(pairs.count)
        let fx = pairs.reduce(0) { $0 + $1.from.x } / n, fy = pairs.reduce(0) { $0 + $1.from.y } / n
        let tx = pairs.reduce(0) { $0 + $1.to.x } / n, ty = pairs.reduce(0) { $0 + $1.to.y } / n
        var dot = 0.0, cross = 0.0, norm = 0.0
        for p in pairs {
            let u = p.from.x - fx, v = p.from.y - fy, s = p.to.x - tx, t = p.to.y - ty
            dot += u * s + v * t
            cross += u * t - v * s
            norm += u * u + v * v
        }
        let a = dot / norm, b = cross / norm
        return [a, -b, tx - (a * fx - b * fy), b, a, ty - (b * fx + a * fy), 0, 0, 1]
    }

    /// A camera turning on its head moves the ground by a homography, K R K^-1, whose
    /// sideways shift grows towards the edges of the frame — 1 + x²/f² times the centre's.
    /// The ground is fitted as that rotation, so it has to put the whole width of the
    /// ground back, edges included, and find the focal length to do it with: the frames
    /// carry none.  The 4-DOF similarity it replaced is linear in x, and could not.
    func testAPanIsFittedAcrossTheWholeWidthOfTheGround() throws {
        let width = 960, height = 640, horizon = 400
        let f = 0.55 * Double(width)   // about a 20mm lens on full frame
        let cx = Double(width - 1) / 2, cy = Double(height - 1) / 2
        // a pan that moves the middle of the frame 12px, and a little tilt
        let truth = cameraRotation(pan: atan(12 / f), tilt: 0.002, f: f, cx: cx, cy: cy)
        let untruth = inverse(truth)

        // The neighbour sees at q what the base saw at truth^-1(q), sky and ground alike.
        let scene = GroundScene(seed: 20261023)
        let base = mat16(width: width, height: height) { x, y in
            scene.value(Double(x), Double(y), horizon: horizon)
        }
        let neighbor = mat16(width: width, height: height) { x, y in
            let p = self.apply(untruth, Double(x), Double(y))
            return scene.value(p.x, p.y, horizon: horizon)
        }
        let baseMask = mat8(width: width, height: height) { _, y in y < horizon ? 255 : 0 }
        let neighborMask = mat8(width: width, height: height) { x, y in
            self.apply(untruth, Double(x), Double(y)).y < Double(horizon) ? 255 : 0
        }

        let warp = try groundHomography(base: base, baseMask: baseMask,
                                        neighbor: neighbor, neighborMask: neighborMask,
                                        width: width, height: height)
        XCTAssertEqual(warp.alignmentState, .homographySuccess)
        let h = try XCTUnwrap(warp.homography?.homographyValues)

        // The warp maps the neighbour onto the base: ground the neighbour shows at
        // truth(p) belongs at p, all the way across.
        var ground: [(x: Double, y: Double)] = []
        for y in stride(from: 420.0, through: 620, by: 40) {
            for x in stride(from: 40.0, through: 920, by: 40) { ground.append((x, y)) }
        }
        let worst = ground.map { p -> Double in
            let q = apply(truth, p.x, p.y), back = apply(h, q.x, q.y)
            return hypot(back.x - p.x, back.y - p.y)
        }.max() ?? .infinity
        XCTAssertLessThan(worst, 0.75,
                          "the ground fit is \(worst)px out somewhere across the frame")

        // The pan is one the similarity could not have fitted: the best one to this exact
        // motion, with no noise at all, is still pixels out at the edges.
        let similarity = bestSimilarity(ground.map { (from: apply(truth, $0.x, $0.y), to: $0) })
        let similarityWorst = ground.map { p -> Double in
            let q = apply(truth, p.x, p.y), back = apply(similarity, q.x, q.y)
            return hypot(back.x - p.x, back.y - p.y)
        }.max() ?? 0
        XCTAssertGreaterThan(similarityWorst, 3,
                             "precondition: a pan whose curvature a similarity cannot follow")
    }
}
