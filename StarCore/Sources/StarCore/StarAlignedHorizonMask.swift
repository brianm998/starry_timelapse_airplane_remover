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
/// The computation runs inside the actor on purpose, for the same reason the
/// reference-mask cache decodes inside its actor: frames arrive in batches that all
/// want the same answer, and serialising the one cold computation is what collapses
/// the batch into a single set of warps.
public actor StarAlignedHorizonMaskCache {

    private struct Key: Equatable {
        let width: Int
        let height: Int
        let maskDigest: UInt64
        let homographies: [[Double]]
    }

    private var entry: (key: Key, mask: PixelatedImage)?

    private var computes = 0
    private var hits = 0

    /// The intersection of `baseMask` with itself warped by each of `homographies`,
    /// computed or served from the slot.  An empty homography list means nothing was
    /// warped into this frame's merge, so the mask needs no adjusting and comes back
    /// unchanged.  `nil` only when the underlying OpenCV work fails.
    public func mask(
      from baseMask: PixelatedImage,
      homographies: [[Double]]
    ) -> PixelatedImage? {
        guard !homographies.isEmpty else { return baseMask }

        let key = Key(width: baseMask.width,
                      height: baseMask.height,
                      maskDigest: Self.digest(of: baseMask),
                      homographies: homographies)

        if let entry, entry.key == key {
            hits += 1
            return entry.mask
        }

        guard let computed = StarAlignedHorizonMask.compute(
                from: baseMask,
                homographies: homographies
              )
        else { return nil }

        computes += 1
        entry = (key, computed)
        Log.i("StarAlignedHorizonMaskCache: computed " +
              "\(baseMask.width)×\(baseMask.height) mask over " +
              "\(homographies.count) homographies " +
              "(\(computes) computed so far, \(hits) hit(s) served)")
        return computed
    }

    /// Drop whatever is held.
    public func invalidateAll() { entry = nil }

    /// Computations performed and hits served, for tests and for logging what the
    /// slot saved.
    public func stats() -> (computes: Int, hits: Int) { (computes, hits) }

    /// FNV-1a over a strided sample of the mask's pixels, plus its full extent.
    ///
    /// Full-content hashing would read 40MB per lookup to answer a question the
    /// boundary rows decide; a horizon that moves even a few pixels changes tens of
    /// thousands of pixels, so a ~64K-point stride across the whole plane cannot
    /// miss it.  This keys the slot without holding the caller's instance identity,
    /// which is not stable here: the composite path re-wraps the shared reference
    /// mask's mat in a fresh `PixelatedImage` on every call.
    private static func digest(of mask: PixelatedImage) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ value: UInt64) {
            hash ^= value
            hash = hash &* 0x100000001b3
        }
        func mixBuffer<T: FixedWidthInteger>(_ buffer: UnsafeBufferPointer<T>) {
            mix(UInt64(buffer.count))
            let stride = Swift.max(1, buffer.count / 65536)
            var index = 0
            while index < buffer.count {
                mix(UInt64(truncatingIfNeeded: buffer[index]))
                index += stride
            }
        }
        switch mask.imageData {
        case .eightBit(let buffer):     mixBuffer(buffer)
        case .sixteenBit(let buffer):   mixBuffer(buffer)
        case .thirtyTwoBit(let buffer): mixBuffer(buffer)
        }
        return hash
    }
}

/// Module-level, matching `horizonReferenceMaskCache`: on a static sequence the same
/// answer serves every frame, so the cache has to outlive any one frame's processor.
public let starAlignedHorizonMaskCache = StarAlignedHorizonMaskCache()
