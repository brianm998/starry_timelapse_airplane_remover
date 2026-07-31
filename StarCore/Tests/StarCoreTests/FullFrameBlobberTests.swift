import XCTest
import StarCppBridge
@testable import StarCore

/// `FullFrameBlobber` is the first real step of outlier detection: it takes the subtraction image —
/// this frame minus an aligned neighbour — and groups the pixels that changed into blobs.  Every
/// airplane trail star finds starts life as a blob here, so its behaviour is the foundation the rest
/// of the pipeline stands on.  419 lines, none of it covered.
///
/// Driven directly rather than through `BlobFinder`, which needs a whole `FrameAirplaneRemover`.
final class FullFrameBlobberTests: XCTestCase {

    /// The args the real `StrongBlobProcessor` uses, so the thresholds under test are the ones that
    /// ship rather than something invented here.
    private func strongArgs() -> BlobFinder.Args {
        BlobFinder.Args(minPixelIntensity: 6000,
                        startContrastSize: 10,
                        endContrastSize: 100,
                        startMinContrast: 30,
                        endMinContrast: 5)
    }

    /// A blobber over a synthetic subtraction image.  `subtractionPixelData` is row-major and must
    /// be exactly width*height — the initializer `fatalError`s otherwise, which is worth knowing
    /// before building one of these.
    private func blobber(width: Int, height: Int,
                         args: BlobFinder.Args? = nil,
                         neighborType: FullFrameBlobber.NeighborType = .eight,
                         value: (Int, Int) -> UInt16) async -> FullFrameBlobber
    {
        var subtraction = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { subtraction[y * width + x] = value(x, y) }
        }

        // the blobber keeps the original image only to read brightnesses from, so a matching
        // single channel image is enough
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: width * height)
        for i in 0..<(width * height) { data[i] = subtraction[i] }
        let mat = MatWrapper(width: width, height: height,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 16,
                                                       componentsPerPixel: 1),
                             bytesPerRow: width * 2,
                             data: UnsafeMutableRawPointer(data),
                             takeOwnership: true)

        return await FullFrameBlobber(config: Config(),
                                      args: args ?? strongArgs(),
                                      imageWidth: width,
                                      imageHeight: height,
                                      subtractionPixelData: subtraction,
                                      originalImage: PixelatedImage(mat: mat)!,
                                      frameIndex: 0,
                                      neighborType: neighborType)
    }

    private func run(_ blobber: FullFrameBlobber) async -> [Blob] {
        blobber.sortPixels()
        await blobber.process()
        return blobber.blobs
    }

    // MARK: - what gets picked up at all

    /// A subtraction image with nothing in it produces no blobs.  If this ever found something, the
    /// whole pipeline would be chasing noise on every frame.
    func testAnEmptySubtractionImageFindsNothing() async {
        let blobs = await run(await blobber(width: 32, height: 32) { _, _ in 0 })
        XCTAssertTrue(blobs.isEmpty, "found \(blobs.count) blobs in a blank frame")
    }

    /// Pixels below `minPixelIntensity` cannot start a blob — that threshold is what keeps sensor
    /// noise out.
    func testPixelsBelowTheIntensityThresholdAreIgnored() async {
        // 5999 is just under the strong processor's 6000
        let blobs = await run(await blobber(width: 32, height: 32) { x, y in
            (10...14).contains(x) && y == 10 ? 5999 : 0
        })
        XCTAssertTrue(blobs.isEmpty, "a streak below the threshold should not blob")
    }

    func testPixelsAboveTheIntensityThresholdAreFound() async {
        let blobs = await run(await blobber(width: 32, height: 32) { x, y in
            (10...14).contains(x) && y == 10 ? 20000 : 0
        })
        XCTAssertFalse(blobs.isEmpty, "a bright streak should produce a blob")
    }

    /// The headline behaviour: one bright streak becomes one blob holding its pixels.
    func testABrightStreakBecomesOneBlob() async {
        let blobs = await run(await blobber(width: 40, height: 40) { x, y in
            (10...19).contains(x) && y == 20 ? 30000 : 0
        })

        XCTAssertEqual(blobs.count, 1, "one streak should be one blob, got \(blobs.count)")
        guard let blob = blobs.first else { return }

        let pixels = await blob.pixels
        XCTAssertEqual(pixels.count, 10, "the blob should hold all ten lit pixels")
        XCTAssertEqual(Set(pixels.map(\.y)), [20], "all on one row")
        XCTAssertEqual(Set(pixels.map(\.x)), Set(10...19))
    }

    /// Two streaks far apart stay separate — the blobber must not join unrelated signal.
    func testTwoDistantStreaksBecomeTwoBlobs() async {
        let blobs = await run(await blobber(width: 64, height: 64) { x, y in
            ((5...9).contains(x) && y == 10) || ((50...54).contains(x) && y == 50) ? 30000 : 0
        })
        XCTAssertEqual(blobs.count, 2, "got \(blobs.count)")
    }

    /// Eight-way connectivity is what the production path uses, so a diagonal run is one blob.
    func testADiagonalRunIsOneBlobUnderEightWayConnectivity() async {
        let blobs = await run(await blobber(width: 40, height: 40, neighborType: .eight) { x, y in
            (5...14).contains(x) && y == x ? 30000 : 0
        })
        XCTAssertEqual(blobs.count, 1, "a diagonal should hold together, got \(blobs.count)")
        let pixels = await blobs.first?.pixels
        XCTAssertEqual(pixels?.count, 10)
    }

    /// Under four-way connectivity the same diagonal falls apart, which is the difference between
    /// the two modes.
    func testADiagonalRunFragmentsUnderFourWayConnectivity() async {
        let blobs = await run(await blobber(width: 40, height: 40,
                                           neighborType: .fourCardinal) { x, y in
            (5...14).contains(x) && y == x ? 30000 : 0
        })
        XCTAssertGreaterThan(blobs.count, 1,
                             "four way connectivity should not bridge a diagonal")
    }

    func testASolidBlockIsOneBlob() async {
        let blobs = await run(await blobber(width: 40, height: 40) { x, y in
            (10...19).contains(x) && (10...19).contains(y) ? 30000 : 0
        })
        XCTAssertEqual(blobs.count, 1)
        let pixels = await blobs.first?.pixels
        XCTAssertEqual(pixels?.count, 100)
    }

    // MARK: - blob identity

    /// Blob ids have to be unique and non-zero: zero means "no blob" in the id image the connector
    /// reads, so a blob with id 0 would be invisible to it.
    func testEveryBlobGetsAUniqueNonZeroId() async {
        let blobs = await run(await blobber(width: 64, height: 64) { x, y in
            // four separated dots
            ((x == 5 && y == 5) || (x == 30 && y == 5) ||
             (x == 5 && y == 30) || (x == 30 && y == 30)) ? 30000 : 0
        })

        XCTAssertEqual(blobs.count, 4)
        let ids = blobs.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "blob ids collided: \(ids)")
        for id in ids { XCTAssertGreaterThan(id, 0, "zero means no blob") }
    }

    /// The starting id is configurable so a second blobbing pass can continue where the first left
    /// off rather than reusing ids that are already spoken for.
    func testTheStartingIdIsHonoured() async {
        var subtraction = [UInt16](repeating: 0, count: 32 * 32)
        subtraction[10 * 32 + 10] = 30000

        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: 32 * 32)
        for i in 0..<(32 * 32) { data[i] = subtraction[i] }
        let mat = MatWrapper(width: 32, height: 32,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 16,
                                                       componentsPerPixel: 1),
                             bytesPerRow: 32 * 2,
                             data: UnsafeMutableRawPointer(data), takeOwnership: true)

        let blobber = await FullFrameBlobber(config: Config(), args: strongArgs(),
                                            imageWidth: 32, imageHeight: 32,
                                            subtractionPixelData: subtraction,
                                            originalImage: PixelatedImage(mat: mat)!,
                                            frameIndex: 0, neighborType: .eight,
                                            startingBlobID: 500)
        let blobs = await run(blobber)

        XCTAssertEqual(blobs.count, 1)
        XCTAssertGreaterThanOrEqual(blobs.first?.id ?? 0, 500,
                                    "ids should start from where they were told to")
    }

    /// `blobMap` is how every later stage looks a blob up by the id in the label image, so it has to
    /// agree with the blob list.
    func testTheBlobMapIsKeyedByEachBlobsOwnId() async {
        let blobber = await blobber(width: 64, height: 64) { x, y in
            ((x == 5 && y == 5) || (x == 30 && y == 30) || (x == 50 && y == 10)) ? 30000 : 0
        }
        let blobs = await run(blobber)
        let map = blobber.blobMap

        XCTAssertEqual(map.count, blobs.count)
        for blob in blobs {
            XCTAssertNotNil(map[blob.id], "blob \(blob.id) is missing from the map")
            XCTAssertEqual(map[blob.id]?.id, blob.id)
        }
    }

    // MARK: - sorting

    /// The blobber grows blobs outward from the brightest pixels, so the sort has to put them first.
    /// Getting it backwards would seed every blob from its dimmest edge.
    func testPixelsAreSortedBrightestFirst() async {
        let blobber = await blobber(width: 16, height: 16) { x, y in
            y == 8 ? UInt16(7000 + x * 1000) : 0
        }
        blobber.sortPixels()

        let intensities = blobber.sortedPixels.map(\.intensity)
        XCTAssertFalse(intensities.isEmpty)
        XCTAssertEqual(intensities, intensities.sorted(by: >),
                       "sortPixels should order brightest first")
    }

    /// Only pixels the blobber could actually use are kept — anything under the intensity threshold
    /// is not worth carrying through the sort.
    func testTheSortOnlyKeepsPixelsWorthConsidering() async {
        let blobber = await blobber(width: 16, height: 16) { x, y in
            y == 8 ? (x < 8 ? 100 : 30000) : 0
        }
        blobber.sortPixels()

        for pixel in blobber.sortedPixels {
            XCTAssertGreaterThanOrEqual(pixel.uInt32Value, 6000,
                                        "a pixel below the threshold reached the sort")
        }
    }

    // MARK: - bounds

    /// The blobber can be restricted to a region, which is how a reprocess only redoes part of a
    /// frame.  Signal outside the region must be left alone.
    func testRestrictingToBoundsIgnoresSignalOutsideIt() async {
        var subtraction = [UInt16](repeating: 0, count: 64 * 64)
        // one dot inside the region, one well outside
        subtraction[10 * 64 + 10] = 30000
        subtraction[50 * 64 + 50] = 30000

        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: 64 * 64)
        for i in 0..<(64 * 64) { data[i] = subtraction[i] }
        let mat = MatWrapper(width: 64, height: 64,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 16,
                                                       componentsPerPixel: 1),
                             bytesPerRow: 64 * 2,
                             data: UnsafeMutableRawPointer(data), takeOwnership: true)

        let blobber = await FullFrameBlobber(
          config: Config(), args: strongArgs(),
          imageWidth: 64, imageHeight: 64,
          within: BoundingBox(min: Coord(x: 0, y: 0), max: Coord(x: 31, y: 31)),
          subtractionPixelData: subtraction,
          originalImage: PixelatedImage(mat: mat)!,
          frameIndex: 0, neighborType: .eight)

        let blobs = await run(blobber)
        XCTAssertEqual(blobs.count, 1, "only the dot inside the bounds should blob")

        let pixels = await blobs.first?.pixels ?? []
        for pixel in pixels {
            XCTAssertLessThan(pixel.x, 32)
            XCTAssertLessThan(pixel.y, 32)
        }
    }

    // MARK: - the output image is a visualisation, not a label image

    /// `outputImage` paints each blob with a stepped brightness starting at 0x4FFF and rising by
    /// 0x1000, so blobs can be told apart by eye in a debug image.  It is *not* a blob-id label
    /// image — the ids the connector reads come from `OutlierGroups.outlierImageData` — and reading
    /// a blob id out of this would get a brightness instead.
    func testTheOutputImagePaintsBlobPixelsBrightAndLeavesTheRestBlack() async throws {
        let blobber = await blobber(width: 32, height: 32) { x, y in
            (10...14).contains(x) && y == 10 ? 30000 : 0
        }
        let blobs = await run(blobber)
        let produced = await blobber.outputImage()
        let painted = try XCTUnwrap(produced)

        XCTAssertEqual(painted.width, 32)
        XCTAssertEqual(painted.height, 32)

        guard let blob = blobs.first else { return XCTFail("expected a blob") }
        for pixel in await blob.pixels {
            let value = painted.intensity(atX: pixel.x, andY: pixel.y)
            XCTAssertGreaterThanOrEqual(value, UInt(0x4FFF),
                                        "pixel [\(pixel.x), \(pixel.y)] should be painted bright")
        }

        // a corner nothing reached
        XCTAssertEqual(painted.intensity(atX: 0, andY: 0), 0)
        XCTAssertEqual(painted.intensity(atX: 31, andY: 31), 0)
    }

    /// Consecutive blobs get distinguishable brightnesses, which is the whole point of the stepping.
    func testSeparateBlobsArePaintedDifferentBrightnesses() async throws {
        let blobber = await blobber(width: 64, height: 64) { x, y in
            ((x == 5 && y == 5) || (x == 30 && y == 30) || (x == 50 && y == 10)) ? 30000 : 0
        }
        let blobs = await run(blobber)
        XCTAssertEqual(blobs.count, 3)

        let produced = await blobber.outputImage()
        let painted = try XCTUnwrap(produced)

        var values: Set<UInt> = []
        for blob in blobs {
            for pixel in await blob.pixels {
                values.insert(painted.intensity(atX: pixel.x, andY: pixel.y))
            }
        }
        XCTAssertEqual(values.count, 3, "three blobs should paint three brightnesses: \(values)")
    }

    /// The stepping wraps: 0x4FFF rising by 0x1000 reaches 0xFFFF after eleven blobs and restarts,
    /// so a frame with many blobs reuses brightnesses.  Fine for a debug image, but it means the
    /// value cannot be treated as an identity.
    func testTheOutputBrightnessesWrapOnAFrameWithManyBlobs() async throws {
        // sixteen well separated dots
        let blobber = await blobber(width: 128, height: 128) { x, y in
            (x % 16 == 4) && (y % 16 == 4) && x < 64 && y < 64 ? 30000 : 0
        }
        let blobs = await run(blobber)
        XCTAssertEqual(blobs.count, 16, "expected sixteen dots, got \(blobs.count)")

        let produced = await blobber.outputImage()
        let painted = try XCTUnwrap(produced)

        var values: [UInt] = []
        for blob in blobs {
            for pixel in await blob.pixels {
                values.append(painted.intensity(atX: pixel.x, andY: pixel.y))
            }
        }
        XCTAssertLessThan(Set(values).count, values.count,
                          "with sixteen blobs the brightness should have wrapped and repeated")
    }

    // MARK: - determinism

    /// The blobber walks a sorted pixel list, so the same subtraction image has to give the same
    /// blobs every time — the outlier features derived from them feed the classifier.
    func testTheSameImageBlobsTheSameWayTwice() async {
        func fingerprint() async -> [String] {
            let blobs = await run(await blobber(width: 48, height: 48) { x, y in
                if (5...15).contains(x) && y == 10 { return 30000 }
                if (20...25).contains(x) && y == x { return 25000 }
                if x == 40 && y == 40 { return 40000 }
                return 0
            })
            var out: [String] = []
            for blob in blobs {
                let pixels = await blob.pixels
                out.append(pixels.map { "\($0.x),\($0.y)" }.sorted().joined(separator: " "))
            }
            return out.sorted()
        }

        let first = await fingerprint()
        XCTAssertFalse(first.isEmpty)
        for run in 1...5 {
            let again = await fingerprint()
            XCTAssertEqual(again, first, "run \(run) blobbed differently")
        }
    }
}
