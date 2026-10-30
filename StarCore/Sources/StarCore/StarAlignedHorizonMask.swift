import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// The horizon mask a star-aligned image actually has, derived from the homographies
/// its merge warped the neighbouring frames by.
///
/// Warping a neighbour to line its stars up with the base frame moves the neighbour's
/// ground too, and by more the further away the neighbour is.  Wherever a warp lands
/// ground above the base frame's own horizon, the merged image carries smeared terrain
/// up to the highest warped horizon — the fuzzy ridge that hovers over the real one in
/// the star-aligned image.  A composite that keeps calling those pixels "sky" paints
/// the smear into the final frame.
///
/// This used to be papered over by `horizonVerticalShiftAmount`, a hand-entered
/// constant that scooted the whole mask up before compositing.  One scalar cannot be
/// right: measured on a 42MP sequence facing azimuth 270, the warps raised neighbour
/// ground by 7px at one end of the ridge and 33px at the other (the manual guess was
/// 8), while a camera facing the rising side of the sky needs no shift at all —
/// there the warps push neighbour ground *down*, below the base horizon, where the
/// composite takes earth pixels anyway.
///
/// So instead: intersect the mask with itself warped by each homography the merge
/// used.  A pixel stays sky only if every warped source keeps it above ground — the
/// exact per-column envelope of where warped ground can reach, whichever way the
/// camera points, with no knob to guess.
public enum StarAlignedHorizonMask {

    /// `mask ∧ warp(mask, H)` over every homography in `homographies`.
    ///
    /// Each warp goes through the same `warpPerspective` call the merge used on the
    /// neighbour's pixels, with NEAREST sampling to keep the mask binary and the
    /// border filled white: a destination pixel outside a neighbour's warp coverage
    /// received no sample from it in the merge (zeros are "no data" there), so that
    /// neighbour cannot contaminate it and must impose no constraint.
    ///
    /// The base frame's mask stands in for each neighbour's own.  On a static tripod
    /// they are the same mask; on a moving one the per-frame masks differ far less
    /// than the tens of pixels the warps move them by, and the base mask is already
    /// the merged product of its neighbours' detections.
    ///
    /// `mask` is expected to be a normalised CV_8UC1 horizon mask (white sky, black
    /// ground), which is what `HorizonMask` always carries.
    public static func compute(
      from mask: PixelatedImage,
      homographies: [[Double]]
    ) -> PixelatedImage? {
        var result = mask
        for homography in homographies {
            guard homography.count == 9,
                  let warped = mask.warpedAsHorizonMask(with: homography),
                  let intersection = try? result.bitwiseAnd(with: warped)
            else {
                return nil
            }
            result = intersection
        }
        return result
    }
}

/// Process-wide cache for the star-aligned horizon mask.
///
/// After `validateStaticStarAlignment` every interior frame of a static sequence
/// carries the same homography set, and with a static reference horizon they share
/// the same base mask too — so the intersection above is the same ~40MB answer for
/// nearly every frame of the sequence.  One slot, like `HorizonReferenceMaskCache`:
/// the frames near the sequence ends have fewer neighbours and therefore their own
/// keys, but each of those keys serves a single frame, so caching more than the
/// interior answer would pin full-frame masks for no hits.  Moving sequences have a
/// different homography set per frame and simply compute every time.
///
/// What has to be serialised is the one cold computation, not the cache: frames arrive in
/// batches that all want the same answer, and a lookup that finds the same answer already
/// being computed waits for it instead of starting a second, which is what collapses a batch
/// into a single set of warps.  The computation itself, and the fingerprint that keys it,
/// run on the CPU gate outside the actor.  They used to run inside it, and that made every
/// frame of a *moving* sequence — where no two frames share an answer — queue behind the
/// others' eight full-frame warps and their fingerprints, one at a time for the whole merge
/// phase, which is a ceiling on how many frames a minute the merge can finish however many
/// cores there are.  Now frames with different answers compute at once.
public actor StarAlignedHorizonMaskCache {

    private struct Key: Equatable, Sendable {
        let width: Int
        let height: Int
        let maskDigest: UInt64
        let homographies: [[Double]]
    }

    private var entry: (key: Key, mask: PixelatedImage)?

    /// Answers being computed, so that a second ask for one waits for it.
    private var inFlight: [(key: Key, task: Task<PixelatedImage?, Never>)] = []

    private var computes = 0
    private var hits = 0

    private enum Lookup {
        case ready(PixelatedImage)
        case computing(Task<PixelatedImage?, Never>)
    }

    /// The intersection of `baseMask` with itself warped by each of `homographies`,
    /// computed or served from the slot.  An empty homography list means nothing was
    /// warped into this frame's merge, so the mask needs no adjusting and comes back
    /// unchanged.  `nil` only when the underlying OpenCV work fails.
    public nonisolated func mask(
      from baseMask: PixelatedImage,
      homographies: [[Double]]
    ) async -> PixelatedImage? {
        guard !homographies.isEmpty else { return baseMask }

        let digest = await NativeWork.run { Self.digest(of: baseMask) }
        let key = Key(width: baseMask.width,
                      height: baseMask.height,
                      maskDigest: digest,
                      homographies: homographies)
        switch await lookup(key, baseMask: baseMask, homographies: homographies) {
        case .ready(let mask): return mask
        case .computing(let task): return await task.value
        }
    }

    /// The slot's answer, the computation already under way for it, or a new one.  Synchronous
    /// on purpose: nothing between the check and the claim can interleave.
    private func lookup(_ key: Key, baseMask: PixelatedImage,
                        homographies: [[Double]]) -> Lookup {
        if let entry, entry.key == key {
            hits += 1
            return .ready(entry.mask)
        }
        if let pending = inFlight.first(where: { $0.key == key }) {
            hits += 1
            return .computing(pending.task)
        }
        let task = Task<PixelatedImage?, Never> {
            let computed = await NativeWork.run {
                StarAlignedHorizonMask.compute(from: baseMask, homographies: homographies)
            }
            await self.finished(key, computed, baseMask: baseMask, homographies: homographies)
            return computed
        }
        inFlight.append((key, task))
        return .computing(task)
    }

    private func finished(_ key: Key, _ computed: PixelatedImage?, baseMask: PixelatedImage,
                          homographies: [[Double]]) {
        inFlight.removeAll { $0.key == key }
        guard let computed else { return }
        computes += 1
        entry = (key, computed)
        Log.i("StarAlignedHorizonMaskCache: computed " +
              "\(baseMask.width)×\(baseMask.height) mask over " +
              "\(homographies.count) homographies " +
              "(\(computes) computed so far, \(hits) hit(s) served)")
    }

    /// Drop whatever is held.
    public func invalidateAll() { entry = nil }

    /// Computations performed and hits served, for tests and for logging what the
    /// slot saved.
    public func stats() -> (computes: Int, hits: Int) { (computes, hits) }

    /// FNV-1a over the mask's horizon: its extent and, for every column, the row where it
    /// turns from sky to ground.
    ///
    /// The slot's question is "is this the same horizon", and the horizon is what a repaint
    /// changes. This used to hash one pixel in about 643 (a stride over the whole plane), on
    /// the argument that a moved horizon changes tens of thousands of pixels; but a touch-up
    /// of a few tens of columns by ten rows changes under a thousand, and a stride that wide
    /// steps right over it, so the stale intersection was served. The per-column horizon cannot
    /// miss a change to the boundary. It is read row by row and stops once every column has
    /// its answer, so it costs about one read of the sky part of the plane.
    ///
    /// Also keys the slot without holding the caller's instance identity, which is not stable
    /// here: the composite path re-wraps the shared reference mask's mat in a fresh
    /// `PixelatedImage` on every call.
    static func digest(of mask: PixelatedImage) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ value: UInt64) {
            hash ^= value
            hash = hash &* 0x100000001b3
        }
        mix(UInt64(mask.width))
        mix(UInt64(mask.height))
        for y in CombinedHorizonDetector.extractHorizonY(from: mask) {
            mix(UInt64(truncatingIfNeeded: y ?? -1))
        }
        return hash
    }
}

/// Module-level, matching `horizonReferenceMaskCache`: on a static sequence the same
/// answer serves every frame, so the cache has to outlive any one frame's processor.
public let starAlignedHorizonMaskCache = StarAlignedHorizonMaskCache()
