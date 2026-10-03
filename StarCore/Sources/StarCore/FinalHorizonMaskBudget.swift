import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// Something `FinalHorizonMaskBudget` can ask to let go of its cached mask.
///
/// `FrameHorizonProcessor` is the only real one.  A protocol so the budget's bookkeeping can
/// be tested without standing up frames.
protocol FinalHorizonMaskHolder: AnyObject, Sendable {
    func releaseCachedFinalHorizonMask() async
}

extension FrameHorizonProcessor: FinalHorizonMaskHolder {}

/// Bounds how many frames hold a cached final horizon mask at once.
///
/// `FrameHorizonProcessor.cachedFinalHorizonMask` is a full-frame 8-bit plane — 31MB at
/// 7008×4672 — kept so that the several ops which mask by it decode it once per frame rather
/// than once each.  It used to be kept until the frame reached `.complete`, and nothing else
/// let it go.  But no frame can complete before every frame in the sequence has been aligned:
/// `AlignmentValidationOp` depends on every `HomographyOp`, and the outlier and merge ops that
/// finish a frame depend on it.  So through the whole first half of a run every frame that had
/// run its horizon merge or keypoint detection kept its mask, and memory grew with the length
/// of the sequence rather than with the work in flight.
///
/// Measured on a 36GB M5 Max working a 1911-frame 7008×4672 sequence: 889 frames in, 888
/// full-frame images were resident — one cached mask per frame — and the process footprint
/// was 38GB, against a MemoryMonitor budget of 30.6GB that none of it was booked against.  The
/// reality brake then held every reservation and the queue fell to one forced admission a
/// minute: about 175 frames in the next twelve hours, with the GPU idle.  A 128GB machine
/// never noticed, because 1911 masks fit under its 108GB budget.  More than a quarter of those
/// masks cost 55MB or more rather than 31MB, too: keypoint detection frees a burst of 55MB
/// detection-scale float planes just before the next mask is allocated, and the allocator
/// hands the mask one of those blocks whole.
///
/// So the cache stays, but only for the frames that used it most recently — enough for the
/// ops in flight and for the next op on the same frame, and no more.  Letting one go loses
/// nothing: `loadOrCreateFinalHorizonMask()` decodes it again from disk in about 100ms.  And an
/// op already using a mask holds its own reference, so eviction never takes a mask away from
/// work that is using it.
actor FinalHorizonMaskBudget {

    /// How many frames to allow per frame processed concurrently.  Two: one for the op running
    /// on the frame now, one for the op that follows it on the same frame — the earth keypoints
    /// after the sky ones, the merge after the outliers — so that one finds the mask still
    /// cached.
    static let framesPerConcurrentFrame = 2

    /// The floor, for a run configured with very little concurrency.
    static let minimumLimit = 8

    /// The limit for a queue running `concurrency` frames at once.
    static func limit(forConcurrency concurrency: Int) -> Int {
        max(minimumLimit, framesPerConcurrentFrame * concurrency)
    }

    private struct Entry {
        let id: ObjectIdentifier
        /// Weak, so the budget never keeps a frame alive.  An entry whose holder has gone is
        /// dropped the next time the list is touched.
        weak var holder: (any FinalHorizonMaskHolder)?
    }

    /// Least recently used first.
    private var entries: [Entry] = []

    private(set) var limit: Int

    init(limit: Int = FinalHorizonMaskBudget.limit(forConcurrency: 12)) {
        self.limit = max(1, limit)
    }

    /// Change the limit, releasing whichever holders no longer fit.
    func configure(limit: Int) async {
        self.limit = max(1, limit)
        for holder in overflow() {
            await holder.releaseCachedFinalHorizonMask()
        }
    }

    /// `holder` holds its mask now, or has just served it from the cache.
    ///
    /// Moves it to the most recently used end, and hands back the holders that fall off the
    /// other end for the caller to release — never `holder` itself.  Returned rather than
    /// released here so the budget never waits on a frame while other frames wait on it.
    func holding(_ holder: any FinalHorizonMaskHolder) -> [any FinalHorizonMaskHolder] {
        let id = ObjectIdentifier(holder)
        entries.removeAll { $0.id == id || $0.holder == nil }
        entries.append(Entry(id: id, holder: holder))
        return overflow()
    }

    /// `holder` has let its mask go, so it no longer takes up a place.
    func released(_ holder: any FinalHorizonMaskHolder) {
        let id = ObjectIdentifier(holder)
        entries.removeAll { $0.id == id }
    }

    /// How many holders are booked, live or not yet swept.  For tests.
    var count: Int { entries.count }

    /// Whether `holder` is booked.  For tests.
    func isHolding(_ holder: any FinalHorizonMaskHolder) -> Bool {
        let id = ObjectIdentifier(holder)
        return entries.contains { $0.id == id }
    }

    private func overflow() -> [any FinalHorizonMaskHolder] {
        var evicted: [any FinalHorizonMaskHolder] = []
        while entries.count > limit {
            if let holder = entries.removeFirst().holder {
                evicted.append(holder)
            }
        }
        return evicted
    }
}

/// Module-level, like `keypointCache`: the bound is on the whole process, not on any one
/// sequence or frame.  Sized from the frame concurrency by `FrameGraphBuilder.update(from:)`.
let finalHorizonMaskBudget = FinalHorizonMaskBudget()
