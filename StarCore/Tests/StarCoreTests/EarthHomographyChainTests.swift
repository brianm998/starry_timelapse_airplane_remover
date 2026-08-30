import XCTest
import Foundation
@testable import StarCore

/// A moving timelapse's painted reference horizons are only useful to *other* frames if there is a
/// way to say where the ground they were painted on has since moved to.  `EarthHomographyChain`
/// composes the alignment stage's earth homographies to answer that, and `HorizonCurve` carries a
/// horizon line across the answer.
///
/// What these pin is the part that is easy to get subtly wrong and impossible to see: the direction
/// of the composition, which record a link is read out of, and that the widest available hop is
/// preferred — the last of which is worth a factor of two and a half in accuracy on real data and
/// costs nothing to lose silently.
final class EarthHomographyChainTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
          .appendingPathComponent("EarthHomographyChain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - helpers

    /// Row-major translation by (dx, dy).
    private func translation(_ dx: Double, _ dy: Double) -> [Double] {
        [1, 0, dx, 0, 1, dy, 0, 0, 1]
    }

    /// Write one frame's earth record.  `links` maps a neighbour's frame index to the homography
    /// bringing that neighbour into `frameIndex` — the direction the real alignment stage stores.
    private func write(
      _ database: HomographyDatabase,
      frameIndex: Int,
      links: [Int: [Double]],
      state: AlignmentState = .homographySuccess
    ) async throws {
        let warps = links.map { neighbour, homography in
            AlignmentWarpInfoCodable(homography: homography,
                                     deviation: 1,
                                     alignmentState: state,
                                     frameIndex: neighbour)
        }
        try await database.write(frameIndex: frameIndex,
                                 type: .earth,
                                 results: HomographyResultsCodable(for: frameIndex,
                                                                   with: warps))
    }

    private func database(named name: String) throws -> HomographyDatabase {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return HomographyDatabase(tempOutputPath: directory.path)
    }

    /// Where `(x, y)` lands under a row-major 3x3.
    private func apply(_ h: [Double], _ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let w = h[6] * x + h[7] * y + h[8]
        return ((h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w)
    }

    // MARK: - EarthHomographyChain

    /// A frame is trivially in its own coordinates.  Callers lean on this: the frame being merged is
    /// sometimes its own nearest reference.
    func testAFrameMapsToItselfWithTheIdentity() async throws {
        let db = try database(named: "identity")
        let chain = EarthHomographyChain()
        let transform = await chain.transform(from: 7, to: 7, database: db)
        XCTAssertEqual(try XCTUnwrap(transform), [1, 0, 0, 0, 1, 0, 0, 0, 1])
    }

    /// The link from frame 4 to frame 5 lives in *frame 5's* record, because that record's job is to
    /// bring each neighbour into frame 5.  Reading it out of frame 4's would invert the transform,
    /// which shows up as a horizon that moves the wrong way — the kind of fault a picture makes
    /// obvious and a number does not.
    func testASingleStepIsReadFromTheDestinationsRecord() async throws {
        let db = try database(named: "onestep")
        try await write(db, frameIndex: 5, links: [4: translation(10, -3)])
        let chain = EarthHomographyChain()

        let transform = await chain.transform(from: 4, to: 5, database: db)
        let moved = apply(try XCTUnwrap(transform), 100, 200)
        XCTAssertEqual(moved.x, 110, accuracy: 1e-9)
        XCTAssertEqual(moved.y, 197, accuracy: 1e-9)
    }

    /// Composition order: applying the chain must be applying each step in turn, so three hops of
    /// +10 land 30 across rather than 10.
    func testStepsComposeInOrder() async throws {
        let db = try database(named: "compose")
        for frame in 1...3 {
            try await write(db, frameIndex: frame, links: [frame - 1: translation(10, 1)])
        }
        let chain = EarthHomographyChain()

        let transform = await chain.transform(from: 0, to: 3, database: db)
        let moved = apply(try XCTUnwrap(transform), 0, 0)
        XCTAssertEqual(moved.x, 30, accuracy: 1e-9)
        XCTAssertEqual(moved.y, 3, accuracy: 1e-9)
    }

    /// Backwards works the same way, out of the record of the frame being stepped *to*.
    func testTheChainRunsBackwardsAsWellAsForwards() async throws {
        let db = try database(named: "backwards")
        try await write(db, frameIndex: 0, links: [1: translation(-5, 0)])
        try await write(db, frameIndex: 1, links: [2: translation(-5, 0)])
        let chain = EarthHomographyChain()

        let transform = await chain.transform(from: 2, to: 0, database: db)
        XCTAssertEqual(apply(try XCTUnwrap(transform), 100, 0).x, 90, accuracy: 1e-9)
    }

    /// The widest hop the records offer is taken, not four single ones.  Each hop multiplies in its
    /// own fit error, and the wide entries were fitted directly between their two frames rather than
    /// composed — measured on real data this is 3.1 px of error against 8.1 px.
    ///
    /// Made visible here by giving the four-frame link a translation that is *not* four times the
    /// single-frame one: whichever route was taken is readable from the answer.
    func testTheWidestAvailableHopIsPreferred() async throws {
        let db = try database(named: "widest")
        // single steps of +1 all the way, plus a direct 0 -> 4 of +100
        for frame in 1...4 {
            var links: [Int: [Double]] = [frame - 1: translation(1, 0)]
            if frame == 4 { links[0] = translation(100, 0) }
            try await write(db, frameIndex: frame, links: links)
        }
        let chain = EarthHomographyChain()

        // The first read is what teaches the chain how far the records reach, so ask twice: the
        // second call is the one that has the reach and must use it.
        _ = await chain.transform(from: 0, to: 4, database: db)
        let transform = await chain.transform(from: 0, to: 4, database: db)
        XCTAssertEqual(apply(try XCTUnwrap(transform), 0, 0).x, 100, accuracy: 1e-9,
                       "the direct four-frame link should have been used, not four single steps")
    }

    /// A gap with nothing bridging it gives no answer rather than a wrong one.  The caller falls back
    /// to interpolating, which is worse but honest.
    func testAMissingLinkBreaksTheChain() async throws {
        let db = try database(named: "gap")
        try await write(db, frameIndex: 1, links: [0: translation(1, 0)])
        // nothing written for frame 2, so there is no way out of frame 1
        let chain = EarthHomographyChain()
        let result = await chain.transform(from: 0, to: 2, database: db)
        XCTAssertNil(result, "a chain with a hole in it must not be answered")
    }

    /// A neighbour whose alignment failed carries a homography field that means nothing.  Using it
    /// would move the horizon by whatever the failed fit happened to produce.
    func testAFailedAlignmentIsNotUsedAsALink() async throws {
        let db = try database(named: "failed")
        try await write(db, frameIndex: 1, links: [0: translation(1, 0)], state: .noHomographyFound)
        let chain = EarthHomographyChain()
        let result = await chain.transform(from: 0, to: 1, database: db)
        XCTAssertNil(result)
    }

    /// `usedExistingHomography` is a real alignment — it is how a frame that reused a neighbour's
    /// solution is recorded — and must be accepted alongside `homographySuccess`.
    func testAReusedHomographyCounts() async throws {
        let db = try database(named: "reused")
        try await write(db, frameIndex: 1, links: [0: translation(4, 0)],
                        state: .usedExistingHomography)
        let chain = EarthHomographyChain()
        let transform = await chain.transform(from: 0, to: 1, database: db)
        XCTAssertEqual(apply(try XCTUnwrap(transform), 0, 0).x, 4, accuracy: 1e-9)
    }

    /// Records are memoised, and a second sequence must not be answered out of the first one's.  The
    /// chain lives for the process, not the run.
    func testOpeningAnotherSequenceDropsTheMemoisedRecords() async throws {
        let first = try database(named: "seqA")
        let second = try database(named: "seqB")
        try await write(first, frameIndex: 1, links: [0: translation(7, 0)])
        let chain = EarthHomographyChain()

        let fromFirst = await chain.transform(from: 0, to: 1, database: first)
        XCTAssertNotNil(fromFirst)
        let fromSecond = await chain.transform(from: 0, to: 1, database: second)
        XCTAssertNil(fromSecond, "the second sequence has no homographies of its own")
        let firstAgain = await chain.transform(from: 0, to: 1, database: first)
        XCTAssertNotNil(firstAgain, "and switching back must read the first one's again")
    }

    /// Every frame of a refinement span asks about the same records; reading each once is the point
    /// of the memo.
    func testRecordsAreReadOnce() async throws {
        let db = try database(named: "memo")
        for frame in 1...3 {
            try await write(db, frameIndex: frame, links: [frame - 1: translation(1, 0)])
        }
        let chain = EarthHomographyChain()
        _ = await chain.transform(from: 0, to: 3, database: db)
        let after = await chain.stats()
        _ = await chain.transform(from: 0, to: 3, database: db)
        let again = await chain.stats()
        XCTAssertEqual(again.reads, after.reads, "the second chain read nothing new")
        XCTAssertGreaterThan(again.hits, after.hits)
    }

    // MARK: - HorizonCurve.warp

    /// Under the identity the line comes back where it started, column for column.
    func testWarpingByTheIdentityChangesNothing() {
        let line: [Int?] = [10, 12, 14, 16]
        let warped = HorizonCurve.warp(line, with: [1, 0, 0, 0, 1, 0, 0, 0, 1], width: 4)
        XCTAssertEqual(warped.map { $0.map { Int($0.rounded()) } }, [10, 12, 14, 16])
    }

    /// A pure vertical shift moves every column by the same amount — the one case the old
    /// interpolate-the-Y-values approach also got right.
    func testAVerticalShiftMovesEveryColumn() {
        let line: [Int?] = [10, 10, 10, 10]
        let warped = HorizonCurve.warp(line, with: [1, 0, 0, 0, 1, 25, 0, 0, 1], width: 4)
        XCTAssertEqual(warped.map { $0.map { Int($0.rounded()) } }, [35, 35, 35, 35])
    }

    /// A horizontal pan is the case it exists for: the ridge that was under column 0 is now under
    /// column 2, and the columns the reference no longer reaches come back nil rather than guessed.
    func testAHorizontalPanCarriesTheLineSidewaysAndLeavesTheUncoveredEdgeNil() {
        let line: [Int?] = [10, 20, 30, 40]
        let warped = HorizonCurve.warp(line, with: [1, 0, 2, 0, 1, 0, 0, 0, 1], width: 4)
        XCTAssertNil(warped[0], "nothing the reference saw lands in column 0 any more")
        XCTAssertNil(warped[1])
        XCTAssertEqual(warped[2].map { Int($0.rounded()) }, 10)
        XCTAssertEqual(warped[3].map { Int($0.rounded()) }, 20)
    }

    /// Sub-pixel landings are interpolated between the two samples that bracket them rather than
    /// snapped, so a half-pixel pan does not quantise the whole line.
    func testALandingBetweenTwoColumnsIsInterpolated() {
        let line: [Int?] = [0, 100, 200]
        let warped = HorizonCurve.warp(line, with: [1, 0, 0.5, 0, 1, 0, 0, 0, 1], width: 3)
        XCTAssertNil(warped[0])
        XCTAssertEqual(try XCTUnwrap(warped[1]), 50, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(warped[2]), 150, accuracy: 1e-6)
    }

    /// Undefined columns in the source contribute nothing — a partly painted reference is normal.
    func testUndefinedSourceColumnsAreSkipped() {
        let line: [Int?] = [10, nil, 30, nil]
        let warped = HorizonCurve.warp(line, with: [1, 0, 0, 0, 1, 0, 0, 0, 1], width: 4)
        XCTAssertEqual(try XCTUnwrap(warped[0]), 10, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(warped[1]), 20, accuracy: 1e-6,
                       "the gap is spanned by the two samples either side")
        XCTAssertEqual(try XCTUnwrap(warped[2]), 30, accuracy: 1e-6)
        XCTAssertNil(warped[3], "past the last sample there is nothing to interpolate from")
    }

    /// Fewer than two samples cannot define a line, and must give nils rather than trap.
    func testTooFewSamplesGiveNothing() {
        XCTAssertEqual(HorizonCurve.warp([nil, 5, nil],
                                         with: [1, 0, 0, 0, 1, 0, 0, 0, 1],
                                         width: 3).compactMap { $0 }.count, 0)
        XCTAssertEqual(HorizonCurve.warp([], with: [1, 0, 0, 0, 1, 0, 0, 0, 1], width: 3).count, 3)
    }

    /// A malformed homography is refused rather than indexed into.
    func testAMalformedHomographyIsRefused() {
        let warped = HorizonCurve.warp([10, 20], with: [1, 0, 0], width: 2)
        XCTAssertEqual(warped.count, 2)
        XCTAssertTrue(warped.allSatisfy { $0 == nil })
    }
}
