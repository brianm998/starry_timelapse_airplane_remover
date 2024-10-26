import Foundation
import CoreGraphics
import logging
import Cocoa


// different ways that an individual frame from a sequence can be displayed
public enum FrameViewMode: String, Equatable, CaseIterable, Sendable {
    case original               // source frame with no changes
    case aligned                // aligned neighbor frame
    case subtraction            // the result of subtracting an aligned neighbor frame
    case blobs                  // blobs detected from the subtraction frame
    case filter1                // further blob processing
    case filter2                // ..
    case filter3                // ..
    case filter4                // ..
    case filter5                // ..
    case filter6                // ..
    case filter7                // ..
    case filter8                // ..
    case filter9                // ..
    case filter10               // ..
    case filter11               // ..
    case filter12               // ..
    case validation             // an image of exactly what pixels have been identified as unwanted
    case paintMask              // the paint mask created from the validation image
    case processed              // the final processed image, 
                                // the paint mask is used as a layer mask for the aligned neighbor 

    public var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }

    public var shortName: String {
        switch self {
        case .original:
            return "orig"
        case .subtraction:
            return "subt"
        case .blobs:
            return "blob"
        case .filter1:
            return "f1"
        case .filter2:
            return "f2"
        case .filter3:
            return "f3"
        case .filter4:
            return "f4"
        case .filter5:
            return "f5"
        case .filter6:
            return "f6"
        case .filter7:
            return "f7"
        case .filter8:
            return "f8"
        case .filter9:
            return "f9"
        case .filter10:
            return "f10"
        case .filter11:
            return "f11"
        case .filter12:
            return "f12"
        case .paintMask:
            return "pmask"
        case .validation:
            return "valid"
        case .processed:
            return "proc"
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
        case .filter1:
            return "blob filter level 1"
        case .filter2:
            return "blob filter level 2"
        case .filter3:
            return "blob filter level 3"
        case .filter4:
            return "blob filter level 4"
        case .filter5:
            return "blob filter level 5"
        case .filter6:
            return "blob filter level 6"
        case .filter7:
            return "blob filter level 7"
        case .filter8:
            return "blob filter level 8"
        case .filter9:
            return "blob filter level 9"
        case .filter10:
            return "blob filter level 10"
        case .filter11:
            return "blob filter level 11"
        case .filter12:
            return "blob filter level 12"
        case .paintMask:
            return "computed paint mask"
        case .validation:
            return "validation data"
        case .processed:
            return "processed frame"
        case .aligned:
            return "aligned frame"
        }
    }
}
