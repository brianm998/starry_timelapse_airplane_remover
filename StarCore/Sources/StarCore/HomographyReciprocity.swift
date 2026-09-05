import Foundation
import logging

/*
 A cross-frame consistency check on star homographies.

 Every check in `HomographyResultsCodable.alignmentLooksOk` is internal to one frame's
 own neighbor set: how big the matrices are, whether `deviation/frameDistance` is
 uniform, and how far tx/ty sit from a line fit through that same set.  None of them can
 see a set that is internally smooth and collectively wrong, and on a sequence whose pan
 rate is changing they can flag a set that is right — `deviation` is `‖H−I‖`, which is
 only linear in frame distance while the rate is constant.

 The information needed to do better is already in hand and unused.  Each frame pair is
 fitted twice, independently: once as frame `f`'s entry at offset `+k`, and once as
 frame `f+k`'s entry at offset `−k`.  Both describe the same relative motion, and
 `H_f[+k]` maps the neighbor's coordinates into the base frame's (that is
 `findHomography(ptsNeighbor, ptsBase)`, and `warpInto` then warps the neighbor with
 it), so the two must be inverses of each other.  Where they disagree, at least one of
 them is wrong, and neither fit knew what the other was going to say.

 Measured on the 2103 frame `11_30_2024-a9-1-aurora-topaz` sequence (moving, with an
 accelerating pan): the per-frame median disagreement runs p50 0.138px, p90 0.477,
 p99 0.721, p99.9 1.066 — and then the two frames that actually rendered as
 "brightest-stars-only" at 2.17 and 2.14px.  A threshold anywhere between about 1.2 and
 2.1px flags exactly those two frames and nothing else in the sequence.  Those same two
 frames passed `alignmentLooksOk`, which in fact rated them *cleaner* than their
 correct neighbours (max tx residual 0.19px against 1.04px), because what was wrong with
 them was the rate of a perfectly straight line.

 Cheap enough to run over a whole sequence unconditionally: five points through a 3x3 per
 pair, no images and no keypoints.
 */
enum HomographyReciprocity {

    /// Where to measure the disagreement between two homographies: the four corners plus
    /// the centre.  A wrong rotation or scale shows up at the corners and cancels at the
    /// centre, and a wrong translation shows up everywhere, so taking the largest of
    /// these five catches both without integrating over the frame.
    /// nil when the frame size is not known well enough to measure with.  `Config`'s
    /// `imageWidth`/`imageHeight` default to 0 and are filled in by `set(imageInfo:)`;
    /// degenerating to a point at the origin would silently turn this into a
    /// translation-only check that agrees with anything at the centre and disagrees at
    /// no corner, which is worse than not running.
    static func probePoints(width: Int, height: Int) -> [(x: Double, y: Double)]? {
        guard width > 64, height > 64 else { return nil }
        let w = Double(width - 1), h = Double(height - 1)
        return [(0, 0), (w, 0), (0, h), (w, h), (w / 2, h / 2)]
    }

    /// How far apart, in pixels, two homographies place the same points.
    static func disagreement(
      _ a: [Double],
      _ b: [Double],
      at points: [(x: Double, y: Double)]
    ) -> Double? {
        guard a.count == 9, b.count == 9 else { return nil }
        var worst = 0.0
        for p in points {
            guard let pa = CaptureCadence.apply(a, to: p),
                  let pb = CaptureCadence.apply(b, to: p)
            else { return nil }
            let d = ((pa.x - pb.x) * (pa.x - pb.x) +
                     (pa.y - pb.y) * (pa.y - pb.y)).squareRoot()
            worst = max(worst, d)
        }
        return worst
    }

    /// The disagreement between each of `results`' entries and the partner frame's own
    /// independent fit of the same pair, keyed by neighbor frame index.
    ///
    /// `partnerSet` supplies the partner frame's homography set, or nil when that frame
    /// has none or is not one this caller wants to be judged against.  Offsets whose
    /// partner does not answer are absent from the result rather than scored as zero.
    static func perNeighborDisagreement(
      of results: HomographyResultsCodable,
      partnerSet: (Int) -> HomographyResultsCodable?,
      at points: [(x: Double, y: Double)]
    ) -> [Int: Double] {
        var ret: [Int: Double] = [:]
        for entry in results.neighborHomography {
            guard let mine = entry.homography else { continue }
            let offset = entry.frameIndex - results.frameIndex
            guard offset != 0,
                  let partner = partnerSet(entry.frameIndex)
            else { continue }
            // the partner's view of this same pair, which points the other way
            guard let theirs = partner.neighborHomography.first(where: {
                      $0.frameIndex - partner.frameIndex == -offset
                  })?.homography,
                  let inverted = CaptureCadence.invert3x3(theirs),
                  let d = disagreement(mine, inverted, at: points)
            else { continue }
            ret[entry.frameIndex] = d
        }
        return ret
    }

    /// One number for how well a whole set agrees with its partners: the median of the
    /// per-neighbor disagreements.
    ///
    /// Median, not max, so that one bad partner cannot condemn a good frame — the
    /// asymmetry matters, because a frame adjacent to a genuinely bad one shares a pair
    /// with it and would otherwise inherit its error.  nil when too few partners answered
    /// for the median to mean anything, which is the honest result at the ends of a
    /// sequence and for frames whose neighbors all failed to align.
    static func score(
      of results: HomographyResultsCodable,
      partnerSet: (Int) -> HomographyResultsCodable?,
      at points: [(x: Double, y: Double)],
      minimumPartners: Int = 4
    ) -> Double? {
        median(of: perNeighborDisagreement(of: results, partnerSet: partnerSet, at: points),
               minimumPartners: minimumPartners)
    }

    /// The same median, over a `perNeighborDisagreement` map the caller already has —
    /// optionally restricted to a subset of neighbors, which is how a pruned set is
    /// scored without measuring it again.
    static func median(
      of perNeighbor: [Int: Double],
      restrictedTo keep: Set<Int>? = nil,
      minimumPartners: Int = 4
    ) -> Double? {
        let values = (keep == nil
                        ? Array(perNeighbor.values)
                        : perNeighbor.filter { keep!.contains($0.key) }.map(\.value))
          .sorted()
        guard values.count >= minimumPartners else { return nil }
        return values[values.count / 2]
    }
}
