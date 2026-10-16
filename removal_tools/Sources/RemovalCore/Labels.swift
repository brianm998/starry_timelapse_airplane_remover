import Foundation

public enum TrailClass: String, Codable, Sendable {
    case airplane, satellite, meteor, other
}

public struct LabelObject: Codable, Sendable {
    public var id: String
    public var `class`: TrailClass
    /// A polyline in full-resolution input pixel coordinates.
    public var points: [[Double]]
    /// The trail's full width in pixels.
    public var width: Double
    public var confirmed: Bool
    public var note: String?

    public init(id: String, class cls: TrailClass, points: [[Double]], width: Double,
                confirmed: Bool, note: String? = nil) {
        self.id = id; self.class = cls; self.points = points; self.width = width
        self.confirmed = confirmed; self.note = note
    }

    public var polyline: [Point] { points.compactMap { $0.count == 2 ? Point(x: $0[0], y: $0[1]) : nil } }
}

public struct LabelSet: Codable, Sendable {
    public var version: Int
    /// Keyed by input file name, e.g. "LRT_00092.jpg".
    public var frames: [String: [LabelObject]]
    public var sky: [[Double]]?
    public var complete: Bool?

    public init(version: Int = 1, frames: [String: [LabelObject]], sky: [[Double]]? = nil,
                complete: Bool? = nil) {
        self.version = version; self.frames = frames; self.sky = sky; self.complete = complete
    }

    public var skyPolygon: [Point]? {
        guard let sky, sky.count >= 3 else { return nil }
        return sky.compactMap { $0.count == 2 ? Point(x: $0[0], y: $0[1]) : nil }
    }

    public static func load(from url: URL) throws -> LabelSet {
        let set = try JSONDecoder().decode(LabelSet.self, from: Data(contentsOf: url))
        guard set.version == 1 else { throw VerifyError.badInput("labels version \(set.version) unsupported") }
        for (frame, objs) in set.frames {
            for o in objs where o.polyline.count < 2 || o.polyline.count != o.points.count || o.width <= 0 {
                throw VerifyError.badInput("\(frame): object \(o.id) needs >= 2 [x,y] points and width > 0")
            }
        }
        return set
    }

    /// Match key: file name without directory or extension (Star keeps the base name).
    public static func baseName(_ file: String) -> String {
        ((file as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

public enum VerifyError: Error, CustomStringConvertible {
    /// Maps to exit code 2.
    case badInput(String)
    public var description: String {
        switch self { case .badInput(let s): return s }
    }
}
