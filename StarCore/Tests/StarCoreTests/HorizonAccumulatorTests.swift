import XCTest
import StarCppBridge
@testable import StarCore

/// The running horizon vote: masks folded in one at a time, in place, from concurrent callers.
final class HorizonAccumulatorTests: XCTestCase {

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
}
