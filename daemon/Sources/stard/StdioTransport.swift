import Foundation
import StarDaemonMessages
import SwiftProtobuf
import logging

#if os(Windows)
import ucrt
#endif

// Called once at startup so Windows does not translate \n or treat 0x1A as EOF.
func setBinaryStdIO() {
    #if os(Windows)
    let O_BINARY: Int32 = 0x8000
    _ = _setmode(_fileno(stdin),  O_BINARY)
    _ = _setmode(_fileno(stdout), O_BINARY)
    #endif
}

// MARK: - Framing primitives (validated per §6.3)

private let inHandle  = FileHandle.standardInput
private let outHandle = FileHandle.standardOutput

private func readExactly(_ n: Int) -> Data? {
    var buf = Data()
    while buf.count < n {
        let chunk = inHandle.readData(ofLength: n - buf.count)
        if chunk.isEmpty { return nil }
        buf.append(chunk)
    }
    return buf
}

func readFrame() -> Data? {
    guard let lenBytes = readExactly(4) else { return nil }
    let len = lenBytes.reduce(0) { ($0 << 8) | Int($1) }
    return readExactly(len)
}

// writeFrame must only be called from the single writer task.
func writeFrame(_ data: Data) {
    let n = UInt32(data.count).bigEndian
    var header = Data(count: 4)
    withUnsafeBytes(of: n) { header.replaceSubrange(0..<4, with: $0) }
    outHandle.write(header)
    outHandle.write(data)
}

// MARK: - StdioTransport

// Owns the single outbound pipe writer and exposes send/sendStream helpers.
actor StdioTransport {
    // Outbound channel: all callers enqueue here; one writer task drains it.
    private let outCh: AsyncStream<Star_V1_Envelope>.Continuation
    private let outStream: AsyncStream<Star_V1_Envelope>

    init() {
        var cont: AsyncStream<Star_V1_Envelope>.Continuation!
        outStream = AsyncStream { cont = $0 }
        outCh = cont
    }

    // Start the single writer. Call once.
    func startWriter() {
        Task.detached(priority: .high) { [outStream] in
            for await envelope in outStream {
                do {
                    let data = try envelope.serializedData()
                    writeFrame(data)
                } catch {
                    Log.e("stard: failed to serialize envelope: \(error)")
                }
            }
        }
    }

    // Enqueue one envelope onto the serialized writer.
    func send(_ envelope: Star_V1_Envelope) {
        outCh.yield(envelope)
    }

    // Send a RESPONSE envelope for the given request id.
    func respond(id: UInt64, payload: Data) {
        var env = Star_V1_Envelope()
        env.id = id
        env.kind = .response
        env.payload = payload
        send(env)
    }

    // Send an ERROR envelope for the given request id.
    func sendError(id: UInt64, message: String, code: Int32 = 0) {
        var env = Star_V1_Envelope()
        env.id = id
        env.kind = .error
        env.error = message
        env.errorCode = code
        send(env)
    }

    // Send one STREAM_ITEM for the given request id.
    func sendStreamItem(id: UInt64, payload: Data) {
        var env = Star_V1_Envelope()
        env.id = id
        env.kind = .streamItem
        env.payload = payload
        send(env)
    }

    // Send STREAM_END for the given request id.
    func sendStreamEnd(id: UInt64) {
        var env = Star_V1_Envelope()
        env.id = id
        env.kind = .streamEnd
        send(env)
    }

    // Finish the outbound channel (called on graceful shutdown).
    func finish() {
        outCh.finish()
    }
}
