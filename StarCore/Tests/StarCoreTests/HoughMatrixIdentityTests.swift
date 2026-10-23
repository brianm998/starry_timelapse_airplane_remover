import XCTest
@testable import StarCore

/// The matrix connector's per-element walk is now synchronous; it has to map exactly the blob
/// pairs the actor-driven walk did, on every element of the matrix.
final class HoughMatrixIdentityTests: XCTestCase {

    private func segment(id: Int32, from a: (Int, Int), to b: (Int, Int), gapEvery: Int = 0,
                         thickness: Int = 1) -> Blob {
        var pixels = Set<SortablePixel>()
        let steps = max(abs(b.0 - a.0), abs(b.1 - a.1))
        for s in 0...steps {
            if gapEvery > 0, s % gapEvery < 2 { continue }
            let x = a.0 + (b.0 - a.0) * s / max(steps, 1)
            let y = a.1 + (b.1 - a.1) * s / max(steps, 1)
            for t in 0..<thickness {
                pixels.insert(SortablePixel(x: x, y: y + t, value: .sixteenBit(30000)))
            }
        }
        return Blob(pixels, id: id, frameIndex: 0)
    }

    private func scene() -> (blobs: [Int32: Blob], width: Int, height: Int) {
        var blobs: [Int32: Blob] = [:]
        // several trails: collinear pieces with small gaps (should map), pieces far apart on one
        // line (should not), a crossing trail, and scattered dots
        let pieces: [(Int32, (Int, Int), (Int, Int))] = [
          (1, (20, 30), (80, 60)), (2, (95, 67), (150, 95)), (3, (200, 120), (230, 134)),
          (4, (30, 200), (120, 190)), (5, (130, 189), (210, 180)), (6, (260, 175), (330, 168)),
          (7, (40, 120), (60, 260)), (8, (300, 20), (380, 40)), (9, (330, 29), (340, 31)),
          (10, (350, 100), (352, 102)), (11, (10, 280), (12, 282)), (12, (150, 250), (270, 262)),
        ]
        for (id, a, b) in pieces { blobs[id] = segment(id: id, from: a, to: b) }
        blobs[13] = segment(id: 13, from: (250, 40), to: (330, 120), gapEvery: 6, thickness: 2)
        return (blobs, 400, 300)
    }

    func testTheSynchronousWalkMapsTheSamePairsAsTheActorWalk() async throws {
        let (blobs, width, height) = scene()
        let analyzer = await BlobAnalyzer(blobMap: blobs, width: width, height: height, frameIndex: 0)
        let maybeImage = await analyzer.pixelatedImage
        let image = try XCTUnwrap(maybeImage)

        let argsList: [HoughLineMatrixBlobConnector.Args] = [
          .init(elementWidth: 200, elementHeight: 150, overlapPercent: 0.2, maxHoughLines: 50,
                sideIterationPixels: 3, maxBlobDistance: 30),
          .init(elementWidth: 400, elementHeight: 300, overlapPercent: 0.1, maxHoughLines: 200,
                sideIterationPixels: 5, maxBlobDistance: 12),
        ]

        var totalMappings = 0
        for args in argsList {
            let matrix = image.splitIntoMatrix(maxWidth: args.elementWidth, maxHeight: args.elementHeight,
                                               overlapPercent: args.overlapPercent)
            XCTAssertFalse(matrix.isEmpty)
            for (index, element) in matrix.enumerated() {
                let legacy = await legacyProcess(element: element, blobElement: element, with: args,
                                                 frameIndex: 0, blobMap: blobs)
                let rewritten = processSync(element: element, blobElement: element, with: args,
                                            frameIndex: 0, blobMap: blobs)
                XCTAssertEqual(legacy, rewritten, "element \(index) of \(matrix.count) differs")
                totalMappings += rewritten.count
            }
        }
        XCTAssertGreaterThan(totalMappings, 0, "the scene produced no mappings, so nothing was compared")
    }

    /// An element no blob touches maps nothing (and no longer pays for a Hough transform).
    func testAnElementWithNoBlobsMapsNothing() async throws {
        let blobs: [Int32: Blob] = [1: segment(id: 1, from: (10, 10), to: (40, 20))]
        let analyzer = await BlobAnalyzer(blobMap: blobs, width: 400, height: 300, frameIndex: 0)
        let maybeImage = await analyzer.pixelatedImage
        let image = try XCTUnwrap(maybeImage)
        let args = HoughLineMatrixBlobConnector.Args(elementWidth: 100, elementHeight: 100, overlapPercent: 0,
                                                     maxHoughLines: 20, sideIterationPixels: 2,
                                                     maxBlobDistance: 30)
        let matrix = image.splitIntoMatrix(maxWidth: 100, maxHeight: 100, overlapPercent: 0)
        let far = try XCTUnwrap(matrix.last)
        XCTAssertTrue(processSync(element: far, blobElement: far, with: args, frameIndex: 0, blobMap: blobs).isEmpty)
    }
}
