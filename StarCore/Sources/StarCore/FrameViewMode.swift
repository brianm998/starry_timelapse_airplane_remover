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
    case horizon                // computed horizon mask
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
            "original"
        case .subtraction:
            "subtracted"
        case .blobs:
            "blob"
        case .removeMask:
            "rmask"
        case .validation:
            "valid"
        case .processed:
            "processed"
        case .aligned:
            "aligned"
        case .horizon:
            "horizon"
        }
    }

    public var longName: String {
        switch self {
        case .original:
            "original frame"
        case .subtraction:
            "subtracted frame"
        case .blobs:
            "initially detected blobs"
        case .removeMask:
            "computed removal mask"
        case .validation:
            "validation data"
        case .processed:
            "processed frame"
        case .aligned:
            "aligned frame"
        case .horizon:
            "horizon mask"
        }
    }
}
