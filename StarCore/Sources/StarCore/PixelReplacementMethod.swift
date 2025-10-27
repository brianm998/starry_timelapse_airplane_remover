import Foundation

// An enum that determines our top level processing mode

public enum PixelReplacementMethod: Sendable, Codable {
    case automatic
    case selective

    var description: String {
        switch self {
        case .automatic:
"""
The automatic pixel replacement method simply either returns the star aligned image directly, or if horizon detection is enabled, returns ths star aligned image masked by the horizon mask with the earth aligned image used based upon that mask.
"""
        case .selective:
"""
The selective method takes the aligned image(s) as a starting point, and with them, computes a subtraction image for each frame, where the aligned image is litereally subtracted from the frame being processed.  This makes most of the bad signal show up a lot more.

From the subtraction image, groups of nearby bright pixels are assembled into groups, and hough line detection is used to attempt to see what pixel group are linear or not.

Decision tree logic is then used to separate these outlying pixels into three groups:

1 - trash
2 - not replaced
3 - replaced
"""
        }
    }
}
