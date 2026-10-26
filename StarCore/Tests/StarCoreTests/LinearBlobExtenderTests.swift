import XCTest
@testable import StarCore

/// `LinearBlobExtender` was dropped from the blob processors because it cannot change the blob
/// map. These pin that claim, so the step cannot quietly become meaningful again without the
/// processors noticing.
final class LinearBlobExtenderTests: XCTestCase {

    private func streak(id: Int32, from x0: Int, to x1: Int, y: Int) -> Blob {
        var pixels = Set<SortablePixel>()
        for x in x0...x1 {
            pixels.insert(SortablePixel(x: x, y: y + (x - x0) / 8, value: .sixteenBit(30000)))
        }
        return Blob(pixels, id: id, frameIndex: 0)
    }

    func testTheExtenderLeavesTheBlobMapUntouched() async {
        // two collinear streaks with a small gap: exactly what the extender was meant to join
        let a = streak(id: 1, from: 10, to: 80, y: 20)
        let b = streak(id: 2, from: 90, to: 160, y: 30)
        let extender = await LinearBlobExtender(blobMap: [1: a, 2: b], width: 200, height: 80, frameIndex: 0)
        await extender.process(.init(minBlobSize: 30, lineExtension: 25, innerSearch: 15,
                                     maxIterationCount: 4, scoreMultiplier: 8.1, sideIterationPixels: 5))
        let out = await extender.blobMap()
        XCTAssertEqual(Set(out.keys), [1, 2])
        let sizeA = await out[1]?.size(), sizeB = await out[2]?.size()
        XCTAssertEqual(sizeA, 71)
        XCTAssertEqual(sizeB, 71)
    }

    func testNoPresetStillRunsTheExtender() {
        for type in DetectionType.allCases {
            let processor = type.blobProcessor
            for step in processor.steps {
                if case .linearBlobExtender = step {
                    XCTFail("\(type) still has a linearBlobExtender step")
                }
            }
        }
    }
}
