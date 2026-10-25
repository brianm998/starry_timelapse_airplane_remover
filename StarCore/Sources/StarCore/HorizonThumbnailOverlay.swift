import Foundation

// MARK: - HorizonThumbnailOverlay

/// A scaled-down representation of one of a frame's horizon lines, used to draw a coloured
/// stroke over a filmstrip cell, a grid cell or the frame itself.
///
/// A frame can have one of each kind; `FrameHorizonProcessor.loadHorizonThumbnailOverlays`
/// returns every one it has, and the clients draw the kinds the user has switched on.  Where
/// only one line is wanted, the one the final composite reads wins: reference (green) >
/// consensus (purple) > merged (blue) > initial (white).
public struct HorizonThumbnailOverlay: Sendable {

    /// Which horizon source produced this overlay, determining the stroke colour.  Each is
    /// the line of one horizon view mode (`viewMode`).
    public enum Kind: String, Sendable, CaseIterable, Hashable, Codable {
        /// Initial per-frame detected horizon (`.horizon` mask) — draw white.
        case initial
        /// Median-merged horizon from neighbours (`.mergedHorizon` mask) — draw blue.
        case merged
        /// A moving sequence's horizon consensus (`.consensusHorizon`), which the outlier
        /// subtraction and the composite use in place of the merged mask — draw purple.
        case consensus
        /// User-painted reference horizon (`horizonReference/` file) — draw green.
        case reference

        /// The view mode that shows this kind's mask.
        public var viewMode: FrameViewMode {
            switch self {
            case .initial:   .horizon
            case .merged:    .mergedHorizon
            case .consensus: .consensusHorizon
            case .reference: .userHorizon
            }
        }

        /// Which of several lines the composite reads, highest first.
        public var compositePriority: Int {
            switch self {
            case .reference: 3
            case .consensus: 2
            case .merged:    1
            case .initial:   0
            }
        }
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

extension Array where Element == HorizonThumbnailOverlay {
    /// The line the final composite reads, of those here.
    public var compositeLine: HorizonThumbnailOverlay? {
        self.max { $0.kind.compositePriority < $1.kind.compositePriority }
    }

    /// The kinds present.
    public var kinds: Set<HorizonThumbnailOverlay.Kind> { Set(map(\.kind)) }

    /// The lines of `visible` kinds, in drawing order: lowest composite priority first, so
    /// the line the composite reads is drawn last, on top.
    public func drawn(_ visible: Set<HorizonThumbnailOverlay.Kind>) -> [HorizonThumbnailOverlay] {
        filter { visible.contains($0.kind) }
          .sorted { $0.kind.compositePriority < $1.kind.compositePriority }
    }
}
