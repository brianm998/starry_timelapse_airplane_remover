import Foundation
import StarCore
import StarCppBridge
import RemovalCore

/// Decoding goes through StarCore's PixelatedImage so files are read exactly as Star reads them.
public enum ImageIO {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "tif", "tiff", "png"]

    public static func imageFiles(in dir: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) && !$0.hasPrefix(".") }
            .sorted()
    }

    /// Pixel values normalised to 0...1; channel order is whatever OpenCV gave (BGR).
    public static func load(_ path: String) throws -> (raster: Raster, bitDepth: Int) {
        guard let img = PixelatedImage(filename: path) else {
            throw VerifyError.badInput("cannot read image \(path)")
        }
        let w = img.width, h = img.height, c = img.componentsPerPixel
        var data = [Float](repeating: 0, count: w * h * c)
        switch img.imageData {
        case .eightBit(let buf):
            let stride = img.bytesPerRow
            for y in 0..<h { for i in 0..<(w * c) { data[y * w * c + i] = Float(buf[y * stride + i]) / 255 } }
            return (Raster(width: w, height: h, channels: c, data: data), 8)
        case .sixteenBit(let buf):
            let stride = img.bytesPerRow / 2
            for y in 0..<h { for i in 0..<(w * c) { data[y * w * c + i] = Float(buf[y * stride + i]) / 65535 } }
            return (Raster(width: w, height: h, channels: c, data: data), 16)
        case .thirtyTwoBit:
            throw VerifyError.badInput("\(path): 32-bit images are not supported")
        }
    }

    /// Writes 16-bit (or 8-bit) by file extension; format comes from the extension.
    public static func save(_ r: Raster, to path: String, bitDepth: Int) throws {
        let n = r.width * r.height * r.channels
        let type: Int32 = bitDepth == 16 ? (r.channels == 1 ? 2 : 18) : (r.channels == 1 ? 0 : 16)
        let bytes = bitDepth == 16 ? 2 : 1
        let raw = UnsafeMutableRawPointer.allocate(byteCount: n * bytes, alignment: 16)
        if bitDepth == 16 {
            let p = raw.bindMemory(to: UInt16.self, capacity: n)
            for i in 0..<n { p[i] = UInt16(max(0, min(65535, (r.data[i] * 65535).rounded()))) }
        } else {
            let p = raw.bindMemory(to: UInt8.self, capacity: n)
            for i in 0..<n { p[i] = UInt8(max(0, min(255, (r.data[i] * 255).rounded()))) }
        }
        // the Mat takes ownership and frees the buffer
        let mat = MatWrapper(width: r.width, height: r.height, cvType: type,
                             bytesPerRow: r.width * r.channels * bytes, data: raw, takeOwnership: true)
        guard mat.write(to: path) else { throw VerifyError.badInput("cannot write \(path)") }
    }
}
