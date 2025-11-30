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
    case mergedHorizon          // median merged and maybe aligned horizon mask from neighbors
    case starAligned            // star aligned neighbor frame
    case failedStarAligned      // failed star aligned neighbor frame
    case earthAligned           // earth aligned neighbor frame
    case subtraction            // the result of subtracting a star aligned neighbor frame
    case blobs                  // blobs detected from the subtraction frame
    case validation             // an image of exactly what pixels have been identified as unwanted
    case removeMask             // the remove mask created from the validation image
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
        case .starAligned:
            "starAligned"
        case .failedStarAligned:
            "failedStarAligned"
        case .earthAligned:
            "earthAligned"
        case .horizon:
            "horizon"
        case .mergedHorizon:
            "mergedHorizon"
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
        case .earthAligned:
            "earth aligned frame"
        case .starAligned:
            "star aligned frame"
        case .failedStarAligned:
            "failed star align frame"
        case .horizon:
            "horizon mask"
        case .mergedHorizon:
            "merged horizon"
        }
    }
}
