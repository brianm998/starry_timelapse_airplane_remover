import Foundation
import CoreGraphics
import logging
import Cocoa
import SwiftUI


// different ways that an individual frame from a sequence can be displayed
public enum FrameViewMode: String,
                           Equatable,
                           CaseIterable,
                           Sendable,
                           Codable,
                           Identifiable
{
    public var id: Self { self }

    case original               // source frame with no changes
    case aligned                // aligned neighbor frame
    case subtraction            // the result of subtracting an aligned neighbor frame
    case blobs                  // blobs detected from the subtraction frame
    case validation             // an image of exactly what pixels have been identified as unwanted
    case removeMask              // the remove mask created from the validation image
    case processed              // the final processed image, 
                                // the remove mask is used as a layer mask for the aligned neighbor 
 
    public var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }

    public var shortName: String {
        switch self {
        case .original:
            return "original"
        case .subtraction:
            return "subtracted"
        case .blobs:
            return "blob"
        case .removeMask:
            return "rmask"
        case .validation:
            return "valid"
        case .processed:
            return "processed"
        case .aligned:
            return "aligned"
        }
    }

    public var longName: String {
        switch self {
        case .original:
            return "original frame"
        case .subtraction:
            return "subtracted frame"
        case .blobs:
            return "initially detected blobs"
        case .removeMask:
            return "computed removal mask"
        case .validation:
            return "validation data"
        case .processed:
            return "processed frame"
        case .aligned:
            return "aligned frame"
        }
    }
}
