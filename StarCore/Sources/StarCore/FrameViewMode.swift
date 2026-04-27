import Foundation
import logging
#if canImport(SwiftUI)
import SwiftUI
#endif


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
    case mergedHorizon          // median merged and maybe aligned horizon mask from neighbors
    case refinedHorizon         // homography alignment-drop refined horizon mask
    case userHorizon            // user-defined horizon mask from horizonReference/
    case starAligned            // star aligned neighbor frame
    case failedStarAligned      // failed star aligned neighbor frame
    case earthAligned           // earth aligned neighbor frame
    case failedEarthAligned     // failed earth aligned neighbor frame
    case subtraction            // the result of subtracting a star aligned neighbor frame
    case blobs                  // blobs detected from the subtraction frame
    case validation             // an image of exactly what pixels have been identified as unwanted
    case removeMask             // the remove mask created from the validation image
    case autoProcessed          // .automatic(false) CleanMode
    case autoSelectiveProcessed // .autoamtic(true) CleanMode
    case selectiveProcessed     // .selective CleanMode
    case final              // the final processed image, 
                                // the remove mask is used as a layer mask for the aligned neighbor
           
#if canImport(SwiftUI)
    public var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
#endif

    /// True for image types that represent horizon masks.
    /// These must always be CV_8UC1 (single-channel 8-bit grayscale).
    public var isHorizonMask: Bool {
        switch self {
        case .horizon, .mergedHorizon, .refinedHorizon, .userHorizon: true
        default: false
        }
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
        case .autoProcessed:
            "autoProcessed"
        case .autoSelectiveProcessed:
            "autoSelectiveProcessed"
        case .selectiveProcessed:
            "selectiveProcessed"
        case .final:
            "final"
        case .starAligned:
            "starAligned"
        case .failedStarAligned:
            "failedStarAligned"
        case .earthAligned:
            "earthAligned"
        case .failedEarthAligned:
            "failedEarthAligned"
        case .horizon:
            "horizon"
        case .mergedHorizon:
            "mergedHorizon"
        case .refinedHorizon:
            "refinedHorizon"
        case .userHorizon:
            "userHorizon"
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
        case .autoProcessed:
            "auto processed"
        case .autoSelectiveProcessed:
            "auto processed with selection"
        case .selectiveProcessed:
            "selective processed"
        case .final:
            "final processed frame"
        case .earthAligned:
            "earth aligned frame"
        case .failedEarthAligned:
            "failed earth aligned frame"
        case .starAligned:
            "star aligned frame"
        case .failedStarAligned:
            "failed star align frame"
        case .horizon:
            "horizon mask"
        case .mergedHorizon:
            "merged horizon"
        case .refinedHorizon:
            "homography refined horizon"
        case .userHorizon:
            "user defined horizon"
        }
    }
}
