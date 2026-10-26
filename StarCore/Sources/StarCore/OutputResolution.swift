import Foundation

/// The size a rendered video is scaled to, named by its height the way other video editors do.
/// `.original` leaves the frames at the size they have.
public enum OutputResolution: Equatable, CaseIterable, Hashable, Codable, Sendable {
    case original
    case p2160   // 4k
    case p1440   // 2k
    case p1080
    case p720
    case p480

    /// The height in pixels, 0 for `.original`.  This is what crosses the daemon's wire.
    public var height: Int {
        switch self {
        case .original: 0
        case .p2160: 2160
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        }
    }

    /// The resolution with this height, `.original` for 0 or a height that is none of ours.
    public init(height: Int) {
        self = Self.allCases.first { $0.height == height } ?? .original
    }

    /// How it is said on the command line: `original`, `4k`, `2k`, `1080p`, `720p`, `480p`.
    public var name: String {
        switch self {
        case .original: "original"
        case .p2160: "4k"
        case .p1440: "2k"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        }
    }

    /// Accepts `name`, a bare height such as `1080`, and `<height>p`; case does not matter.
    public init?(name: String) {
        let s = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let match = Self.allCases.first(where: { $0.name == s }) {
            self = match
            return
        }
        let digits = s.hasSuffix("p") ? String(s.dropLast()) : s
        guard let h = Int(digits), let match = Self.allCases.first(where: { $0.height == h && h > 0 }) else { return nil }
        self = match
    }

    /// The ffmpeg arguments that scale to this resolution: none for `.original`.  The width follows
    /// the aspect ratio, rounded to an even number as most encoders need.  A video already smaller
    /// than the height is left as it is, not blown up.
    public var ffmpegArguments: [String] {
        guard height > 0 else { return [] }
        return ["-vf", "scale=-2:'min(\(height),ih)'"]
    }
}
