import Foundation
import logging

/// Which frames each stage of the frame graph runs on, for one call to
/// `FrameGraphBuilder.build(frames:startIndex:endIndex:closure:errorClosure:)`.
///
/// A partial range cannot simply be handed to every stage.  Only the frames inside
/// the requested range get an output image written, but a frame at the edge of that
/// range is aligned against — and merged from — neighbours outside it, so those
/// neighbours need keypoints, and the horizon masks the keypoint stage masks with,
/// even though nothing is ever written for them.
///
/// Restricting the alignment stages to the requested range as well would not skip
/// that work, only move it somewhere worse: `FrameAlignmentProcessor`'s
/// `loadOrCreateHomography` detects any keypoints it is missing inline, and the
/// `KeypointLimiter` exists precisely because concurrent full-resolution SIFT is
/// what sets a 42MP run's peak memory.
///
/// All three lists are sorted, hold only frame indices the sequence actually
/// contains, and are empty together — see `isEmpty`.
struct FrameGraphRange {

    /// Frames we produce output for: an outlier op, a merge op, the homography that
    /// merge warps its neighbours with, and a dependency from the completion barrier.
    let output: [Int]

    /// Frames we detect keypoints for: `output`, plus every frame those align against.
    let keypoint: [Int]

    /// Frames we detect and merge a horizon for: `keypoint`, plus every frame whose
    /// first-round mask feeds one of their merged masks.
    let horizon: [Int]

    /// True when the requested range selects no frame at all: an empty sequence, a
    /// `startIndex` past the end of it, or an `endIndex` below `startIndex`.
    ///
    /// Callers must report this instead of building a graph.  Each of those three
    /// cases used to become an inverted `startIndex...lastIndex` and trap.
    var isEmpty: Bool { output.isEmpty }

    /// - Parameters:
    ///   - sequenceIndices: the `frameIndex` of every frame the caller passed, in any
    ///     order.  Frame indices are not array indices, so an index missing from here
    ///     is dropped from every list rather than looked up positionally.
    ///   - startIndex: first frame index to produce output for.
    ///   - endIndex: last frame index to produce output for, inclusive; `nil` means
    ///     the end of the sequence.
    ///   - alignmentNeighbours: for each frame index, the frames it aligns against
    ///     (`FrameAirplaneRemover.getAlignmentFrameIndices()`).  This is what widens
    ///     `keypoint` past `output`.
    ///   - horizonMergeNeighbours: for each frame index, the frames whose horizon
    ///     masks are merged into its own
    ///     (`FrameAirplaneRemover.getHorizonMergeIndices()`).  This is what widens
    ///     `horizon` past `keypoint`.  Pass an empty map for a static sequence: it
    ///     has a single merge op that votes over the whole sequence and loads any
    ///     mask it was not handed from disk, so there is nothing to widen.
    init(
      sequenceIndices: [Int],
      startIndex: Int,
      endIndex: Int?,
      alignmentNeighbours: [Int: [Int]],
      horizonMergeNeighbours: [Int: [Int]]
    ) {
        let available = Set(sequenceIndices)

        guard let maxFrameIndex = available.max() else {
            // no frames at all
            self.output = []
            self.keypoint = []
            self.horizon = []
            return
        }

        // `endIndex` is a frame index, so cap it at the largest index we actually
        // hold, not at `sequenceIndices.count - 1`.
        let lastIndex = min(endIndex ?? maxFrameIndex, maxFrameIndex)

        // Filtering the indices we hold, rather than walking `startIndex...lastIndex`,
        // is what makes an inverted or out-of-bounds request an empty set instead of a
        // trap.
        let outputSet = available.filter { $0 >= startIndex && $0 <= lastIndex }

        guard !outputSet.isEmpty else {
            self.output = []
            self.keypoint = []
            self.horizon = []
            return
        }

        // Both neighbour lists arrive already clamped to the sequence bounds by
        // `FrameAlignmentProcessor.calculateNeighborIndices`, but intersect anyway:
        // a caller that passes a subset of the sequence must not leave us asking for
        // an op on a frame we were never given.
        var keypointSet = outputSet
        for frameIndex in outputSet {
            keypointSet.formUnion(alignmentNeighbours[frameIndex] ?? [])
        }
        keypointSet.formIntersection(available)

        var horizonSet = keypointSet
        for frameIndex in keypointSet {
            horizonSet.formUnion(horizonMergeNeighbours[frameIndex] ?? [])
        }
        horizonSet.formIntersection(available)

        self.output = outputSet.sorted()
        self.keypoint = keypointSet.sorted()
        self.horizon = horizonSet.sorted()
    }
}
