import XCTest
@testable import StarCore
import StarCppBridge

/// The aligned merge's "zero means no data" convention exists for warp borders, and
/// it used to swallow legitimately-zero pixel-channels with it: a deep twilight sky
/// exposes with its red channel at exactly 0, so in that channel one source's red
/// light — an airplane's beacon — was the only observation the median saw, and it
/// stamped straight through the merge whose whole purpose is to remove it.  Sources
/// are now lifted off zero before warping, so only warp borders read as no-data.
final class AlignedMergeZeroFloorTests: XCTestCase {

    private let width = 64
    private let height = 64

    /// A 16-bit 3-channel frame of deep twilight: red exactly 0, green and blue lit.
    /// `spots` paints 3x3 squares of the given channel values.
    private func duskFrame(
      spots: [(x: Int, y: Int, r: UInt16, g: UInt16, b: UInt16)] = []
    ) -> MatWrapper {
        var pixels = [UInt16](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            pixels[i * 3] = 0          // red: a dusk sky has none
            pixels[i * 3 + 1] = 1000
            pixels[i * 3 + 2] = 2000
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
        let image = PixelatedImage(mat: mat)!
        guard case .sixteenBit(let buffer) = image.imageData else {
            XCTFail("expected 16 bit data")
            return 0
        }
        return buffer[(y * width + x) * 3 + c]
    }

    func testARedLightOnZeroRedSkyDoesNotStampThroughTheMerge() throws {
        let star = (x: 20, y: 20, r: UInt16(50000), g: UInt16(50000), b: UInt16(50000))
        let base = duskFrame(spots: [star])
        // three aligned neighbours: same star, and one of them carries a red
        // airplane beacon over sky whose red channel is otherwise exactly 0
        let plain = duskFrame(spots: [star])
        let withBeacon = duskFrame(spots: [
          star, (x: 40, y: 40, r: 60000, g: 1500, b: 2500),
        ])

        let frames: [String: MatWrapper] = [
          "n1": plain, "n2": withBeacon, "n3": duskFrame(spots: [star]),
        ]
        ImageCache.setLoader { frames[$0] }
        defer { ImageCache.setLoader { MatWrapper.load(fromFilename: $0) } }

        let identity = MatWrapper(homographyValues: [1, 0, 0, 0, 1, 0, 0, 0, 1])
        let result = try XCTUnwrap(
          ImageAligner.alignAndMedianMerge(
            baseImage: base,
            baseFrameIndex: 10,
            neighbors: [
              AlignmentNeighborInfo(filename: "n1", maskFilename: nil,
                                    keypoints: nil, frameIndex: 11),
              AlignmentNeighborInfo(filename: "n2", maskFilename: nil,
                                    keypoints: nil, frameIndex: 12),
              AlignmentNeighborInfo(filename: "n3", maskFilename: nil,
                                    keypoints: nil, frameIndex: 13),
            ],
            homography: [1: identity, 2: identity, 3: identity],
            outlierThreshold: 1.2,
            includeAll: false,
            scratchDir: NSTemporaryDirectory(),
            streamingThresholdBytes: 0,
            loadConcurrency: 1
          )
        )
        XCTAssertEqual(result.warpCount, 3)
        let merged = result.merged

        // the beacon appears in one source of four: the median has to reject it,
        // which it could not do when the other sources' zeros read as "no data"
        XCTAssertLessThanOrEqual(channel(merged, 40, 40, 0), 1,
                                 "one source's red light must not survive the merge")

        // the star is in every source and has to come through untouched
        XCTAssertGreaterThan(channel(merged, 20, 20, 0), 40000)

        // plain sky: red stays black to within the off-zero lift
        XCTAssertLessThanOrEqual(channel(merged, 50, 12, 0), 1)
        XCTAssertEqual(channel(merged, 50, 12, 1), 1000)
    }

    func testWarpBordersStillReadAsNoData() throws {
        let base = duskFrame()
        // this neighbour is shifted half the frame away: the uncovered half of its
        // warp must contribute nothing rather than a wall of lifted-off-zero values
        let shifted = MatWrapper(homographyValues: [1, 0, Double(width / 2),
                                                    0, 1, 0,
                                                    0, 0, 1])
        let bright = duskFrame(spots: [(x: 10, y: 10, r: 30000, g: 30000, b: 30000)])
        ImageCache.setLoader { $0 == "n1" ? bright : nil }
        defer { ImageCache.setLoader { MatWrapper.load(fromFilename: $0) } }

        let result = try XCTUnwrap(
          ImageAligner.alignAndMedianMerge(
            baseImage: base,
            baseFrameIndex: 10,
            neighbors: [AlignmentNeighborInfo(filename: "n1", maskFilename: nil,
                                              keypoints: nil, frameIndex: 11)],
            homography: [1: shifted],
            outlierThreshold: 1.2,
            includeAll: false,
            scratchDir: NSTemporaryDirectory(),
            streamingThresholdBytes: 0,
            loadConcurrency: 1
          )
        )
        XCTAssertEqual(result.warpCount, 1)
        let merged = result.merged

        // in the half the warp did not cover, the base frame alone decides
        XCTAssertEqual(channel(merged, 8, 32, 1), 1000)
        XCTAssertEqual(channel(merged, 8, 32, 2), 2000)
    }
}
