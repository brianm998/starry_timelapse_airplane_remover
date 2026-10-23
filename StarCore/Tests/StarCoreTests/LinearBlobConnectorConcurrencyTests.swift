import XCTest
@testable import StarCore

/// The connector's seeds are independent and their results are unioned, so how many run at once
/// must not change the blobs that come out. Checked at frame level on a synthetic dense field
/// (the dense crop itself is off limits on this machine, see the guide's 0.3).
final class LinearBlobConnectorConcurrencyTests: XCTestCase {

    private func denseField() -> [Int32: Blob] {
        var state: UInt64 = 2024
        func next(_ n: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int(state >> 33) % n }
        var blobs: [Int32: Blob] = [:]
        var id: Int32 = 1
        // many short collinear-ish streak pieces plus dots, close enough that clouds overlap
        for _ in 0..<24 {
            let x0 = next(160) + 10, y0 = next(100) + 10
            let dx = next(3) + 1, dy = next(2)
            let length = next(14) + 6
            var pixels = Set<SortablePixel>()
            for s in 0..<length {
                pixels.insert(SortablePixel(x: x0 + s * dx, y: y0 + s * dy, value: .sixteenBit(UInt16(20000 + next(30000)))))
            }
            blobs[id] = Blob(pixels, id: id, frameIndex: 0)
            id += 1
        }
        return blobs
    }

    private func fingerprint(_ map: [Int32: Blob]) async -> [String] {
        var out: [String] = []
        for (id, blob) in map {
            let pixels = await blob.getPixels().sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            out.append("\(id): " + pixels.map { "\($0.x),\($0.y)" }.joined(separator: ";"))
        }
        return out.sorted()
    }

    func testTheResultDoesNotDependOnHowManySeedsRunAtOnce() async {
        let args = LinearBlobConnector.Args(scanSize: 14, blobsSmallerThan: 6800, blobsLargerThan: 4,
                                            lineBorder: 5, minLineScore: 0.5,
                                            adjecentPixelsOnIteration: 5, maxBlobsProcessed: 400)
        var reference: [String]? = nil
        for concurrency in [1, 3, 32] {
            let connector = await LinearBlobConnector(blobMap: denseField(), width: 200, height: 130, frameIndex: 0)
            await connector.process(args, seedConcurrency: concurrency)
            let result = await fingerprint(await connector.blobMap())
            if let reference {
                XCTAssertEqual(result, reference, "seedConcurrency \(concurrency) changed the blobs")
            } else {
                reference = result
            }
        }
    }
}
