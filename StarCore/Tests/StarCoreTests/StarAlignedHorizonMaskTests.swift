import XCTest
import StarCppBridge
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

    /// A batch of frames that all want the same answer, arriving together, shares one
    /// computation; frames that want different answers each compute — at once, not one behind
    /// the other.
    func testConcurrentAsksForOneAnswerShareItAndDifferentAnswersEachCompute() async throws {
        let cache = StarAlignedHorizonMaskCache()
        let mask = flatMask()
        let same = [translation(ty: -20)]

        let shared = await withTaskGroup(of: PixelatedImage?.self) { group -> [PixelatedImage?] in
            for _ in 0..<6 { group.addTask { await cache.mask(from: mask, homographies: same) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let first = try XCTUnwrap(shared.first ?? nil)
        XCTAssertTrue(shared.allSatisfy { $0 === first }, "every ask got the one computed mask")
        var stats = await cache.stats()
        XCTAssertEqual(stats.computes, 1)
        XCTAssertEqual(stats.hits, 5)

        let different = (1...5).map { [translation(ty: -Double($0))] }
        let results = await withTaskGroup(of: (Int, PixelatedImage?).self) { group -> [(Int, PixelatedImage?)] in
            for (index, set) in different.enumerated() {
                group.addTask { (index, await cache.mask(from: mask, homographies: set)) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        for (index, result) in results {
            XCTAssertEqual(boundary(of: try XCTUnwrap(result))[50], horizonY - (index + 1))
        }
        stats = await cache.stats()
        XCTAssertEqual(stats.computes, 6, "five more, one for each set")
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

    // MARK: - Heap integrity under the crash's workload

    /// The eight homographies a9-2 frame 611 merged (neighbours 607...615 without itself),
    /// read from that run's homography.db.  The perspective terms are small but real, which
    /// is what sends OpenCV down its perspective rather than affine remap path.
    private static let a9_2Frame611: [[Double]] = [
        [1.0061157695666394, 0.004534312649519937, -19.4361104307603, 0.0008506897716432838, 1.0073869571443639, -23.70048637080109, 5.361888957361996e-07, 1.448024701917303e-06, 1],
        [1.00452686189122, 0.003407222597862513, -14.468890599804995, 0.0006117433234070847, 1.005534928853778, -17.762225597145186, 3.898814869079981e-07, 1.0879337552829858e-06, 1],
        [1.0029700864506756, 0.0023144240085680896, -9.603983224422455, 0.0003915592867946989, 1.0036818569947499, -11.8232090042792, 2.5125485417316684e-07, 7.332642208531102e-07, 1],
        [1.0015311536420957, 0.0011215313284047145, -4.791168515219407, 0.00018753683194567305, 1.0017790160917508, -5.85826712325726, 1.3625980590859365e-07, 3.451078508583622e-07, 1],
        [0.9992385575991518, -0.0005182800857452981, 3.237556719839122, -0.00022064826475199124, 0.9982128171170319, 6.290710652583869, -4.23171141701994e-08, -2.749874174137786e-07, 0.9999999999999999],
        [0.9969890649859868, -0.002306370675196633, 9.647704826273554, -0.0004246971470725641, 0.9962672321081697, 11.905148128943901, -2.5814508703315995e-07, -7.439113947493028e-07, 0.9999999999999999],
        [0.9954605025577902, -0.0034386711340025308, 14.410086669829944, -0.0006532689805825064, 0.9944240797279142, 17.89422417691363, -3.951981630384381e-07, -1.1005666360115607e-06, 1],
        [0.993970482316306, -0.0045596651429831376, 19.166951574720876, -0.0008560364501395022, 0.9925829818180378, 23.786276918068495, -5.237311491638077e-07, -1.464084943638238e-06, 1],
    ]

    /// Frame 611's set nudged down by `variant` tenths of a pixel, so every variant is its own
    /// cache key and nothing collapses into a shared computation, as on a moving sequence.
    private static func a9_2Set(variant: Int) -> [[Double]] {
        a9_2Frame611.map { h in
            var h = h
            h[5] += Double(variant) * 0.1
            return h
        }
    }

    private static func bytes(of image: PixelatedImage) -> [UInt8] {
        let count = image.mat.lengthInBytes
        guard let base = image.mat.dataPtr else { return [] }
        return Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self),
                                         count: count))
    }

    private func sixteenBitFrame(width: Int, height: Int, seed: UInt16) -> MatWrapper {
        let count = width * height * 3
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: count)
        for i in 0..<count { data[i] = UInt16(truncatingIfNeeded: i &* 31 &+ Int(seed)) }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 16, componentsPerPixel: 3),
                          bytesPerRow: width * 3 * MemoryLayout<UInt16>.size,
                          data: UnsafeMutableRawPointer(data),
                          takeOwnership: true)
    }

    /// What was running when the 0.12.6 gui aborted on a heap-corruption guard at a9-2 frame
    /// 611: a dozen full-frame star-aligned masks, each eight perspective warps of a
    /// 6000×4000 mask, all on `NativeWork` at once, beside the downscale that saves a frame's
    /// preview (`ImageAccessor.saveInt`), the distance transform behind the feathered horizon,
    /// and warps of 16-bit frames.  Run under `swift test --sanitize=address` and with
    /// `MallocNanoZone=0 MallocGuardEdges=1 MallocScribble=1`; a clean pass also pins that
    /// every concurrent answer is the one a lone computation gives.
    func testConcurrentFullFrameMasksAlongsideOtherNativeWorkKeepTheHeapIntact() async throws {
        guard ProcessInfo.processInfo.physicalMemory >= 16 << 30 else {
            throw XCTSkip("needs memory for a dozen 24MB masks and 16-bit frames in flight")
        }
        let width = 6000, height = 4000
        let wave = (0..<width).map { x in
            Optional(2000 + Int(150 * sin(Double(x) / 400)))
        }
        let mask = try XCTUnwrap(PixelatedImage.fromHorizonColumnY(
          width: width, height: height, columnY: wave))
        let frame = try XCTUnwrap(PixelatedImage(mat: sixteenBitFrame(width: width, height: height,
                                                                    seed: 3)))
        let small = try XCTUnwrap(PixelatedImage(mat: sixteenBitFrame(width: 3000, height: 2000,
                                                                    seed: 9)))

        let masks = 12
        let expected = (0..<masks).map { variant in
            StarAlignedHorizonMask.compute(from: mask, homographies: Self.a9_2Set(variant: variant))
                .map(Self.bytes(of:))
        }
        XCTAssertTrue(expected.allSatisfy { $0 != nil })

        let cache = StarAlignedHorizonMaskCache()
        let rounds = 3
        for _ in 0..<rounds {
            let results = await withTaskGroup(of: (Int, [UInt8]?).self) { group -> [(Int, [UInt8]?)] in
                for variant in 0..<masks {
                    group.addTask {
                        let result = await cache.mask(from: mask,
                                                      homographies: Self.a9_2Set(variant: variant))
                        return (variant, result.map { Self.bytes(of: $0) })
                    }
                }
                for _ in 0..<4 {
                    group.addTask {
                        _ = await NativeWork.run { frame.downScaleTo(width: 1500, height: 1000) }
                        return (-1, nil)
                    }
                    group.addTask {
                        _ = await NativeWork.run { mask.raiseMaskBy(100) }
                        return (-1, nil)
                    }
                    group.addTask {
                        _ = await NativeWork.run { small.warped(with: Self.a9_2Frame611[0]) }
                        return (-1, nil)
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            for (variant, result) in results where variant >= 0 {
                XCTAssertEqual(result, expected[variant],
                               "variant \(variant) differs from the same mask computed alone")
            }
        }
    }
}
