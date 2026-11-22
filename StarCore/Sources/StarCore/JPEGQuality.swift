import Foundation

/// The quality a JPEG was written at, read back from its quantisation table.
public enum JPEGQuality {
    /// What OpenCV writes when nothing is known, and what star always wrote before.
    public static let fallback = 95

    /// The IJG standard luminance table (natural order) that quality 50 uses.
    private static let standardLuminance: [Int] = [
        16, 11, 10, 16, 24, 40, 51, 61,
        12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56,
        14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77,
        24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101,
        72, 92, 95, 98, 112, 100, 103, 99,
    ]

    /// Quality from the first DQT table of the JPEG at `path`, or nil if it is not a JPEG or has none.
    public static func estimate(atPath path: String) -> Int? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // The tables sit before the frame header; 64 KB covers any sane header (EXIF can be most of that).
        guard let data = try? handle.read(upToCount: 1 << 17), data.count > 4 else { return nil }
        return estimate(header: [UInt8](data))
    }

    static func estimate(header b: [UInt8]) -> Int? {
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }              // fill byte
            if marker == 0xD9 || marker == 0xDA { return nil }  // end / start of scan: no table seen
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2 else { return nil }
            if marker == 0xDB {
                let end = min(i + 2 + length, b.count)
                var p = i + 4
                while p < end {
                    let precision = Int(b[p] >> 4), id = Int(b[p] & 0x0F)
                    let size = precision == 0 ? 64 : 128
                    guard p + 1 + size <= b.count else { return nil }
                    if id == 0 {
                        let zigzag = zigzagOrder
                        var sum = 0.0
                        for k in 0..<64 {
                            let q = precision == 0 ? Int(b[p + 1 + k])
                                                   : Int(b[p + 1 + 2 * k]) << 8 | Int(b[p + 2 + 2 * k])
                            sum += Double(q) * 100.0 / Double(standardLuminance[zigzag[k]])
                        }
                        let scale = sum / 64.0
                        let quality = scale <= 100 ? (200 - scale) / 2 : 5000 / scale
                        return min(max(Int(quality.rounded()), 1), 100)
                    }
                    p += 1 + size
                }
            }
            i += 2 + length
        }
        return nil
    }

    private static let zigzagOrder: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]

    /// The sidecar's quality when the folder is a JPEG video import, else the first frame's estimate, else nil.
    public static func ofSequence(folder: String?, firstFramePath: String?) -> Int? {
        if let folder, let sidecar = FrameExtractionSidecar.read(inFolder: folder),
           sidecar.format.kind == .jpeg {
            return sidecar.format.jpegQuality
        }
        if let firstFramePath {
            let ext = (firstFramePath as NSString).pathExtension.lowercased()
            if ext == "jpg" || ext == "jpeg" { return estimate(atPath: firstFramePath) }
        }
        return nil
    }
}
