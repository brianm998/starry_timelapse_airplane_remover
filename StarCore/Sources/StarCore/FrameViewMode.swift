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
    case userHorizon            // user-defined horizon mask from horizonReference/
    case consensusHorizon       // a moving sequence's horizon consensus, drawn as a mask
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
        case .horizon, .mergedHorizon, .userHorizon, .consensusHorizon: true
        default: false
        }
    }

    /// True for full-size intermediates that are only a cache: when one is missing or
    /// fails to decode, `loadOrCreateAlignedImage` recomputes it. They are written
    /// uncompressed and without fsync (see `PixelatedImage.writeCacheTIFF`), and in the
    /// default mode not at all, because nothing reads them back.
    public var isRecomputableCache: Bool {
        switch self {
        case .starAligned, .earthAligned: true
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
        case .userHorizon:
            "userHorizon"
        case .consensusHorizon:
            "consensusHorizon"
        }
    }

    /// The mode's name in the user's language, from the catalogue (`view_mode.<case name>`, which the desktop client reads too).
    /// It was a switch of English literals, so every picker and "not found" line of the gui said "final processed frame" in any language.
    public var longName: String {
        localized("view_mode.\(rawValue)")
    }
}
