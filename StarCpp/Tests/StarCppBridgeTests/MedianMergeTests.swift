import XCTest
@testable import StarCppBridge

/// Coverage for the median-merge kernel that builds every star-aligned frame.
///
/// The bug these were written for: `warpPerspective` fills everything outside a warped
/// neighbour with BORDER_CONSTANT 0, so near the edges of a frame some neighbours have no
/// sample at that position.  The first and last few frames of a sequence have neighbours on
/// one side only, so every one of their warps uncovers the *same* edge, and in that strip
/// most of the sources are zero.  The kernel used to fold those zeros into the mean and
/// deviation it derives its outlier threshold from, which dragged the mean down far enough
/// that the base frame's own real value was rejected as a bright outlier — and the index it
/// then selected landed back inside the run of zeros.  The result was a black border a few
/// pixels wide down one side of the first and last frames of every sequence.
final class MedianMergeTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MedianMergeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        // Without this every filename source loads as nothing and the merge quietly runs
        // on the base frame alone — which returns the base value and makes most of these
        // tests pass for the wrong reason.  `assertSourcesLoad` below is the guard against
        // that going unnoticed again.
        ImageCache.setLoader { MatWrapper.load(fromFilename: $0) }
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - helpers

    /// star's default `Config.pixelThreshold`.  The failure is threshold-dependent — it
    /// needs a value low enough that a lone real sample among zeros reads as an outlier —
    /// so the shipped default is the one worth pinning.
    private static let defaultPixelThreshold = 1.2

    private let width = 16
    private let height = 4

    /// A 16-bit single-channel Mat built from `value(x, y)`.
    private func makeMat(_ value: (Int, Int) -> UInt16) -> MatWrapper {
        makeMat(width: width, height: height, value)
    }

    /// The same, at an explicit size — the width is what decides how a row is split
    /// between the kernel's two paths, so some tests need to vary it.
    private func makeMat(width: Int, height: Int,
                         _ value: (Int, Int) -> UInt16) -> MatWrapper {
        let count = width * height
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: count)
        for y in 0..<height {
            for x in 0..<width { data[y * width + x] = value(x, y) }
        }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 16, componentsPerPixel: 1),
                          bytesPerRow: width * MemoryLayout<UInt16>.size,
                          data: UnsafeMutableRawPointer(data),
                          takeOwnership: true)
    }

    /// Writes `mat` into the scratch directory and returns the path, so it can be handed to
    /// the merge as one of its filename sources.
    private func write(_ mat: MatWrapper, named name: String) throws -> String {
        let path = scratch.appendingPathComponent("\(name).tiff").path
        XCTAssertTrue(mat.write(to: path), "could not write \(path)")
        return path
    }

    /// Every merge below is only as good as its sources actually reaching the kernel, and a
    /// source that fails to load is dropped silently rather than reported.  Check.
    private func assertSourcesLoad(_ filenames: [String],
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        for filename in filenames {
            let loaded = try XCTUnwrap(ImageCache.load(filename),
                                       "\(filename) did not load", file: file, line: line)
            XCTAssertEqual(loaded.cols, width, file: file, line: line)
            XCTAssertEqual(loaded.rows, height, file: file, line: line)
            XCTAssertEqual(loaded.channels, 1, file: file, line: line)
        }
    }

    private func samples(of mat: MatWrapper) throws -> [[UInt16]] {
        let base = try XCTUnwrap(mat.dataPtr)
        let step = mat.step
        return (0..<mat.rows).map { y in
            let row = base.advanced(by: y * step).assumingMemoryBound(to: UInt16.self)
            return (0..<mat.cols).map { row[$0] }
        }
    }

    // MARK: - tests

    /// Neighbours that miss part of the frame, expressed the only way that now says so:
    /// by warping them.
    ///
    /// These three tests are about what the merge does where few of its sources reached,
    /// and they used to say "did not reach" by writing a zero into an *unwarped* source.
    /// That worked while the kernel read coverage off the pixel values, and it stopped
    /// meaning anything when coverage moved into a plane of its own: through
    /// `medianMergeImage`, which warps nothing, a zero is now a source that is black,
    /// not a source that is absent.  Warping is what puts a hole in a source, so these
    /// go through the aligned merge and let it build the plane from the same
    /// `warpPerspective` call it warps the pixels with.
    ///
    /// `dst(x, y) = src(x - tx, y)`, so a negative `tx` slides a source left and leaves
    /// the rightmost `-tx` columns of the frame uncovered; `tx >= width` uncovers all of
    /// it.
    private func translation(x tx: Int) -> MatWrapper {
        MatWrapper(homographyValues: [1, 0, Double(tx),
                                      0, 1, 0,
                                      0, 0, 1])
    }

    /// Merge `base` against neighbours holding `values`, each warped by its own
    /// translation.  Neighbour indices start at 1 so the homography key, which is the
    /// offset from `baseFrameIndex` 0, is the neighbour's own index.
    private func alignedMerge(base: MatWrapper,
                              neighbours: [(value: (Int, Int) -> UInt16, shiftX: Int)],
                              named prefix: String) throws -> MatWrapper {
        var infos: [AlignmentNeighborInfo] = []
        var homography: [Int: MatWrapper] = [:]
        for (k, neighbour) in neighbours.enumerated() {
            let filename = try write(makeMat(neighbour.value), named: "\(prefix)-\(k)")
            infos.append(AlignmentNeighborInfo(filename: filename, maskFilename: nil,
                                               keypoints: nil, frameIndex: Int32(k + 1)))
            homography[k + 1] = translation(x: neighbour.shiftX)
        }
        try assertSourcesLoad(infos.map(\.filename))
        let result = try XCTUnwrap(ImageAligner.alignAndMedianMerge(
          baseImage: base, baseFrameIndex: 0,
          neighbors: infos, homography: homography,
          outlierThreshold: Self.defaultPixelThreshold, includeAll: false,
          loadConcurrency: 1))
        XCTAssertEqual(result.warpCount, neighbours.count,
                       "every neighbour has a homography and should have been warped")
        return result.merged
    }

    /// The shipped failure, at the geometry that produced it: a base frame plus eight
    /// aligned neighbours, where neighbour *k* has no data in the rightmost `2 * (k + 1)`
    /// columns.  Column 15 is covered by the base alone, column 0 by everything.  No output
    /// pixel may be black, because every column has at least the base frame's sample.
    func testEdgeColumnsCoveredByOnlyTheBaseFrameAreNotBlack() throws {
        let level: UInt16 = 30000
        let merged = try alignedMerge(
          base: makeMat { _, _ in level },
          neighbours: (0..<8).map { k in ({ _, _ in level }, -2 * (k + 1)) },
          named: "neighbour")

        for (y, row) in try samples(of: merged).enumerated() {
            for (x, value) in row.enumerated() {
                XCTAssertEqual(value, level,
                               "pixel (\(x), \(y)) merged to \(value); " +
                               "\(1 + (0..<8).filter { x < width - 2 * ($0 + 1) }.count) " +
                               "of 9 sources had data there")
            }
        }
    }

    /// The same shape one source at a time: with `n` of the nine sources reaching a pixel
    /// and the rest warped away from it, the merge has to return their value for every
    /// `n >= 1`.  The old kernel returned it only for `n >= 4`.
    func testASingleCoveredSourceStillDecidesThePixel() throws {
        let level: UInt16 = 30000

        for covered in 1...9 {
            let merged = try alignedMerge(
              base: makeMat { _, _ in level },
              // neighbours 0 ..< covered - 1 land on the frame, the rest are warped
              // clear of it entirely
              neighbours: (0..<8).map { k in
                  ({ _, _ in level }, k < covered - 1 ? 0 : self.width)
              },
              named: "n-\(covered)")

            let values = Set(try samples(of: merged).flatMap { $0 })
            XCTAssertEqual(values, [level],
                           "with \(covered) of 9 sources covered the merge produced \(values.sorted())")
        }
    }

    /// A position no source covered has no honest answer but zero, and must stay zero —
    /// this is what the caller's "ignore it" behaviour is built on.
    func testAPositionNoSourceCoveredStaysZero() throws {
        let base = makeMat { _, _ in 0 }
        let filenames = try (0..<3).map { try write(makeMat { _, _ in 0 }, named: "empty-\($0)") }

        try assertSourcesLoad(filenames)
        let merged = ImageAligner.medianMergeImage(base, withFilenames: filenames,
                                                   outlierThreshold: Self.defaultPixelThreshold,
                                                   includeAll: false)
        XCTAssertEqual(Set(try samples(of: merged).flatMap { $0 }), [0])
    }

    /// Leaving the sources that did not reach a pixel out of the statistics must not cost
    /// the kernel its actual job.  Here one neighbour carries an airplane trail — far
    /// brighter than the rest — and the columns to the right are reached by fewer and
    /// fewer sources.  The trail has to be rejected everywhere, including where only it
    /// and the base are present, which is the thinnest evidence the kernel can be asked
    /// to reject on.
    func testABrightTrailIsRejectedEvenWhereCoverageIsThin() throws {
        let sky: UInt16 = 12000
        let trail: UInt16 = 60000
        let merged = try alignedMerge(
          base: makeMat { _, _ in sky },
          // neighbour 0 is the one carrying the trail, and it reaches furthest right
          neighbours: (0..<8).map { k in
              ({ _, _ in k == 0 ? trail : sky }, -2 * (k + 1))
          },
          named: "trail")

        for (y, row) in try samples(of: merged).enumerated() {
            for (x, value) in row.enumerated() {
                XCTAssertEqual(value, sky, "pixel (\(x), \(y)) kept \(value)")
            }
        }
    }

    /// The other half of the same bug, one level up.  A warp does not end at a clean edge:
    /// INTER_LINEAR blends the outermost real pixel with the border value just past it, so
    /// the boundary comes back as a fringe at a fraction of its true brightness.  That
    /// fringe is not zero, so nothing downstream can tell it from data, and since it is
    /// darker than the sky around it the merge prefers it — a dim line down the edge.
    ///
    /// A single neighbour shifted by a fractional 5.5px, darker than the base everywhere,
    /// makes that visible: the merge takes the neighbour's value where the neighbour
    /// reaches and the base's where it does not, so every output pixel has to be exactly
    /// one or the other.  Anything in between is fringe that survived.
    func testTheInterpolatedEdgeOfAWarpIsNotTreatedAsData() throws {
        let baseLevel: UInt16 = 30000
        let neighbourLevel: UInt16 = 20000

        let base = makeMat { _, _ in baseLevel }
        let neighbour = makeMat { _, _ in neighbourLevel }
        let path = try write(neighbour, named: "shifted")
        try assertSourcesLoad([path])

        let merged = try XCTUnwrap(ImageAligner.alignAndMedianMerge(
          baseImage: base, baseFrameIndex: 0,
          neighbors: [AlignmentNeighborInfo(filename: path, maskFilename: nil,
                                            keypoints: nil, frameIndex: 1)],
          // pure translation, deliberately not a whole pixel — a whole-pixel shift has no
          // interpolation to do and would not produce a fringe at all
          homography: [1: MatWrapper(homographyValues: [1, 0, -5.5,
                                                        0, 1, 0,
                                                        0, 0, 1])],
          outlierThreshold: Self.defaultPixelThreshold, includeAll: false))
        XCTAssertEqual(merged.warpCount, 1)

        let rows = try samples(of: merged.merged)
        XCTAssertEqual(Set(rows.flatMap { $0 }), [baseLevel, neighbourLevel],
                       "row 0 came out as \(rows[0])")
        // and the two regions have to be the right way round: the neighbour covers the
        // left of the frame and is uncovered on the right, where it was shifted from
        XCTAssertEqual(rows[0].first, neighbourLevel)
        XCTAssertEqual(rows[0].last, baseLevel)
    }

    /// The interior of a frame — where every source has data — has to come through the fix
    /// unchanged, since that is all but a few columns of every frame in a sequence.  With no
    /// zeros present the leading-zero scan finds nothing and the statistics run over the
    /// whole set exactly as they always did, so the selection is untouched: `10100`, the
    /// midpoint of the samples left after the outlier cut, whether or not the top sample is
    /// an airplane trail.  (Pinned exhaustively offline too — 200k random zero-free inputs
    /// across both `includeAll` modes gave identical results before and after.)
    func testAFullyCoveredPixelIsUnaffected() throws {
        for levels: [UInt16] in [[10000, 10100, 10200, 10300, 10400],
                                 [10000, 10100, 10200, 10300, 60000]] {
            let base = makeMat { _, _ in levels[0] }
            let filenames = try levels.dropFirst().enumerated().map { offset, level in
                try write(makeMat { _, _ in level }, named: "level-\(level)-\(offset)")
            }

            try assertSourcesLoad(filenames)
            let merged = ImageAligner.medianMergeImage(base, withFilenames: filenames,
                                                       outlierThreshold: Self.defaultPixelThreshold,
                                                       includeAll: false)
            XCTAssertEqual(Set(try samples(of: merged).flatMap { $0 }), [10100],
                           "merging \(levels)")
        }
    }

    /// The kernel merges a fixed-width block of pixel-channels at a time and handles
    /// whatever is left of a row one pixel at a time, so a row is split between two code
    /// paths at an offset that depends only on the frame's width.  A pixel's value must
    /// not depend on which side of that split it lands on.
    ///
    /// This walks the same nine sources across every width from 1 to 40 — widths below,
    /// at, and either side of the block width, so each column in turn is a block pixel in
    /// one run and a leftover in another — and requires column `x` to merge to the same
    /// value every time.  The column data is chosen to exercise the parts of the
    /// selection that the two paths implement differently: how many sources are zero
    /// varies by column, so `first`, the deviation and the outlier cut all move with `x`.
    func testAPixelMergesTheSameWhereverTheBlockBoundaryFalls() throws {
        let height = 3
        let sources = 9

        // column x has (x % 5) of its eight neighbours warped out, and one bright sample
        // every third column, so neither the zero count nor the outlier cut is constant
        func level(_ x: Int, _ source: Int) -> UInt16 {
            if source > 0, source <= x % 5 { return 0 }
            if source == 1, x % 3 == 0 { return 60000 }
            return UInt16(10000 + 100 * source + 7 * (x % 11))
        }

        var mergedByWidth: [Int: [Int: UInt16]] = [:]   // width -> column -> value

        for width in 1...40 {
            let base = makeMat(width: width, height: height) { x, _ in level(x, 0) }
            let filenames = try (1..<sources).map { source in
                try write(makeMat(width: width, height: height) { x, _ in level(x, source) },
                          named: "boundary-\(width)-\(source)")
            }
            let merged = ImageAligner.medianMergeImage(base, withFilenames: filenames,
                                                       outlierThreshold: Self.defaultPixelThreshold,
                                                       includeAll: false)
            let rows = try samples(of: merged)
            XCTAssertEqual(rows.count, height)
            XCTAssertEqual(rows[0].count, width, "width \(width) came back \(rows[0].count) wide")
            // every row is identical by construction, so one is enough to compare across
            for row in rows {
                XCTAssertEqual(row, rows[0], "rows disagree at width \(width)")
            }
            mergedByWidth[width] = Dictionary(uniqueKeysWithValues: rows[0].enumerated().map { ($0, $1) })
        }

        // the widest run is the reference: every narrower one has to agree with it column
        // for column, which it can only do if both paths decide a pixel the same way
        let reference = try XCTUnwrap(mergedByWidth[40])
        for width in 1...39 {
            let row = try XCTUnwrap(mergedByWidth[width])
            for x in 0..<width {
                XCTAssertEqual(row[x], reference[x],
                               "column \(x) merged to \(row[x] as Any) at width \(width) " +
                               "but \(reference[x] as Any) at width 40")
            }
        }
    }

    // MARK: - loading several sources at once

    /// Nine levels, one per source, arranged so that losing or duplicating any single
    /// source is visible in the output.
    ///
    /// The merge sorts each pixel's samples before it uses them, so source *order* never
    /// reaches the answer — which means a test that only compares one concurrency against
    /// another cannot see a source going missing, as long as it goes missing every time.
    /// What does reach the answer is the multiset. Modelled against the kernel:
    ///
    ///   - all nine levels merge to 11000;
    ///   - removing any of 0, 10000, 10500 or 11000 gives 11500 instead;
    ///   - a second copy of 11500, 12000, 12500 or 13000 gives 11500 instead.
    ///
    /// Source `s` carries `levels[(s + x) % 9]` in column `x`, so over nine or more
    /// columns every source carries every level somewhere. Losing source `s` therefore
    /// removes a sensitive level in some column, and duplicating it adds one — either way
    /// at least one column moves off 11000. Every column sees the same nine levels, so
    /// the correct answer is 11000 everywhere, which makes the assertion a single value.
    ///
    /// The level of 0 is a source that is black here, not a source that is absent.  These
    /// merges warp nothing, so every source covers every pixel and a zero is an
    /// observation like any other — which is why the answer is 11000 and not the 11500
    /// this expected until the kernel stopped reading coverage off the pixel values.
    /// Keeping the 0 in the set is what pins that.
    private static let concurrencyLevels: [UInt16] =
      [0, 10000, 10500, 11000, 11500, 12000, 12500, 13000, 60000]
    private static let concurrencyExpected: UInt16 = 11000
    /// What the merge produces when the multiset is one source short or one source long.
    private static let concurrencyPerturbed: UInt16 = 11500

    private func concurrencyLevel(source: Int, column: Int) -> UInt16 {
        let levels = Self.concurrencyLevels
        return levels[(source + column) % levels.count]
    }

    /// Sources 1...8 as files; source 0 is the base image the caller passes separately.
    private func writeConcurrencySources(prefix: String) throws -> [String] {
        try (1..<Self.concurrencyLevels.count).map { source in
            try write(makeMat { x, _ in concurrencyLevel(source: source, column: x) },
                      named: "\(prefix)-\(source)")
        }
    }

    private func concurrencyBase() -> MatWrapper {
        makeMat { x, _ in concurrencyLevel(source: 0, column: x) }
    }

    /// A merge decodes several of its sources at once, and what it produces must not
    /// depend on how many were in flight — nor may a source be lost or duplicated on the
    /// way, which is the failure mode of handing the loop to a thread pool.
    func testTheResultDoesNotDependOnHowManySourcesLoadAtOnce() throws {
        let filenames = try writeConcurrencySources(prefix: "conc")
        try assertSourcesLoad(filenames)

        for concurrency in [1, 2, 3, 4, 8, 32] {
            let merged = ImageAligner.medianMergeImage(
              concurrencyBase(), withFilenames: filenames,
              outlierThreshold: Self.defaultPixelThreshold,
              includeAll: false,
              loadConcurrency: concurrency)
            XCTAssertEqual(Set(try samples(of: merged).flatMap { $0 }),
                           [Self.concurrencyExpected],
                           "merging with \(concurrency) sources in flight did not merge "
                           + "all nine levels")
        }
    }

    /// And the assertion above has teeth: hand the same merge one source too few, and then
    /// one too many, and it has to notice. Without this the test would keep passing if the
    /// pool silently dropped or repeated a source every time.
    func testAMergeMissingOrRepeatingASourceIsVisible() throws {
        let filenames = try writeConcurrencySources(prefix: "sensitivity")
        try assertSourcesLoad(filenames)

        let complete = ImageAligner.medianMergeImage(
          concurrencyBase(), withFilenames: filenames,
          outlierThreshold: Self.defaultPixelThreshold, includeAll: false,
          loadConcurrency: 4)
        XCTAssertEqual(Set(try samples(of: complete).flatMap { $0 }), [Self.concurrencyExpected])

        for dropped in filenames.indices {
            var short = filenames
            short.remove(at: dropped)
            let merged = ImageAligner.medianMergeImage(
              concurrencyBase(), withFilenames: short,
              outlierThreshold: Self.defaultPixelThreshold, includeAll: false,
              loadConcurrency: 4)
            let values = Set(try samples(of: merged).flatMap { $0 })
            XCTAssertTrue(values.contains(Self.concurrencyPerturbed),
                          "dropping source \(dropped + 1) left every column at "
                          + "\(values.sorted()), so a lost source would not be noticed")
        }

        for repeated in filenames.indices {
            let long = filenames + [filenames[repeated]]
            let merged = ImageAligner.medianMergeImage(
              concurrencyBase(), withFilenames: long,
              outlierThreshold: Self.defaultPixelThreshold, includeAll: false,
              loadConcurrency: 4)
            let values = Set(try samples(of: merged).flatMap { $0 })
            XCTAssertTrue(values.contains(Self.concurrencyPerturbed),
                          "repeating source \(repeated + 1) left every column at "
                          + "\(values.sorted()), so a duplicated source would not be noticed")
        }
    }

    /// The aligned merge loads *and warps* concurrently, and reports how many neighbours
    /// it managed to warp — a count the caller reads as "fall back to the unaligned frame"
    /// when it is zero, so it has to be right whatever the worker count.
    ///
    /// The homographies are all identity, so the same nine levels reach the kernel as
    /// above and the answer is again 11500 in every column: this is testing the pool's
    /// bookkeeping, not the warp, which the tests above already cover.
    func testTheAlignedMergeAgreesWithItselfAtEveryConcurrency() throws {
        let filenames = try writeConcurrencySources(prefix: "aligned-conc")
        try assertSourcesLoad(filenames)

        var neighbors: [AlignmentNeighborInfo] = []
        var homography: [Int: MatWrapper] = [:]
        for (offset, filename) in filenames.enumerated() {
            let frameIndex = offset + 1
            neighbors.append(AlignmentNeighborInfo(filename: filename, maskFilename: nil,
                                                   keypoints: nil, frameIndex: Int32(frameIndex)))
            homography[frameIndex] = MatWrapper(homographyValues: [1, 0, 0,
                                                                   0, 1, 0,
                                                                   0, 0, 1])
        }

        for concurrency in [1, 2, 3, 6, 16] {
            let result = try XCTUnwrap(ImageAligner.alignAndMedianMerge(
              baseImage: concurrencyBase(), baseFrameIndex: 0,
              neighbors: neighbors, homography: homography,
              outlierThreshold: Self.defaultPixelThreshold, includeAll: false,
              loadConcurrency: concurrency))
            XCTAssertEqual(result.warpCount, neighbors.count,
                           "concurrency \(concurrency) warped \(result.warpCount) of "
                           + "\(neighbors.count) neighbours")
            XCTAssertEqual(Set(try samples(of: result.merged).flatMap { $0 }),
                           [Self.concurrencyExpected],
                           "concurrency \(concurrency) did not merge all nine levels")
        }
    }
}
