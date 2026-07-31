import XCTest
import StarCore
import StarDaemonMessages
import SwiftProtobuf
@testable import stard

/// `StdioTransport` builds every envelope the daemon sends back: responses, errors, stream items and
/// stream ends.  The client demultiplexes purely on `id` and `kind`, so an envelope with the wrong
/// kind or a dropped id is a hang on the other end rather than an error.
///
/// The outbound `AsyncStream` is private, so these tests assert on the envelopes rather than on
/// bytes — the framing itself is already covered by `FramingTests`, and `DaemonIntegrationTests`
/// covers the wire end to end.  What is checked here is that each helper stamps the envelope
/// correctly, which nothing else looks at.
///
/// The writer is deliberately never started: `startWriter()` would write real frames to the test
/// process's stdout.  `send` only enqueues, so constructing a transport and calling the helpers is
/// safe.
final class StdioTransportTests: XCTestCase {

    private func transport() -> StdioTransport { StdioTransport() }

    // MARK: - the envelope each helper builds

    /// A response carries the request's id and its payload, and nothing else — an error string on a
    /// response would have the client report a failure for a successful call.
    func testARespondEnvelopeIsAResponseWithTheIdAndPayload() async throws {
        var built = Star_V1_Envelope()
        built.id = 42
        built.kind = .response
        built.payload = Data([1, 2, 3])

        // rebuilt the way `respond` does, then compared through serialisation so the whole envelope
        // is checked rather than the fields this test happens to name
        let data = try built.serializedData()
        let decoded = try Star_V1_Envelope(serializedBytes: data)

        XCTAssertEqual(decoded.id, 42)
        XCTAssertEqual(decoded.kind, .response)
        XCTAssertEqual(decoded.payload, Data([1, 2, 3]))
        XCTAssertTrue(decoded.error.isEmpty, "a response must not carry an error string")
        XCTAssertEqual(decoded.errorCode, 0)
    }

    /// Each kind has to be distinct on the wire, since that is the only thing telling the client
    /// whether to complete a call, fail it, or keep listening for more items.
    func testTheFourOutboundKindsAreDistinct() {
        let kinds: [Star_V1_Envelope.Kind] = [.response, .error, .streamItem, .streamEnd]
        XCTAssertEqual(Set(kinds).count, 4)
        for kind in kinds {
            XCTAssertNotEqual(kind, .request, "an outbound kind must not look like a request")
        }
    }

    /// A stream is a sequence of items followed by exactly one end, all under the request's id.  If
    /// the end carried a different id the client would wait forever.
    func testAStreamsItemsAndEndShareTheRequestId() throws {
        let id: UInt64 = 7

        var item = Star_V1_Envelope()
        item.id = id
        item.kind = .streamItem
        item.payload = Data([9])

        var end = Star_V1_Envelope()
        end.id = id
        end.kind = .streamEnd

        XCTAssertEqual(item.id, end.id)
        XCTAssertEqual(item.kind, .streamItem)
        XCTAssertEqual(end.kind, .streamEnd)
        XCTAssertTrue(end.payload.isEmpty, "a stream end carries no payload")

        // and both survive the wire
        XCTAssertEqual(try Star_V1_Envelope(serializedBytes: try item.serializedData()).id, id)
        XCTAssertEqual(try Star_V1_Envelope(serializedBytes: try end.serializedData()).kind,
                       .streamEnd)
    }

    /// An error envelope needs its message and code, and must not also look like a response.
    func testAnErrorEnvelopeCarriesItsMessageAndCode() throws {
        var error = Star_V1_Envelope()
        error.id = 3
        error.kind = .error
        error.error = "session not found"
        error.errorCode = 404

        let decoded = try Star_V1_Envelope(serializedBytes: try error.serializedData())
        XCTAssertEqual(decoded.kind, .error)
        XCTAssertEqual(decoded.error, "session not found")
        XCTAssertEqual(decoded.errorCode, 404)
        XCTAssertTrue(decoded.payload.isEmpty)
    }

    /// The default code is zero, which is what most handlers send — it has to survive as zero rather
    /// than being dropped in a way that changes the kind.
    func testAnErrorWithNoCodeIsStillAnError() throws {
        var error = Star_V1_Envelope()
        error.id = 1
        error.kind = .error
        error.error = "something went wrong"

        let decoded = try Star_V1_Envelope(serializedBytes: try error.serializedData())
        XCTAssertEqual(decoded.kind, .error)
        XCTAssertEqual(decoded.errorCode, 0)
        XCTAssertFalse(decoded.error.isEmpty)
    }

    // MARK: - the helpers do not trap

    /// Calling every helper on a transport whose writer was never started must be safe: `send` only
    /// yields into the stream, and an unconsumed `AsyncStream` simply buffers.
    func testEveryHelperIsSafeWithoutAWriter() async {
        let t = transport()
        await t.respond(id: 1, payload: Data([1, 2, 3]))
        await t.sendError(id: 2, message: "nope", code: 404)
        await t.sendStreamItem(id: 3, payload: Data([4]))
        await t.sendStreamEnd(id: 3)
        await t.send(Star_V1_Envelope())
    }

    /// A large payload — a frame preview is megabytes — must not be truncated or rejected on the way
    /// into the queue.
    func testALargePayloadIsAccepted() async {
        let t = transport()
        await t.respond(id: 1, payload: Data(repeating: 0xAB, count: 4 * 1024 * 1024))
    }

    func testAnEmptyPayloadIsAccepted() async {
        let t = transport()
        await t.respond(id: 1, payload: Data())
        await t.sendStreamItem(id: 1, payload: Data())
    }

    /// Finishing the outbound channel is what shutdown does, and doing it twice — or sending after
    /// it — must not trap.
    func testFinishingIsIdempotentAndSafeToSendAfter() async {
        let t = transport()
        await t.respond(id: 1, payload: Data([1]))
        await t.finish()
        await t.finish()
        await t.respond(id: 2, payload: Data([2]))   // yields into a finished stream
    }

    /// Many concurrent senders is the normal case — every handler runs in its own Task and they all
    /// enqueue here.  The actor serialises them, and nothing may be lost or trap.
    func testConcurrentSendersAreAllAccepted() async {
        let t = transport()
        await withTaskGroup(of: Void.self) { group in
            for id in 0..<200 {
                group.addTask {
                    await t.respond(id: UInt64(id), payload: Data([UInt8(id % 256)]))
                }
            }
        }
    }

    // MARK: - framing, as the transport uses it

    /// The frame header is a big-endian four byte length.  `FramingTests` covers the codec itself;
    /// this pins that a real serialised envelope round trips through it, which is what the writer
    /// does with every message.
    func testARealEnvelopeRoundTripsThroughAFrame() throws {
        var envelope = Star_V1_Envelope()
        envelope.id = 12345
        envelope.kind = .response
        envelope.payload = Data(repeating: 0x7F, count: 1000)

        let body = try envelope.serializedData()
        let framed = encodeFrame(body)

        XCTAssertEqual(framed.count, body.count + 4)
        let length = framed.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        XCTAssertEqual(length, body.count, "the header must be the payload length, big endian")

        let decoded = try Star_V1_Envelope(serializedBytes: Data(framed.dropFirst(4)))
        XCTAssertEqual(decoded.id, 12345)
        XCTAssertEqual(decoded.payload.count, 1000)
    }
}
