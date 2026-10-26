import XCTest
import StarCppBridge
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

    // MARK: - extractHorizonY, row by row

    /// The column-by-column scan this replaced, kept as the reference.
    private func referenceHorizonY(_ mask: PixelatedImage) -> [Int?] {
        var result = [Int?](repeating: nil, count: mask.width)
        guard let raw = mask.mat.dataPtr else { return result }
        let ptr = raw.assumingMemoryBound(to: UInt8.self)
        for x in 0..<mask.width {
            for y in 0..<mask.height where ptr[y * mask.bytesPerRow + x * mask.componentsPerPixel] <= 127 {
                result[x] = y
                break
            }
        }
        return result
    }

    func testRowWiseScanMatchesTheColumnWiseOneOnATidyMask() {
        let mask = FrameHarness.syntheticMask(width: 90, height: 70) { x in 10 + (x * 7) % 50 }
        XCTAssertEqual(CombinedHorizonDetector.extractHorizonY(from: mask), referenceHorizonY(mask))
    }

    /// Noise has dark pixels scattered above the real boundary and columns with none at all, which
    /// is where an early exit could go wrong.
    func testRowWiseScanMatchesTheColumnWiseOneOnANoisyMask() {
        let w = 64, h = 48
        var state: UInt64 = 12345
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 }
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h)
        for i in 0..<(w * h) { data[i] = next() % 9 == 0 ? 0 : 255 }
        for y in 0..<h { data[y * w + 5] = 255 }                // a column with no dark pixel
        let mat = MatWrapper(width: w, height: h,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 1),
                             bytesPerRow: w, data: UnsafeMutableRawPointer(data), takeOwnership: true)
        data.deallocate()
        let mask = PixelatedImage(mat: mat)!
        let got = CombinedHorizonDetector.extractHorizonY(from: mask)
        XCTAssertEqual(got, referenceHorizonY(mask))
        XCTAssertNil(got[5])
    }

    // MARK: - the dropped threshold step

    /// Reading the horizon straight off the upscaled mask is what reading it off the
    /// thresholded copy gave.
    func testThresholdingTheUpscaledMaskNeverChangedItsHorizon() throws {
        let small = FrameHarness.syntheticMask(width: 40, height: 30) { x in 8 + (x * 3) % 15 }
        let up = try XCTUnwrap(small.mat.upScale(to: 160, height: 120))
        let upscaled = try XCTUnwrap(PixelatedImage(mat: up))
        let old = CombinedHorizonDetector.extractHorizonY(
          from: CombinedHorizonDetector.thresholdToBinary(upscaled))
        let new = CombinedHorizonDetector.fullResolutionHorizonY(of: small, toWidth: 160, height: 120)
        XCTAssertEqual(old, new)
    }

    // MARK: - Random Walker scoring without building a mask

    /// A brush is scored from its per-column answers instead of from the mask built from them.
    /// That is only legitimate if reading the mask back gives those answers: a row in [0, H) is
    /// itself, and -1, H and beyond are no horizon.
    func testScoringFromColumnsEqualsScoringTheMaskBuiltFromThem() {
        let h = 40, w = 30
        let raw: [Int32] = (0..<w).map { x in
            switch x % 7 {
            case 0: return -1
            case 1: return 0
            case 2: return Int32(h - 1)
            case 3: return Int32(h)          // at the bottom edge: no dark row
            case 4: return Int32(h + 9)      // past it
            default: return Int32(10 + x % 20)
            }
        }
        let viaMask = PixelatedImage(mat: PixelatedImageBridge.binaryHorizonMask(
            width: Int32(w), height: Int32(h), horizonY: raw.map { $0 < 0 ? nil : Int($0) }))!
        let direct: [Int?] = raw.map { $0 >= 0 && Int($0) < h ? Int($0) : nil }
        XCTAssertEqual(CombinedHorizonDetector.extractHorizonY(from: viaMask), direct)
        XCTAssertEqual(CombinedHorizonDetector.selfScore(mask: viaMask, imageHeight: h),
                       CombinedHorizonDetector.selfScore(horizonY: direct, imageHeight: h))
    }
}
