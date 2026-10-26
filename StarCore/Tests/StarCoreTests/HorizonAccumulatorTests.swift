import XCTest
import StarCppBridge
@testable import StarCore

/// The running horizon vote: masks folded in one at a time, in place, from concurrent callers.
final class HorizonAccumulatorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        _ = imageCache   // constructing the global cache installs the loader the C++ file reads go through
    }

    private func mask(_ horizon: @escaping (Int) -> Int, w: Int = 24, h: Int = 20) -> PixelatedImage {
        FrameHarness.syntheticMask(width: w, height: h, horizonAt: horizon)
    }

    private func skyRowCount(_ image: PixelatedImage, column x: Int) -> Int {
        let ys = CombinedHorizonDetector.extractHorizonY(from: image)
        return ys[x] ?? image.height
    }

    /// Five masks accumulated at once vote exactly as the same five accumulated one by one.
    func testConcurrentAccumulationEqualsSequentialAccumulation() async throws {
        let horizons: [(Int) -> Int] = [{ _ in 6 }, { _ in 8 }, { _ in 10 }, { x in 5 + x % 7 }, { _ in 14 }]
        let masks = horizons.map { mask($0) }
        nonisolated(unsafe) let shared = masks

        let sequential = HorizonAccumulator(frameCount: 5)
        for (i, m) in masks.enumerated() { await sequential.accumulate(image: m, frameIndex: i) }
        let expectedImage = await sequential.finalize(loadFilename: { _ in nil })
        let expected = try XCTUnwrap(expectedImage)

        for _ in 0..<5 {
            let concurrent = HorizonAccumulator(frameCount: 5)
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<5 {
                    group.addTask { await concurrent.accumulate(image: shared[i], frameIndex: i) }
                }
            }
            let gotImage = await concurrent.finalize(loadFilename: { _ in nil })
            let got = try XCTUnwrap(gotImage)
            XCTAssertEqual(CombinedHorizonDetector.extractHorizonY(from: got),
                           CombinedHorizonDetector.extractHorizonY(from: expected))
        }
    }

    /// Majority of five: the row where three of the five have turned to ground.
    func testTheVoteIsTheMajority() async throws {
        let acc = HorizonAccumulator(frameCount: 5)
        for (i, y) in [6, 8, 10, 12, 14].enumerated() {
            await acc.accumulate(image: mask({ _ in y }), frameIndex: i)
        }
        let resultImage = await acc.finalize(loadFilename: { _ in nil })
        let result = try XCTUnwrap(resultImage)
        // sky rows are 0..<y; a pixel is sky if more than 2 of 5 masks call it sky: rows < 10
        XCTAssertEqual(skyRowCount(result, column: 3), 10)
    }

    func testTheSameFrameIsNotCountedTwice() async throws {
        let acc = HorizonAccumulator(frameCount: 3)
        await acc.accumulate(image: mask({ _ in 4 }), frameIndex: 0)
        await acc.accumulate(image: mask({ _ in 4 }), frameIndex: 0)   // ignored
        await acc.accumulate(image: mask({ _ in 12 }), frameIndex: 1)
        await acc.accumulate(image: mask({ _ in 12 }), frameIndex: 2)
        let resultImage = await acc.finalize(loadFilename: { _ in nil })
        let result = try XCTUnwrap(resultImage)
        // 4,12,12 -> sky where more than 1 of 3 votes sky: rows < 12
        XCTAssertEqual(skyRowCount(result, column: 0), 12)
    }

    /// A mask of the wrong size cannot be added; the running total survives it.
    func testAMismatchedMaskLeavesTheRunningTotalIntact() async throws {
        let acc = HorizonAccumulator(frameCount: 3)
        await acc.accumulate(image: mask({ _ in 9 }), frameIndex: 0)
        await acc.accumulate(image: mask({ _ in 3 }, w: 10, h: 8), frameIndex: 1)   // wrong size
        await acc.accumulate(image: mask({ _ in 9 }), frameIndex: 2)
        let resultImage = await acc.finalize(loadFilename: { _ in nil })
        let result = try XCTUnwrap(resultImage)
        XCTAssertEqual(result.width, 24)
        XCTAssertEqual(skyRowCount(result, column: 0), 9)
    }

    // MARK: - partial ranges

    /// A sequence of 100 frames of which only 9 were processed: the vote is against the 9 folded
    /// in. Voting against 100 asked for 51 sky votes from nine masks and called everything ground.
    func testAPartialRangeVotesAgainstTheMasksFoldedIn() async throws {
        let acc = HorizonAccumulator(frameCount: 100)
        for i in 0..<9 { await acc.accumulate(image: mask({ _ in 12 }), frameIndex: i) }
        let image = await acc.finalize(loadFilename: { _ in nil })
        let result = try XCTUnwrap(image)
        XCTAssertEqual(skyRowCount(result, column: 4), 12, "the horizon should be where the nine masks put it")
        XCTAssertFalse(HorizonAccumulatorTests.allOneValue(result), "a partial run produced an all-ground mask")
    }

    /// Masks loaded from disk at finalize time: only the ones that exist count, and the result is
    /// the vote of those.
    func testMissingFilesAreNotInTheVote() async throws {
        let dir = NSTemporaryDirectory() + "acc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // frames 0-2 are on disk (horizon at row 7); frames 3-9 are not
        for i in 0..<3 {
            let path = "\(dir)/m\(i).tif"
            _ = mask({ _ in 7 }).writeTIFFEncoding(toFilename: path)
        }
        let acc = HorizonAccumulator(frameCount: 10)
        let image = await acc.finalize(loadFilename: { "\(dir)/m\($0).tif" })
        let result = try XCTUnwrap(image)
        XCTAssertEqual(skyRowCount(result, column: 2), 7)
    }

    /// In-memory and disk masks together: counted once each, and a frame folded in by finalize is
    /// not folded in again by a second finalize.
    func testAFrameFoldedFromDiskIsNotCountedAgain() async throws {
        let dir = NSTemporaryDirectory() + "acc2-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = mask({ _ in 5 }).writeTIFFEncoding(toFilename: "\(dir)/m1.tif")
        _ = mask({ _ in 5 }).writeTIFFEncoding(toFilename: "\(dir)/m2.tif")
        let acc = HorizonAccumulator(frameCount: 3)
        await acc.accumulate(image: mask({ _ in 15 }), frameIndex: 0)
        let first = await acc.finalize(loadFilename: { "\(dir)/m\($0).tif" })
        // 15, 5, 5 -> sky where more than 1 of 3 votes sky: rows < 5 ... (5,5 vote sky only above 5)
        XCTAssertEqual(skyRowCount(try XCTUnwrap(first), column: 0), 5)
        let second = await acc.finalize(loadFilename: { "\(dir)/m\($0).tif" })
        XCTAssertEqual(skyRowCount(try XCTUnwrap(second), column: 0), 5, "a second finalize double counted")
    }

    static func allOneValue(_ image: PixelatedImage) -> Bool { FrameHorizonProcessor.maskIsUniform(image) }

    func testUniformMasksAreRecognised() {
        let allGround = mask({ _ in 0 })
        let allSky = mask({ _ in 1000 })
        let real = mask({ _ in 9 })
        XCTAssertTrue(FrameHorizonProcessor.maskIsUniform(allGround))
        XCTAssertTrue(FrameHorizonProcessor.maskIsUniform(allSky))
        XCTAssertFalse(FrameHorizonProcessor.maskIsUniform(real))
    }
}
