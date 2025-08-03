import Foundation

public enum FrameRate: Equatable, CaseIterable, Hashable {
    case fps_24
    case fps_25
    case fps_30
    case fps_50
    case fps_60
    case fps_23_976
    case fps_29_97
    case fps_59_94
    case custom(Double)
    
    public var rawValue: Double {
        switch self {
        case .fps_24:
            24
        case .fps_25:
            25
        case .fps_30:
            30
        case .fps_50:
            50
        case .fps_60:
            60
        case .fps_23_976:
            23.976
        case .fps_29_97:
            29.97
        case .fps_59_94:
            59.94
        case .custom(let value):
            value
        }
    }

    public init(rawValue: Double) {
        switch rawValue {
        case 24:
            self = .fps_24
        case 25:
            self = .fps_25
        case 30:
            self = .fps_30
        case 50:
            self = .fps_50
        case 60:
            self = .fps_60
        case 23.976:
            self = .fps_23_976
        case 29.97:
            self = .fps_29_97
        case 59.94:
            self = .fps_59_94
        default:
            self = .custom(rawValue)
        }
    }

    public static var allCases: [FrameRate] {
        [.fps_24, .fps_25, .fps_30, .fps_50, .fps_60, .fps_23_976, .fps_29_97, .fps_59_94, .custom(24)]
    }
    
    public var description: String {
        switch self {
        case .fps_24:
            "Cinema standard. Most movies and scripted content."
        case .fps_25:
            "PAL video standard (Europe, parts of Asia/Africa)."
        case .fps_30:
            "NTSC standard (North America, Japan); also used for YouTube, streaming."
        case .fps_50:
            "High frame rate for PAL; used in sports and smooth motion."
        case .fps_60:
            "High frame rate for NTSC; used in gaming, sports, YouTube, and modern broadcasts."
        case .fps_23_976:
            "Actual frame rate used in digital cinema and Blu-ray (approximation of 24 fps)."
        case .fps_29_97:
            "NTSC broadcast frame rate (drop-frame). Common in TV and DVDs."
        case .fps_59_94:
            "Double of 29.97; used for high frame rate NTSC broadcasting."
        case .custom(_):
            "Any Custom frame rate you desire"
        }
    }
}
