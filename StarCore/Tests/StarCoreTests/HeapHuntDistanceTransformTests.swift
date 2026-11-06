import XCTest
@testable import StarCore

/// A target for the #108 heap hunt (tools/heap-hunt/README.md).
///
/// Thread 42 of the 0.12.6 crash sat in `.LLOOP_4Agas_1`, which is the loop in IPP ICV's
/// `ippiDistanceTransform_3x3_8u32f_C1R` (`ipcvdisttransm7as_*.o` in libopencv2.a), reached through
/// `cv::distanceTransform(.., DIST_L2, 3)` in `createGradientMaskIntoSky`.  IPP is gas-assembled, so ASan
/// cannot see its writes; libgmalloc can, since every allocation ends at a guard page.  The call is
/// size-dependent, so this runs the same entry point (`raiseMaskBy`) at odd sizes, with a wavy horizon and
/// with an all-sky mask.  By default only the small sizes run (a second or so); `STAR_HEAP_HUNT_DT=1` adds the
/// full 6000x4000 family, which is what to run under libgmalloc:
///
///     STAR_HEAP_HUNT_DT=1 tools/heap-hunt/gmalloc-xctest.sh HeapHuntDistanceTransformTests/testGradientMasksAtOddSizes
final class HeapHuntDistanceTransformTests: XCTestCase {
    private func mask(width: Int, height: Int, withGround: Bool) -> PixelatedImage? {
        let columns: [Int?] = (0..<width).map { x in
            withGround ? Optional(max(0, height / 2 + Int(Double(height) * 0.04 * sin(Double(x) / 400)))) : nil
        }
        return PixelatedImage.fromHorizonColumnY(width: width, height: height, columnY: columns)
    }

    func testGradientMasksAtOddSizes() throws {
        var sizes: [(Int, Int)] = [
            (7, 7), (16, 16), (17, 15), (33, 9), (255, 2), (257, 3), (1023, 5), (1025, 5), (1, 64), (64, 1),
        ]
        if ProcessInfo.processInfo.environment["STAR_HEAP_HUNT_DT"] != nil {
            sizes += [(6000, 4000), (6001, 4001), (5999, 3999), (4096, 2731), (6000, 1), (1, 4000)]
        }
        for (width, height) in sizes {
            for withGround in [true, false] {
                let image = try XCTUnwrap(mask(width: width, height: height, withGround: withGround))
                let raised = try XCTUnwrap(image.raiseMaskBy(100),
                                           "raiseMaskBy \(width)x\(height) ground=\(withGround)")
                XCTAssertEqual(raised.width, width)
                XCTAssertEqual(raised.height, height)
            }
        }
    }
}
