import XCTest
@testable import StarCore

/// The neighbour cloud's hop bound (BUG-003): bounded clouds stay near their seed, and agree with
/// the unbounded closure when the bound is at least as long as the chain.
final class NeighborCloudTests: XCTestCase {

    /// `count` small blobs in a row, each within `scanSize` of the next but not of the one after.
    private func chain(count: Int, gap: Int = 6) -> [Int32: Blob] {
        var blobs: [Int32: Blob] = [:]
        for i in 0..<count {
            var pixels = Set<SortablePixel>()
            for dx in 0..<3 { pixels.insert(SortablePixel(x: 10 + i * (3 + gap) + dx, y: 20, value: .sixteenBit(30000))) }
            blobs[Int32(i + 1)] = Blob(pixels, id: Int32(i + 1), frameIndex: 0)
        }
        return blobs
    }

    private func cloud(from seedId: Int32, hops: Int?, in blobs: [Int32: Blob], scanSize: Int = 8) async -> Set<Int32> {
        let analyzer = await BlobAnalyzer(blobMap: blobs, width: 400, height: 60, frameIndex: 0)
        let refs = await analyzer.blobRefsObj
        let result = await neighborCloud(of: blobs[seedId]!, blobRefs: refs, blobMap: blobs,
                                         scanSize: scanSize, maxHops: hops)
        return Set(result.map { $0.id })
    }

    func testUnboundedIsTheWholeChain() async {
        let all = await cloud(from: 1, hops: nil, in: chain(count: 10))
        XCTAssertEqual(all, Set(2...10), "the closure reaches every other blob of the chain")
    }

    func testHopsBoundHowFarTheCloudReaches() async {
        let blobs = chain(count: 10)
        let one = await cloud(from: 1, hops: 1, in: blobs)
        let two = await cloud(from: 1, hops: 2, in: blobs)
        let three = await cloud(from: 1, hops: 3, in: blobs)
        XCTAssertEqual(one, [2])
        XCTAssertEqual(two, [2, 3])
        XCTAssertEqual(three, [2, 3, 4])
    }

    func testABoundAtLeastAsLongAsTheChainEqualsTheClosure() async {
        let blobs = chain(count: 6)
        let closure = await cloud(from: 3, hops: nil, in: blobs)
        let bounded = await cloud(from: 3, hops: 50, in: blobs)
        XCTAssertEqual(closure, bounded)
        XCTAssertEqual(closure, [1, 2, 4, 5, 6])
    }

    func testFromTheMiddleTheBoundReachesBothWays() async {
        let two = await cloud(from: 5, hops: 2, in: chain(count: 9))
        XCTAssertEqual(two, [3, 4, 6, 7])
    }

    func testTheDefaultConfigBoundsTheCloud() {
        XCTAssertEqual(Config().linearConnectorNeighborHops, 2)
    }
}
