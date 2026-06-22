import XCTest
import Foundation
import StarDaemonMessages
import SwiftProtobuf

// §12.2 — wire-level frame round-trip and multiplexer correctness.

final class FramingTests: XCTestCase {

    // MARK: - Pure encode/decode

    func testEmptyPayloadRoundTrip() {
        let payload = Data()
        let frame   = encodeFrame(payload)
        XCTAssertEqual(frame.count, 4)
        let decoded = decodeFrame(from: frame)
        XCTAssertEqual(decoded, payload)
    }

    func testShortPayloadRoundTrip() {
        let payload = Data([0x01, 0x02, 0x03])
        let frame   = encodeFrame(payload)
        XCTAssertEqual(frame.count, 7)
        let decoded = XCTUnwrap(decodeFrame(from: frame))
        XCTAssertEqual(decoded, payload)
    }

    func testLargePayloadRoundTrip() {
        let payload = Data(repeating: 0xAB, count: 65537)
        let frame   = encodeFrame(payload)
        XCTAssertEqual(frame.count, 65537 + 4)
        let decoded = XCTUnwrap(decodeFrame(from: frame))
        XCTAssertEqual(decoded, payload)
    }

    func testHeaderIsBigEndian() {
        let payload = Data(repeating: 0, count: 0x010203)
        let frame   = encodeFrame(payload)
        // 0x010203 big-endian = [0x00, 0x01, 0x02, 0x03]
        XCTAssertEqual(frame[0], 0x00)
        XCTAssertEqual(frame[1], 0x01)
        XCTAssertEqual(frame[2], 0x02)
        XCTAssertEqual(frame[3], 0x03)
    }

    func testDecodeNilForTruncatedHeader() {
        XCTAssertNil(decodeFrame(from: Data([0x00, 0x00])))
    }

    func testDecodeNilForTruncatedPayload() {
        // Header claims 4 bytes but only 2 payload bytes present.
        let bad = Data([0x00, 0x00, 0x00, 0x04, 0xAA, 0xBB])
        XCTAssertNil(decodeFrame(from: bad))
    }

    // MARK: - Envelope encode/decode round-trip

    func testEnvelopeRoundTrip() throws {
        var env = Star_V1_Envelope()
        env.id      = 42
        env.kind    = .request
        env.method  = "Session.OpenSequence"
        env.payload = Data([0xDE, 0xAD])

        let serialized = try env.serializedData()
        let frame      = encodeFrame(serialized)
        let decoded    = try XCTUnwrap(decodeFrame(from: frame))
        let back       = try Star_V1_Envelope(serializedBytes: decoded)

        XCTAssertEqual(back.id,     42)
        XCTAssertEqual(back.kind,   .request)
        XCTAssertEqual(back.method, "Session.OpenSequence")
        XCTAssertEqual(back.payload, Data([0xDE, 0xAD]))
    }

    func testMultipleFramesConcatenated() throws {
        let payloads: [Data] = [
            Data([0x01]),
            Data([0x02, 0x03]),
            Data([0x04, 0x05, 0x06]),
        ]
        var buffer = Data()
        for p in payloads { buffer.append(encodeFrame(p)) }

        var offset = 0
        for expected in payloads {
            let slice = buffer.subdata(in: offset..<buffer.count)
            let got   = try XCTUnwrap(decodeFrame(from: slice))
            XCTAssertEqual(got, expected)
            offset += 4 + expected.count
        }
    }

    // MARK: - FileHandle pipe round-trip (§6.3 validated helpers)

    func testPipeRoundTrip() throws {
        let pipe    = Pipe()
        let payload = Data("hello stard".utf8)
        let frame   = encodeFrame(payload)

        pipe.fileHandleForWriting.write(frame)
        pipe.fileHandleForWriting.closeFile()

        let headerData = pipe.fileHandleForReading.readData(ofLength: 4)
        XCTAssertEqual(headerData.count, 4)
        let len  = headerData.reduce(0) { ($0 << 8) | Int($1) }
        let body = pipe.fileHandleForReading.readData(ofLength: len)
        XCTAssertEqual(body, payload)
    }
}

// XCTUnwrap is throwing in XCTest — provide non-try wrapper for the optional cases above.
private func XCTUnwrap<T>(_ optional: T?) -> T {
    guard let value = optional else { XCTFail("Unexpected nil"); fatalError() }
    return value
}
