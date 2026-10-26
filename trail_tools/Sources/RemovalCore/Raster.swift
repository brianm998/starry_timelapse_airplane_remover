import Foundation

/// A decoded image, values normalised to 0...1 (8-bit / 255, 16-bit / 65535), interleaved channels.
public struct Raster: Sendable {
    public let width: Int
    public let height: Int
    public let channels: Int
    public var data: [Float]

    public init(width: Int, height: Int, channels: Int, data: [Float]) {
        precondition(data.count == width * height * channels)
        self.width = width; self.height = height; self.channels = channels; self.data = data
    }

    public init(width: Int, height: Int, channels: Int = 1, fill: Float = 0) {
        self.init(width: width, height: height, channels: channels,
                  data: [Float](repeating: fill, count: width * height * channels))
    }

    /// Mean of the channels at each pixel: the "brightness" every measurement uses.
    public var brightness: Plane {
        if channels == 1 { return Plane(width: width, height: height, data: data) }
        var out = [Float](repeating: 0, count: width * height)
        let inv = 1 / Float(channels)
        for i in 0..<(width * height) {
            var s: Float = 0
            for c in 0..<channels { s += data[i * channels + c] }
            out[i] = s * inv
        }
        return Plane(width: width, height: height, data: out)
    }
}

/// A single-channel float image.
public struct Plane: Sendable {
    public let width: Int
    public let height: Int
    public var data: [Float]

    public init(width: Int, height: Int, data: [Float]) {
        precondition(data.count == width * height)
        self.width = width; self.height = height; self.data = data
    }

    public init(width: Int, height: Int, fill: Float = 0) {
        self.init(width: width, height: height, data: [Float](repeating: fill, count: width * height))
    }

    @inline(__always) public subscript(x: Int, y: Int) -> Float {
        get { data[y * width + x] }
        set { data[y * width + x] = newValue }
    }

    public func minus(_ other: Plane) -> Plane {
        precondition(width == other.width && height == other.height)
        var out = data
        for i in 0..<out.count { out[i] -= other.data[i] }
        return Plane(width: width, height: height, data: out)
    }
}

public enum Stats {
    public static func median(_ values: [Float]) -> Float {
        if values.isEmpty { return .nan }
        var v = values
        let mid = v.count / 2
        v.sort()
        return v.count % 2 == 1 ? v[mid] : (v[mid - 1] + v[mid]) / 2
    }

    /// Robust sigma: 1.4826 × median absolute deviation.
    public static func madSigma(_ values: [Float]) -> Float {
        if values.isEmpty { return .nan }
        let m = median(values)
        return 1.4826 * median(values.map { abs($0 - m) })
    }

    /// p in 0...1, linear interpolation on the sorted values.
    public static func percentile(_ sorted: [Float], _ p: Double) -> Float {
        if sorted.isEmpty { return .nan }
        let pos = p * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        let f = Float(pos - Double(lo))
        return sorted[lo] * (1 - f) + sorted[hi] * f
    }
}
