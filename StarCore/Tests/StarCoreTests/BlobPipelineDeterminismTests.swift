import XCTest
@testable import StarCore

/// BUG-001: the blob pipeline's output depended on dictionary and set iteration order and on
/// task completion order. These repeat the steps that were order-dependent and require the same
/// blobs, with the same ids, every time.
final class BlobPipelineDeterminismTests: XCTestCase {

    private func fingerprint(_ map: [Int32: Blob]) async -> [String] {
        var out: [String] = []
        for (id, blob) in map {
            let pixels = await blob.getPixels().sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            out.append("\(id): " + pixels.map { "\($0.x),\($0.y)" }.joined(separator: ";"))
        }
        return out.sorted()
    }

    /// L-shapes: a long straight run plus a stub far from its best line, so line trimming has
    /// something to split off.
    private func blobsToTrim() -> [Int32: Blob] {
        var blobs: [Int32: Blob] = [:]
        for k in 0..<12 {
            var pixels = Set<SortablePixel>()
            let ox = 5 + (k % 4) * 60, oy = 5 + (k / 4) * 50
            for x in 0..<40 { pixels.insert(SortablePixel(x: ox + x, y: oy + 5, value: .sixteenBit(30000))) }
            for y in 0..<(15 + k % 3 * 3) { pixels.insert(SortablePixel(x: ox + 5, y: oy + 5 + y, value: .sixteenBit(30000))) }
            let id = Int32(100 - k * 7)   // ids deliberately not in creation order
            blobs[id] = Blob(pixels, id: id, frameIndex: 0)
        }
        return blobs
    }

    func testLineTrimNumbersItsNewBlobsTheSameEveryTime() async {
        var reference: [String]? = nil
        for run in 0..<12 {
            let trim = BlobLineTrim(blobMap: blobsToTrim(), frameIndex: 0)
            let map = await trim.process(.init(minBlobSize: 10, minLineLength: 10, trimAmount: 3))
            let result = await fingerprint(map)
            if let reference {
                XCTAssertEqual(result, reference, "run \(run) numbered or trimmed differently")
            } else {
                reference = result
                XCTAssertGreaterThan(map.count, 12, "nothing was trimmed, so ids were never handed out")
            }
        }
    }

    func testCompactBlobIdsRenumbersInAscendingOldIdOrder() async {
        let processor = StrongBlobProcessor()
        let map: [Int32: Blob] = [900: Blob(id: 900, frameIndex: 0),
                                  7: Blob(id: 7, frameIndex: 0),
                                  42: Blob(id: 42, frameIndex: 0),
                                  3000: Blob(id: 3000, frameIndex: 0)]
        let oldBlobs: [Int32: Blob] = [7: map[7]!, 42: map[42]!, 900: map[900]!, 3000: map[3000]!]
        for _ in 0..<20 {
            let compact = processor.compactBlobIds(of: map)
            XCTAssertEqual(Set(compact.keys), [1, 2, 3, 4])
            XCTAssertTrue(compact[1] === oldBlobs[7])
            XCTAssertTrue(compact[2] === oldBlobs[42])
            XCTAssertTrue(compact[3] === oldBlobs[900])
            XCTAssertTrue(compact[4] === oldBlobs[3000])
            // put the ids back for the next round
            for (old, blob) in oldBlobs { blob.id = old }
        }
    }

    /// The line a blob fits does not depend on the order its pixels sit in the set.
    func testALinesFitDoesNotDependOnPixelSetOrder() async {
        var results: Set<String> = []
        for _ in 0..<8 {
            var pixels = Set<SortablePixel>()
            for i in 0..<60 { pixels.insert(SortablePixel(x: 10 + i, y: 20 + i / 3, value: .sixteenBit(UInt16(20000 + i * 100)))) }
            let blob = Blob(pixels, id: 1, frameIndex: 0)
            if let line = await blob.line {
                let probes = [(0, 0), (50, 30), (100, 5), (10, 90)]
                results.insert(probes.map { "\($0.0),\($0.1)=\(line.standardLine.distanceTo(x: $0.0, y: $0.1))" }.joined(separator: " "))
            }
        }
        XCTAssertEqual(results.count, 1, "different set orders fit different lines: \(results)")
    }
}
