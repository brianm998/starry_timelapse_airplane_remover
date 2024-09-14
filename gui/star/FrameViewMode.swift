import Foundation
import SwiftUI
import StarCore

// different ways that an individual frame from a sequence can be displayed
public enum FrameViewMode: String, Equatable, CaseIterable {
    case original               // source frame with no changes
    case subtraction            // the result of subtracting an aligned neighbor frame
    case blobs                  // blobs detected from the subtraction frame
    case filter1                // further blob processing
    case filter2                // ..
    case filter3                // ..
    case filter4                // ..
    case filter5                // ..
    case filter6                // ..
    case validation             // an image of exactly what pixels have been identified as unwanted
    case paintMask              // the paint mask created from the validation image
    case processed              // the final processed image, 
                                // the paint mask is used as a layer mask for the aligned neighbor 

    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }

    var frameImageType: FrameImageType { // these two enums should probably be one
        switch self {
        case .original:
            return .original
        case .subtraction:
            return .subtracted
        case .blobs:
            return .blobs
        case .filter1:
            return .filter1
        case .filter2:
            return .filter2
        case .filter3:
            return .filter3
        case .filter4:
            return .filter4
        case .filter5:
            return .filter5
        case .filter6:
            return .filter6
        case .paintMask:
            return .paintMask
        case .validation:
            return .validated
        case .processed:
            return .processed
        }
    }
    
    var shortName: String {
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
        case .paintMask:
            return "pmask"
        case .validation:
            return "valid"
        case .processed:
            return "proc"
        }
    }

    var longName: String {
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
        case .paintMask:
            return "computed paint mask"
        case .validation:
            return "validation data"
        case .processed:
            return "processed frame"
        }
    }
}
