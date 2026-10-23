import XCTest
@testable import StarCore

/// The S7 horizon-detector speedups must not change a single answer.
final class HorizonSpeedIdentityTests: XCTestCase {

    /// One prepare, many solves, equals the one-shot call for every weight set.
    func testPreparedDPEqualsTheOneShotDPForEveryWeightSet() throws {
        let image = FrameHarness.syntheticFrame(width: 160, height: 100, horizonRow: 55, seed: 3)
        let prepared = try XCTUnwrap(image.dpHorizonPrepare())
        for lambda in [0.5, 2.0, 6.0] {
            for sobel in [0.3, 0.6, 0.9] {
                for canny in [0.1, 0.4] {
                    let oneShot = try image.dpHorizonDetect(smoothnessLambda: lambda, sobelWeight: sobel,
                                                            cannyWeight: canny)
                    let split = try prepared.detect(smoothnessLambda: lambda, sobelWeight: sobel,
                                                    cannyWeight: canny)
                    XCTAssertEqual(CombinedHorizonDetector.extractHorizonY(from: oneShot),
                                   CombinedHorizonDetector.extractHorizonY(from: split),
                                   "lambda \(lambda) sobel \(sobel) canny \(canny)")
                }
            }
        }
    }

    func testPreparedDPHonoursTheSearchBand() throws {
        let image = FrameHarness.syntheticFrame(width: 120, height: 90, horizonRow: 40)
        let prepared = try XCTUnwrap(image.dpHorizonPrepare())
        let a = try image.dpHorizonDetect(searchTopFraction: 0.2, searchBottomFraction: 0.8)
        let b = try prepared.detect(searchTopFraction: 0.2, searchBottomFraction: 0.8)
        XCTAssertEqual(CombinedHorizonDetector.extractHorizonY(from: a),
                       CombinedHorizonDetector.extractHorizonY(from: b))
    }
}
