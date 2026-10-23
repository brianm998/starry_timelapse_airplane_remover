import XCTest
@testable import StarCore

/// `Blob.absorb` merges one blob's pixels into another, in place.
final class BlobAbsorbTests: XCTestCase {

    private func blob(id: Int32, pixels: [(Int, Int)]) -> Blob {
        Blob(Set(pixels.map { SortablePixel(x: $0.0, y: $0.1, value: .eightBit(200)) }),
             id: id, frameIndex: 0)
    }

    func testAbsorbingAddsTheOtherBlobsPixels() async {
        let a = blob(id: 1, pixels: [(0, 0), (1, 0)])
        let b = blob(id: 2, pixels: [(5, 5), (6, 5), (7, 5)])
        let ok = await a.absorb(b)
        XCTAssertTrue(ok)
        let size = await a.size()
        XCTAssertEqual(size, 5)
        let pixels = await a.getPixels()
        XCTAssertTrue(pixels.contains { $0.x == 7 && $0.y == 5 })
    }

    func testAbsorbingDoesNotChangeTheOtherBlob() async {
        let a = blob(id: 1, pixels: [(0, 0)])
        let b = blob(id: 2, pixels: [(5, 5)])
        _ = await a.absorb(b)
        let size = await b.size()
        XCTAssertEqual(size, 1)
    }

    func testOverlappingPixelsAreNotDuplicated() async {
        let a = blob(id: 1, pixels: [(0, 0), (1, 0)])
        let b = blob(id: 2, pixels: [(1, 0), (2, 0)])
        _ = await a.absorb(b)
        let size = await a.size()
        XCTAssertEqual(size, 3)
    }

    func testAbsorbingYourselfIsRefusedUnlessForced() async {
        let a = blob(id: 1, pixels: [(0, 0)])
        let same = blob(id: 1, pixels: [(3, 3)])
        let refused = await a.absorb(same)
        XCTAssertFalse(refused)
        let size = await a.size()
        XCTAssertEqual(size, 1)
        let forced = await a.absorb(same, always: true)
        XCTAssertTrue(forced)
    }

    /// The saved format stores a pixel count in 16 bits, so a merge past 65,535 pixels is refused
    /// and leaves the receiving blob untouched.
    func testAbsorbingPastTheSixteenBitLimitIsRefused() async {
        let big = (0..<40_000).map { ($0 % 400, $0 / 400) }
        let other = (0..<30_000).map { (($0 % 400) + 500, $0 / 400) }
        let a = blob(id: 1, pixels: big)
        let b = blob(id: 2, pixels: other)
        let ok = await a.absorb(b)
        XCTAssertFalse(ok)
        let size = await a.size()
        XCTAssertEqual(size, 40_000)
    }
}

/// `combine` is how both connectors merge a list of blobs; a blob the first one refuses must come back.
final class BlobCombineTests: XCTestCase {
    private func blob(id: Int32, count: Int, xOffset: Int = 0) -> Blob {
        var pixels = Set<SortablePixel>()
        for i in 0..<count { pixels.insert(SortablePixel(x: xOffset + i % 500, y: i / 500, value: .eightBit(200))) }
        return Blob(pixels, id: id, frameIndex: 0)
    }

    func testBlobsThatFitAreMergedIntoTheFirst() async {
        let a = blob(id: 1, count: 10), b = blob(id: 2, count: 10, xOffset: 600), c = blob(id: 3, count: 5, xOffset: 700)
        let out = await StarCore.combine([a, b, c])
        XCTAssertEqual(out.count, 1)
        let size = await out[0].size()
        XCTAssertEqual(size, 25)
    }

    func testARefusedBlobIsReturnedNotDropped() async {
        let big = blob(id: 1, count: 40_000), other = blob(id: 2, count: 30_000, xOffset: 1000), small = blob(id: 3, count: 20, xOffset: 3000)
        let out = await StarCore.combine([big, other, small])
        XCTAssertEqual(out.map { $0.id }.sorted(), [1, 2], "the refused blob must come back")
        let sizeFirst = await out[0].size()
        XCTAssertEqual(out[0].id, 1)
        XCTAssertEqual(sizeFirst, 40_020, "the small one still merged; the 30,000 one did not fit")
        let sizeRefused = await out[1].size()
        XCTAssertEqual(sizeRefused, 30_000, "and it is intact")
    }

    func testAnEmptyListCombinesToNothing() async {
        let out = await StarCore.combine([])
        XCTAssertTrue(out.isEmpty)
    }
}
