import Foundation
import StarDaemonMessages
import SwiftProtobuf
import logging

#if os(Windows)
import ucrt
#endif

// MARK: - Protocol FD isolation
//
// The binary frame stream must NOT ride on the process-wide stdout (fd 1), because any code in the
// process — StarCore, OpenCV, a dependency, a stray print()/Log — can write to fd 1 and corrupt the
// stream (this caused a real hang: log text interleaved into frames, the client desynced). JVM
// ProcessBuilder can't hand the child an extra FD portably, and the design rules out sockets for
// Windows, so we isolate the protocol *inside* stard:
//
//   1. dup() the real stdin/stdout (the pipes the parent connected) to PRIVATE fds — the protocol
//      reads/writes only these.
//   2. Redirect fd 1 (stdout) → fd 2 (stderr) and fd 0 (stdin) → /dev/null, so any generic
//      read/write on the process-wide std streams can never touch the protocol.
//
// The client side is unchanged: it still reads the child's stdout pipe, which now carries only
// frames (written via the private dup of the original fd 1).

// Set once in setupProtocolIO() before the reader/writer ever run, then only read — hence
// nonisolated(unsafe) (no concurrent mutation to guard).
nonisolated(unsafe) private var inHandle  = FileHandle.standardInput
nonisolated(unsafe) private var outHandle = FileHandle.standardOutput

// Call ONCE at startup, before any logging or I/O.
func setupProtocolIO() {
#if os(Windows)
    let O_BINARY: Int32 = 0x8000
    let inFD  = _dup(_fileno(stdin))
    let outFD = _dup(_fileno(stdout))
    _ = _setmode(inFD,  O_BINARY)
    _ = _setmode(outFD, O_BINARY)
    _ = _dup2(_fileno(stderr), _fileno(stdout))           // stray stdout writes → stderr
    let nul = _open("NUL", 0 /* _O_RDONLY */)
    if nul >= 0 { _ = _dup2(nul, _fileno(stdin)); _ = _close(nul) } // stray stdin reads → EOF
    inHandle  = FileHandle(fileDescriptor: inFD,  closeOnDealloc: false)
    outHandle = FileHandle(fileDescriptor: outFD, closeOnDealloc: false)
#else
    let inFD  = dup(0)
    let outFD = dup(1)
    _ = dup2(2, 1)                                          // stray stdout writes → stderr
    let devnull = open("/dev/null", O_RDONLY)
    if devnull >= 0 { _ = dup2(devnull, 0); close(devnull) } // stray stdin reads → EOF
    inHandle  = FileHandle(fileDescriptor: inFD,  closeOnDealloc: false)
    outHandle = FileHandle(fileDescriptor: outFD, closeOnDealloc: false)
#endif
}

// MARK: - Framing primitives (validated per §6.3)

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
