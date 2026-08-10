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

    /// The shipped failure, at the geometry that produced it: a base frame plus eight
    /// aligned neighbours, where neighbour *k* has no data in the rightmost `2 * (k + 1)`
    /// columns.  Column 15 is covered by the base alone, column 0 by everything.  No output
    /// pixel may be black, because every column has at least the base frame's sample.
    func testEdgeColumnsCoveredByOnlyTheBaseFrameAreNotBlack() throws {
        let level: UInt16 = 30000
        let base = makeMat { _, _ in level }

        var filenames: [String] = []
        for k in 0..<8 {
            let blackFrom = width - 2 * (k + 1)
            let neighbour = makeMat { x, _ in x >= blackFrom ? 0 : level }
            filenames.append(try write(neighbour, named: "neighbour-\(k)"))
        }

        try assertSourcesLoad(filenames)
        let merged = ImageAligner.medianMergeImage(base, withFilenames: filenames,
                                                   outlierThreshold: Self.defaultPixelThreshold,
                                                   includeAll: false)
        for (y, row) in try samples(of: merged).enumerated() {
            for (x, value) in row.enumerated() {
                XCTAssertEqual(value, level,
                               "pixel (\(x), \(y)) merged to \(value); " +
                               "\(1 + (0..<8).filter { x < width - 2 * ($0 + 1) }.count) " +
                               "of 9 sources had data there")
            }
        }
    }

    /// The same shape one source at a time: with `n` of the nine sources carrying a real
    /// value and the rest zero, the merge has to return that value for every `n >= 1`.  The
    /// old kernel returned it only for `n >= 4`.
    func testASingleCoveredSourceStillDecidesThePixel(  ) throws {
        let level: UInt16 = 30000

        for covered in 1...9 {
            let base = makeMat { _, _ in level }
            var filenames: [String] = []
            for k in 0..<8 {
                // neighbours 0 ..< covered - 1 have data, the rest are fully warped out
                let hasData = k < covered - 1
                let neighbour = makeMat { _, _ in hasData ? level : 0 }
                filenames.append(try write(neighbour, named: "n-\(covered)-\(k)"))
            }

            try assertSourcesLoad(filenames)
            let merged = ImageAligner.medianMergeImage(base, withFilenames: filenames,
                                                       outlierThreshold: Self.defaultPixelThreshold,
                                                       includeAll: false)
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

    /// Excluding the no-data zeros from the statistics must not cost the kernel its actual
    /// job.  Here one neighbour carries an airplane trail — far brighter than the rest — in
    /// a strip that is also partly uncovered.  The trail has to be rejected everywhere,
    /// including in the columns where most sources are zero, which is exactly where the old
    /// zero-inflated deviation made the threshold too loose to reject anything.
    func testABrightTrailIsRejectedEvenWhereCoverageIsThin() throws {
        let sky: UInt16 = 12000
        let trail: UInt16 = 60000
        let base = makeMat { _, _ in sky }

        var filenames: [String] = []
        for k in 0..<8 {
            let blackFrom = width - 2 * (k + 1)
            // neighbour 0 is the one with the trail across the full width
            let neighbour = makeMat { x, _ in
                if x >= blackFrom { return 0 }
                return k == 0 ? trail : sky
            }
            filenames.append(try write(neighbour, named: "trail-\(k)"))
        }

        try assertSourcesLoad(filenames)
        let merged = ImageAligner.medianMergeImage(base, withFilenames: filenames,
                                                   outlierThreshold: Self.defaultPixelThreshold,
                                                   includeAll: false)
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
}
