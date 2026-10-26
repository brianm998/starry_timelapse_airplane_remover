import Foundation

/// Minimal PNG writer (8-bit RGB, stored deflate blocks) so crops need no image library.
public enum PNG {
    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    private static func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let t = Array(type.utf8)
        return be32(UInt32(body.count)) + t + body + be32(crc32(t + body))
    }

    public static func encode(rgb: [UInt8], width: Int, height: Int) -> Data {
        var raw: [UInt8] = []; raw.reserveCapacity((width * 3 + 1) * height)
        for y in 0..<height {
            raw.append(0)
            raw.append(contentsOf: rgb[(y * width * 3)..<((y + 1) * width * 3)])
        }
        var z: [UInt8] = [0x78, 0x01]
        var pos = 0
        repeat {
            let n = min(65535, raw.count - pos)
            let last: UInt8 = pos + n >= raw.count ? 1 : 0
            z += [last, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)]
            z += raw[pos..<(pos + n)]
            pos += n
        } while pos < raw.count
        var a: UInt32 = 1, b: UInt32 = 0
        for v in raw { a = (a + UInt32(v)) % 65521; b = (b + a) % 65521 }
        z += be32((b << 16) | a)
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        out += chunk("IHDR", be32(UInt32(width)) + be32(UInt32(height)) + [8, 2, 0, 0, 0])
        out += chunk("IDAT", z)
        out += chunk("IEND", [])
        return Data(out)
    }
}

public enum Crops {
    /// input | output | difference, side by side, auto-levelled per panel (0.5–99.5 percentile).
    public static func sideBySide(input: Plane, output: Plane, x0: Int, y0: Int, x1: Int, y1: Int) -> Data {
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        func panel(_ get: (Int, Int) -> Float) -> [UInt8] {
            var vals: [Float] = []; vals.reserveCapacity(w * h)
            for y in y0...y1 { for x in x0...x1 { vals.append(get(x, y)) } }
            let s = vals.sorted()
            let lo = Stats.percentile(s, 0.005), hi = Stats.percentile(s, 0.995)
            let span = max(hi - lo, 1e-9)
            return vals.map { UInt8(max(0, min(255, (($0 - lo) / span) * 255))) }
        }
        let a = panel { input[$0, $1] }
        let b = panel { output[$0, $1] }
        let d = panel { abs(input[$0, $1] - output[$0, $1]) }
        let gap = 4
        let totalW = w * 3 + gap * 2
        var rgb = [UInt8](repeating: 255, count: totalW * h * 3)
        for y in 0..<h {
            for (k, p) in [a, b, d].enumerated() {
                for x in 0..<w {
                    let v = p[y * w + x]
                    let o = (y * totalW + k * (w + gap) + x) * 3
                    rgb[o] = v; rgb[o + 1] = v; rgb[o + 2] = v
                }
            }
        }
        return PNG.encode(rgb: rgb, width: totalW, height: h)
    }
}
