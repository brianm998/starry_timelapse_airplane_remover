import Foundation

// MARK: - HorizonThumbnailOverlay

/// A scaled-down representation of a frame's best-available horizon line,
/// used to draw a coloured stroke overlay on filmstrip thumbnails.
///
/// Priority for which mask is shown: reference (green) > merged (blue) > initial (white).
public struct HorizonThumbnailOverlay: Sendable {

    /// Which horizon source produced this overlay, determining the stroke colour.
    public enum Kind: Sendable {
        /// Initial per-frame detected horizon (`.horizon` mask) — draw white.
        case initial
        /// Median-merged horizon from neighbours (`.mergedHorizon` mask) — draw blue.
        case merged
        /// User-painted reference horizon (`horizonReference/` file) — draw green.
        case reference
    }

    /// Which source this overlay came from.
    public let kind: Kind

    /// Per-column horizon Y in **thumbnail** pixel coordinates.
    /// Length == thumbnailWidth; every column is filled (edge-extrapolated).
    public let yPerColumn: [Int]

    /// The thumbnail height this overlay was computed at.
    /// Use this (not the current canvas height) as the divisor when computing scaleY.
    public let height: Int
}
