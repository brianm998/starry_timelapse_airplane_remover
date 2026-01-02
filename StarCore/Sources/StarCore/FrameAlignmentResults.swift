import Foundation

public struct FrameAlignmentResults: Codable, Sendable {
    public let numberAligned: [AlignmentWarpInfoCodable]
    public let numberFailed: [AlignmentWarpInfoCodable]

    public var total: Int { numberAligned.count + numberFailed.count }
}

