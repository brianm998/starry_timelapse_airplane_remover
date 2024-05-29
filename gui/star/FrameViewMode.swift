import Foundation

// different ways that an individual frame from a sequence can be displayed
public enum FrameViewMode: String, Equatable, CaseIterable {
    case original               // source frame with no changes
    case subtraction            // the result of subtracting an aligned neighbor frame
    case blobs                  // blobs detected from the subtraction frame
    case absorbedBlobs          // further blob processing
    case rectifiedBlobs         // ..
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
        case .absorbedBlobs:
            return .absorbed
        case .rectifiedBlobs:
            return .rectified
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
        case .absorbedBlobs:
            return "asb"
        case .rectifiedBlobs:
            return "rect"
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
        case .absorbedBlobs:
            return "blobs after the absorber"
        case .rectifiedBlobs:
            return "rectified blobs"
        case .paintMask:
            return "computed paint mask"
        case .validation:
            return "validation data"
        case .processed:
            return "processed frame"
        }
    }
}
