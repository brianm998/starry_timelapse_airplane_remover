import XCTest
@testable import StarCore

/// `outliers.bin` round trips: saver -> file -> loader.
final class BlobBinaryRoundTripTests: XCTestCase {

    private func blob(id: Int32, count: Int, rowOffset: Int = 0) -> Blob {
        // distinct intensities so a trimmed blob keeps a well-defined set
        var pixels = Set<SortablePixel>()
        for i in 0..<count {
            let value = UInt16(1 + i % 60000)
            pixels.insert(SortablePixel(x: i % 1000, y: rowOffset + i / 1000, value: .sixteenBit(value)))
        }
        return Blob(pixels, id: id, frameIndex: 0)
    }

    private func roundTrip(_ blobs: [Blob]) async throws -> [Int32: Blob] {
        let dir = NSTemporaryDirectory() + "blobrt-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var map: [Int32: Blob] = [:]
        for b in blobs { map[b.id] = b }
        await BlobBinarySaver(blobMap: map).save(to: "\(dir)/\(BlobBinarySaver.outlierBinaryFilename)")
        return try await BlobBinaryLoader().load(from: dir, with: 0)
    }

    func testSmallBlobsRoundTrip() async throws {
        let loaded = try await roundTrip([blob(id: 1, count: 10), blob(id: 2, count: 20, rowOffset: 100)])
        let s1 = await loaded[1]?.size(), s2 = await loaded[2]?.size()
        XCTAssertEqual(s1, 10)
        XCTAssertEqual(s2, 20)
    }

    /// A blob over the 16-bit limit is trimmed on save.  Every blob after it must still load
    /// intact; the old sizing left trailing zeros that misaligned them.
    func testABlobOverTheLimitDoesNotCorruptTheOnesAfterIt() async throws {
        let big = blob(id: 1, count: 70_000)
        let normal = blob(id: 2, count: 25, rowOffset: 500)
        // dictionary order is arbitrary, so run it with each ordering by saving several times
        for _ in 0..<3 {
            let loaded = try await roundTrip([big, normal])
            let n = await loaded[2]?.size()
            XCTAssertEqual(n, 25, "the blob after the oversize one came back damaged")
            let b = await loaded[1]?.size()
            XCTAssertEqual(b, Int(UInt16.max) - 1)
            XCTAssertEqual(loaded.count, 2)
        }
    }

    func testTheSizeReportedMatchesTheArrayWritten() async {
        let big = blob(id: 1, count: 70_000)
        let words = await big.persistentDataArray()
        let size = await big.persistentDataSizeBytes()
        XCTAssertEqual(words.count * 2, size)
    }

    /// An id past 16 bits cannot be saved; it is skipped rather than trapping.
    func testAnIdPastSixteenBitsIsSkippedNotTrapped() async throws {
        let loaded = try await roundTrip([blob(id: 70_000, count: 5), blob(id: 3, count: 7, rowOffset: 50)])
        XCTAssertEqual(loaded.count, 1)
        let n = await loaded[3]?.size()
        XCTAssertEqual(n, 7)
    }

    func testOutlierGroupForAnIdPastSixteenBitsDoesNotTrap() async {
        let b = blob(id: 70_000, count: 5)
        let g = await b.outlierGroup(at: 0, imageWidth: 100, imageHeight: 100)
        XCTAssertEqual(g.id, UInt16.max)
    }
}
