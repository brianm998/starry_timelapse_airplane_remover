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

    private func earthFeatures(of image: MatWrapper) -> OCVFeatureSet? {
        ImageAligner.findFeatures(baseImage: image,
                                  frameIndex: 0,
                                  matchMethod: .knnLowes,
                                  mask: alignMask(),
                                  alignmentType: .earth,
                                  maxKeypoints: 2000,
                                  writeDebugImages: false,
                                  groundHorizonExtension: 100,
                                  skyHorizonExtension: 40,
                                  baseImageDilateSize: 20,
                                  baseImageThresholdValue: 100)
    }

    private func groundHomography(base: MatWrapper,
                                  neighbor: MatWrapper) throws -> AlignmentWarpInfo {
        let baseFeatures = try XCTUnwrap(earthFeatures(of: base))
        let neighborFeatures = try XCTUnwrap(earthFeatures(of: neighbor))
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
}
