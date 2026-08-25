import XCTest
@testable import StarCore

/// The geometry behind `StarAlignedHorizonMask`: intersecting the horizon mask with
/// itself warped by each merge homography keeps a pixel "sky" only when every warped
/// source of the star-aligned merge leaves it above ground.
///
/// The homographies here map a neighbour's coordinates onto the base frame's, the way
/// `cv::findHomography(ptsNeighbor, ptsBase)` builds them for the merge.  A vertical
/// translation with negative ty is a neighbour whose warp lifts content up — the
/// setting-sky case that used to need a hand-entered `horizonVerticalShiftAmount`.
final class StarAlignedHorizonMaskTests: XCTestCase {

    private let width = 200
    private let height = 300
    private let horizonY = 100

    private func flatMask(at y: Int? = nil) -> PixelatedImage {
        let boundary = y ?? horizonY
        guard let mask = PixelatedImage.fromHorizonColumnY(
                width: width,
                height: height,
                columnY: [Int?](repeating: boundary, count: width)
              )
        else {
            fatalError("cannot build a flat test mask")
        }
        return mask
    }

    private func translation(tx: Double = 0, ty: Double = 0) -> [Double] {
        [1, 0, tx,
         0, 1, ty,
         0, 0, 1]
    }

    private func boundary(of mask: PixelatedImage) -> [Int?] {
        HorizonScoring.extractHorizonYPerColumn(from: mask)
    }

    // MARK: - The envelope

    func testAWarpThatLiftsGroundRaisesTheMaskByItsDisplacement() throws {
        let mask = flatMask()
        let result = try XCTUnwrap(
          StarAlignedHorizonMask.compute(from: mask,
                                         homographies: [translation(ty: -20)])
        )
        let boundary = boundary(of: result)
        for x in 0..<width {
            XCTAssertEqual(boundary[x], horizonY - 20,
                           "column \(x): a neighbour warped 20px up lands its " +
                           "ground 20px above the base horizon")
        }
    }

    func testAWarpThatLowersGroundLeavesTheMaskAlone() throws {
        let mask = flatMask()
        let result = try XCTUnwrap(
          StarAlignedHorizonMask.compute(from: mask,
                                         homographies: [translation(ty: 20)])
        )
        let boundary = boundary(of: result)
        for x in 0..<width {
            XCTAssertEqual(boundary[x], horizonY,
                           "column \(x): ground warped downward stays below the " +
                           "base horizon, where the mask is already ground")
        }
    }

    func testMultipleNeighboursTakeTheHighestGround() throws {
        let mask = flatMask()
        let result = try XCTUnwrap(
          StarAlignedHorizonMask.compute(
            from: mask,
            homographies: [translation(ty: -5),
                           translation(ty: -20),
                           translation(ty: 30)])
        )
        let boundary = boundary(of: result)
        for x in 0..<width {
            XCTAssertEqual(boundary[x], horizonY - 20,
                           "column \(x): the envelope is the highest warped ground " +
                           "over all neighbours")
        }
    }

    func testUncoveredWarpBorderImposesNoConstraint() throws {
        // A horizontal shift wider than the image: the warped neighbour covers no
        // destination pixel at all.  In the merge such a neighbour offers no sample
        // anywhere (zeros are "no data"), so it cannot contaminate the sky and the
        // mask must come back unchanged — this is what the white border fill is for.
        let mask = flatMask()
        let result = try XCTUnwrap(
          StarAlignedHorizonMask.compute(
            from: mask,
            homographies: [translation(tx: Double(width) + 50)])
        )
        let boundary = boundary(of: result)
        for x in 0..<width {
            XCTAssertEqual(boundary[x], horizonY,
                           "column \(x): outside a warp's coverage there is nothing " +
                           "to keep out of the sky")
        }
    }

    func testARotationRaisesOnlyTheRisingSide() throws {
        // Rotate about the image centre: one end of the horizon rises, the other
        // sinks.  This is the case a single scalar shift can never get right — the
        // rising side needs the full displacement, the sinking side needs none.
        let cx = Double(width) / 2
        let cy = Double(height) / 2
        let theta = 0.1
        let c = cos(theta), s = sin(theta)
        let rotation = [c, -s, cx - c*cx + s*cy,
                        s,  c, cy - s*cx - c*cy,
                        0,  0, 1]

        let mask = flatMask()
        let result = try XCTUnwrap(
          StarAlignedHorizonMask.compute(from: mask, homographies: [rotation])
        )
        let boundary = boundary(of: result)

        let left = try XCTUnwrap(boundary[10])
        XCTAssertLessThan(left, horizonY,
                          "the side the rotation lifts must lose sky")
        XCTAssertEqual(try XCTUnwrap(boundary[190]), horizonY,
                       "the side the rotation lowers keeps the base horizon")
    }

    func testAnIdentityWarpChangesNothing() throws {
        let mask = flatMask()
        let result = try XCTUnwrap(
          StarAlignedHorizonMask.compute(from: mask,
                                         homographies: [translation()])
        )
        let boundary = boundary(of: result)
        for x in 0..<width {
            XCTAssertEqual(boundary[x], horizonY)
        }
    }

    // MARK: - The cache

    func testNoHomographiesMeansTheSameMaskBack() async throws {
        let cache = StarAlignedHorizonMaskCache()
        let mask = flatMask()
        let result = await cache.mask(from: mask, homographies: [])
        XCTAssertTrue(result === mask,
                      "with nothing warped into the merge there is nothing to " +
                      "compute, not even a copy")
        let stats = await cache.stats()
        XCTAssertEqual(stats.computes, 0)
    }

    func testTheSlotServesRepeatLookups() async throws {
        let cache = StarAlignedHorizonMaskCache()
        let mask = flatMask()
        let homographies = [translation(ty: -20)]

        let firstResult = await cache.mask(from: mask, homographies: homographies)
        let secondResult = await cache.mask(from: mask, homographies: homographies)
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)
        XCTAssertTrue(first === second, "the second ask is the static-sequence case " +
                                        "and must be served from the slot")

        // The composite path re-wraps the shared reference mask's mat in a fresh
        // PixelatedImage per frame, so a hit must not depend on instance identity.
        let rewrapped = try XCTUnwrap(PixelatedImage(mat: mask.mat))
        let thirdResult = await cache.mask(from: rewrapped, homographies: homographies)
        let third = try XCTUnwrap(thirdResult)
        XCTAssertTrue(first === third)

        let stats = await cache.stats()
        XCTAssertEqual(stats.computes, 1)
        XCTAssertEqual(stats.hits, 2)
    }

    func testADifferentHomographySetRecomputes() async throws {
        let cache = StarAlignedHorizonMaskCache()
        let mask = flatMask()

        let interiorResult = await cache.mask(from: mask, homographies: [translation(ty: -20)])
        let edgeResult = await cache.mask(from: mask, homographies: [translation(ty: -10)])
        let interior = try XCTUnwrap(interiorResult)
        let edge = try XCTUnwrap(edgeResult)
        XCTAssertFalse(interior === edge)
        XCTAssertEqual(boundary(of: interior)[50], horizonY - 20)
        XCTAssertEqual(boundary(of: edge)[50], horizonY - 10)

        let stats = await cache.stats()
        XCTAssertEqual(stats.computes, 2)
    }

    func testADifferentMaskRecomputes() async throws {
        let cache = StarAlignedHorizonMaskCache()
        let homographies = [translation(ty: -20)]

        let firstResult = await cache.mask(from: flatMask(), homographies: homographies)
        let movedResult = await cache.mask(from: flatMask(at: horizonY + 10), homographies: homographies)
        let first = try XCTUnwrap(firstResult)
        let moved = try XCTUnwrap(movedResult)
        XCTAssertFalse(first === moved,
                       "a mask with a different horizon must not be answered " +
                       "from the other mask's slot")
        XCTAssertEqual(boundary(of: moved)[50], horizonY + 10 - 20)
    }
}
