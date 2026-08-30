import XCTest
@testable import StarCore
import StarCppBridge

/// The merge kernel has to tell a source that landed nothing at a pixel from one
/// that landed black there.  It used to read that off the pixel — a zero was a hole
/// — which is only true of a warped source, and only until a frame turns up whose
/// blacks are exactly zero.  Coverage now travels beside the sources as a count of
/// how many of them missed each pixel, so a merge that warps nothing declares no
/// holes at all and a black pixel is an observation like any other.
///
/// Widths here are deliberately not multiples of the block width: 61 pixels is 183
/// pixel-channels, which is 22 blocks of eight and a tail of seven, so every test
/// runs both the blocked kernel and the scalar one that finishes the row.
final class MergeCoveragePlaneTests: XCTestCase {

    private let width = 61
    private let height = 40

    private struct Spot {
        let x: Int, y: Int
        let r: UInt16, g: UInt16, b: UInt16
    }

    /// A 16-bit 3-channel frame of a flat background, with 3x3 squares painted over it.
    private func frame(background: (UInt16, UInt16, UInt16), spots: [Spot] = []) -> MatWrapper {
        var pixels = [UInt16](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            pixels[i * 3] = background.0
            pixels[i * 3 + 1] = background.1
            pixels[i * 3 + 2] = background.2
        }
        for spot in spots {
            for dy in -1...1 {
                for dx in -1...1 {
                    let index = ((spot.y + dy) * width + (spot.x + dx)) * 3
                    pixels[index] = spot.r
                    pixels[index + 1] = spot.g
                    pixels[index + 2] = spot.b
                }
            }
        }
        return pixels.withUnsafeMutableBytes { ptr in
            MatWrapper(
              width: width, height: height,
              cvType: 18, // CV_16UC3
              bytesPerRow: width * 6,
              data: ptr.baseAddress!,
              takeOwnership: false
            ).clone()
        }
    }

    private func channel(_ mat: MatWrapper, _ x: Int, _ y: Int, _ c: Int) -> UInt16 {
        guard let image = PixelatedImage(mat: mat),
              case .sixteenBit(let buffer) = image.imageData
        else {
            XCTFail("expected 16 bit data")
            return 0
        }
        return buffer[(y * width + x) * 3 + c]
    }

    private func bytes(_ mat: MatWrapper) -> [UInt16] {
        guard let image = PixelatedImage(mat: mat),
              case .sixteenBit(let buffer) = image.imageData
        else {
            XCTFail("expected 16 bit data")
            return []
        }
        return Array(buffer)
    }

    private func withLoader(_ frames: [String: MatWrapper], _ body: () throws -> Void) rethrows {
        ImageCache.setLoader { frames[$0] }
        defer { ImageCache.setLoader { MatWrapper.load(fromFilename: $0) } }
        try body()
    }

    private let identity = MatWrapper(homographyValues: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    // MARK: - The static merge, which warps nothing and so has no holes

    /// The 08_15_2026 a7riii regression, at 1/1000 scale.  A black-clipped foreground
    /// reads exactly 0 in almost every pixel-channel, so when zeros were taken for
    /// holes the only "observations" left at a ground pixel were the headlights of a
    /// car that had driven through two of the seventeen source frames — and the merge
    /// returned those, painting a car into a frame whose own ground was black.
    func testAStaticMergeOfABlackForegroundRejectsALightFewSourcesSaw() throws {
        let car = Spot(x: 30, y: 20, r: 65535, g: 57316, b: 43135)
        let dark = frame(background: (0, 0, 0))
        var frames: [String: MatWrapper] = [:]
        for i in 0..<16 {
            // the car crosses two of the sixteen neighbours, as it did over ~6 of
            // the 1436 frames of the sequence this comes from
            frames["n\(i)"] = (i == 3 || i == 4)
              ? frame(background: (0, 0, 0), spots: [car])
              : dark
        }

        try withLoader(frames) {
            let merged = ImageAligner.medianMergeImage(
              dark,                                       // the base saw no car either
              withFilenames: (0..<16).map { "n\($0)" },
              outlierThreshold: 1.2,
              includeAll: false
            )
            for c in 0..<3 {
                XCTAssertEqual(channel(merged, 30, 20, c), 0,
                               "a light two of seventeen sources saw must not " +
                               "survive a merge of a black foreground (channel \(c))")
            }
            // and the rest of the frame is still black, on both kernel paths
            XCTAssertEqual(channel(merged, 5, 5, 0), 0)
            XCTAssertEqual(channel(merged, 60, 39, 0), 0)   // last pixel, scalar tail
        }
    }

    /// The same rejection the merge has always done, on a foreground that is lit
    /// rather than clipped — so the fix above is not just "black wins".
    func testAStaticMergeStillRejectsABrightInterloperOnALitBackground() throws {
        let interloper = Spot(x: 30, y: 20, r: 60000, g: 60000, b: 60000)
        let plain = frame(background: (1000, 1200, 1400))
        var frames: [String: MatWrapper] = [:]
        for i in 0..<8 {
            frames["n\(i)"] = i == 2 ? frame(background: (1000, 1200, 1400), spots: [interloper])
                                     : plain
        }

        try withLoader(frames) {
            let merged = ImageAligner.medianMergeImage(
              plain,
              withFilenames: (0..<8).map { "n\($0)" },
              outlierThreshold: 1.2,
              includeAll: false
            )
            XCTAssertEqual(channel(merged, 30, 20, 0), 1000)
            XCTAssertEqual(channel(merged, 30, 20, 1), 1200)
            XCTAssertEqual(channel(merged, 30, 20, 2), 1400)
        }
    }

    /// `includeAll` counts every source at every pixel and asks nothing about
    /// coverage, which is what the horizon-mask merge relies on.  Its 0s are ground
    /// votes, and they have to stay 0s.
    func testIncludeAllIsUntouchedAndDoesNotLiftZeros() throws {
        let black = frame(background: (0, 0, 0))
        let frames = ["n0": black, "n1": black]

        try withLoader(frames) {
            let merged = ImageAligner.medianMergeImage(
              black, withFilenames: ["n0", "n1"],
              outlierThreshold: 1.2,
              includeAll: true
            )
            XCTAssertEqual(channel(merged, 30, 20, 0), 0)
            XCTAssertEqual(channel(merged, 60, 39, 2), 0)
        }
    }

    // MARK: - The aligned merge, which does have holes

    /// The warp borders are still holes, and now they are the only ones.  A neighbour
    /// shifted diagonally covers part of the frame; where it does not reach, the base
    /// alone decides and comes through exactly, however bright the neighbour was.
    func testAWarpsUncoveredRegionContributesNothing() throws {
        let base = frame(background: (700, 1000, 2000))
        let bright = frame(background: (40000, 40000, 40000))
        // dst(x, y) = src(x - 31, y - 6): covered for x >= 31 and y >= 6
        let shifted = MatWrapper(homographyValues: [1, 0, 31,
                                                    0, 1, 6,
                                                    0, 0, 1])

        try withLoader(["n1": bright]) {
            let result = try XCTUnwrap(
              ImageAligner.alignAndMedianMerge(
                baseImage: base, baseFrameIndex: 10,
                neighbors: [AlignmentNeighborInfo(filename: "n1", maskFilename: nil,
                                                  keypoints: nil, frameIndex: 11)],
                homography: [1: shifted],
                outlierThreshold: 1.2, includeAll: false,
                scratchDir: NSTemporaryDirectory(),
                streamingThresholdBytes: 0, loadConcurrency: 1
              )
            )
            XCTAssertEqual(result.warpCount, 1)
            let merged = result.merged

            // uncovered: left of the shift, above it, and the corner outside both
            for (x, y) in [(10, 20), (45, 2), (10, 2), (0, 0), (30, 39)] {
                XCTAssertEqual(channel(merged, x, y, 0), 700, "at \(x),\(y)")
                XCTAssertEqual(channel(merged, x, y, 1), 1000, "at \(x),\(y)")
                XCTAssertEqual(channel(merged, x, y, 2), 2000, "at \(x),\(y)")
            }

            // covered: two sources, and the merge picks between them rather than
            // reading the base as the only thing present
            XCTAssertEqual(channel(merged, 45, 20, 0), 700)
            XCTAssertNotEqual(channel(merged, 45, 20, 0), 0,
                              "a covered pixel must not read as a hole")
        }
    }

    /// A genuinely black channel that the warp did cover is an observation, and it
    /// leaves the merge as the zero it arrived as.  Lifting every source off zero
    /// before merging used to make this 1.
    func testACoveredBlackChannelStaysZero() throws {
        // deep twilight: red at exactly 0 across the frame
        let dusk = frame(background: (0, 1000, 2000))
        let beacon = frame(background: (0, 1000, 2000),
                           spots: [Spot(x: 40, y: 20, r: 60000, g: 1500, b: 2500)])

        try withLoader(["n1": dusk, "n2": beacon, "n3": dusk]) {
            let result = try XCTUnwrap(
              ImageAligner.alignAndMedianMerge(
                baseImage: dusk, baseFrameIndex: 10,
                neighbors: (1...3).map {
                    AlignmentNeighborInfo(filename: "n\($0)", maskFilename: nil,
                                          keypoints: nil, frameIndex: 10 + $0)
                },
                homography: [1: identity, 2: identity, 3: identity],
                outlierThreshold: 1.2, includeAll: false,
                scratchDir: NSTemporaryDirectory(),
                streamingThresholdBytes: 0, loadConcurrency: 1
              )
            )
            let merged = result.merged

            // plain sky: red is black, and stays exactly black
            XCTAssertEqual(channel(merged, 12, 30, 0), 0)
            XCTAssertEqual(channel(merged, 12, 30, 1), 1000)

            // and the one source's beacon is still rejected on that zero red floor
            XCTAssertEqual(channel(merged, 40, 20, 0), 0)
        }
    }

    /// The coverage plane stays whole and resident while the sources are spilled a
    /// band at a time, so each band has to take a view of its own rows.  Getting that
    /// offset wrong would move the holes up or down the frame; the two paths are
    /// documented as bit-identical, so compare them.
    func testStreamingAndResidentMergesAgreeWithAPartialWarp() throws {
        let base = frame(background: (700, 1000, 2000),
                         spots: [Spot(x: 45, y: 20, r: 30000, g: 30000, b: 30000)])
        let bright = frame(background: (40000, 12000, 900))
        let shifted = MatWrapper(homographyValues: [1, 0, 17,
                                                    0, 1, 9,
                                                    0, 0, 1])

        try withLoader(["n1": bright, "n2": frame(background: (500, 900, 1800))]) {
            func merge(streamingThreshold: Int64) throws -> [UInt16] {
                let result = try XCTUnwrap(
                  ImageAligner.alignAndMedianMerge(
                    baseImage: base, baseFrameIndex: 10,
                    neighbors: [
                      AlignmentNeighborInfo(filename: "n1", maskFilename: nil,
                                            keypoints: nil, frameIndex: 11),
                      AlignmentNeighborInfo(filename: "n2", maskFilename: nil,
                                            keypoints: nil, frameIndex: 12),
                    ],
                    homography: [1: shifted, 2: identity],
                    outlierThreshold: 1.2, includeAll: false,
                    scratchDir: NSTemporaryDirectory(),
                    streamingThresholdBytes: streamingThreshold, loadConcurrency: 1
                  )
                )
                return bytes(result.merged)
            }

            let resident = try merge(streamingThreshold: 0)     // streaming disabled
            let streamed = try merge(streamingThreshold: 1)     // always streams
            XCTAssertFalse(resident.isEmpty)
            XCTAssertEqual(resident, streamed,
                           "the streaming merge must see the same coverage as the " +
                           "resident one, band offsets included")
        }
    }

    /// Decoding more than one source at a time accumulates into one plane from
    /// several threads.  Whatever the scheduling, the plane has to come out the same.
    func testConcurrentLoadingProducesTheSameCoverage() throws {
        let base = frame(background: (700, 1000, 2000))
        var frames: [String: MatWrapper] = [:]
        var homographies: [Int: MatWrapper] = [:]
        for i in 1...6 {
            frames["n\(i)"] = frame(background: (UInt16(3000 * i), 1000, 2000))
            homographies[i] = MatWrapper(homographyValues: [1, 0, Double(i * 3),
                                                            0, 1, Double(i),
                                                            0, 0, 1])
        }

        try withLoader(frames) {
            func merge(loadConcurrency: Int) throws -> [UInt16] {
                let result = try XCTUnwrap(
                  ImageAligner.alignAndMedianMerge(
                    baseImage: base, baseFrameIndex: 10,
                    neighbors: (1...6).map {
                        AlignmentNeighborInfo(filename: "n\($0)", maskFilename: nil,
                                              keypoints: nil, frameIndex: 10 + $0)
                    },
                    homography: homographies,
                    outlierThreshold: 1.2, includeAll: false,
                    scratchDir: NSTemporaryDirectory(),
                    streamingThresholdBytes: 0, loadConcurrency: loadConcurrency
                  )
                )
                return bytes(result.merged)
            }

            let serial = try merge(loadConcurrency: 1)
            XCTAssertFalse(serial.isEmpty)
            for _ in 0..<3 {
                XCTAssertEqual(try merge(loadConcurrency: 6), serial)
            }
        }
    }
}
