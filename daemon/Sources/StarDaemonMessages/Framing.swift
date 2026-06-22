import Foundation

// Pure (FileHandle-free) framing helpers used by both the daemon and tests.
// The wire format is a 4-byte big-endian unsigned length followed by that many
// payload bytes (§5.1 of CROSS_PLATFORM_DAEMON_DESIGN.md).

public func encodeFrame(_ payload: Data) -> Data {
    let n = UInt32(payload.count).bigEndian
    var out = Data(count: 4 + payload.count)
    withUnsafeBytes(of: n) { out.replaceSubrange(0..<4, with: $0) }
    out.replaceSubrange(4..., with: payload)
    return out
}

// Decode a frame from a contiguous Data buffer (used in tests and for
// building mock transports). Returns the payload bytes, or nil if the
// buffer is too short or malformed.
public func decodeFrame(from buffer: Data) -> Data? {
    guard buffer.count >= 4 else { return nil }
    let lenBytes = buffer.prefix(4)
    let len = lenBytes.reduce(0) { ($0 << 8) | Int($1) }
    guard buffer.count >= 4 + len else { return nil }
    return buffer.subdata(in: 4..<(4 + len))
}
