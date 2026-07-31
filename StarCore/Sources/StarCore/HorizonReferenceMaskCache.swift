import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// Process-wide cache for the sequence-global painted horizon reference,
/// `horizonReference/reference.tiff`.
///
/// A static sequence shares one reference file across every frame, but the loader ran
/// per frame: a crash log from a 1094-frame 42MP sequence showed 1,108 decodes of the
/// same TIFF in 16 seconds, each followed by `ensureGray8U()` and a full-image
/// `horizonBounds()` scan.  Identical input, identical output, once per frame.
///
/// One slot rather than a dictionary.  A run processes one sequence, so the memory bound
/// is a single full-frame 8-bit plane — about 40MB at 42MP, against the 14 concurrent
/// private copies the uncached path held at peak.  Keying on the path means opening a
/// different sequence replaces the entry instead of accumulating.  Per-frame references
/// (moving sequences) are deliberately not cached: each is read by exactly one frame, so
/// caching them would pin one mask per frame and never serve a hit.
///
/// Freshness is decided by the file's own (modification date, size), not by writers
/// remembering to invalidate.  `reference.tiff` is written by `createMergedHorizonMask`
/// and by `saveHorizonReferenceMask`, and deleted outright by the daemon's
/// `clearReference` handler — three call paths in two modules, and serving a stale mask
/// shows up as "I repainted the horizon and nothing changed".  Making correctness a
/// property of the file rather than of that bookkeeping is the point.  `invalidate` is
/// still offered so an in-process writer can drop the entry immediately instead of
/// waiting for the next lookup to notice.
public actor HorizonReferenceMaskCache {

    /// Identity of the file an entry was loaded from.  Size alone would miss a repaint
    /// that happens to produce the same byte count — the horizon is one line in a
    /// fixed-size mask, so that is the common case, not a corner case.
    private struct Stamp: Equatable {
        let modified: Date
        let size: Int

        init?(path: String) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? Int
            else { return nil }
            self.modified = modified
            self.size = size
        }
    }

    private struct Entry {
        let path: String
        let stamp: Stamp
        let mask: HorizonMask
    }

    private var entry: Entry?

    private var loads = 0
    private var hits = 0

    /// The mask at `path`, loaded if this is the first ask or if the file changed
    /// underneath the cached copy.  `nil` when the file is absent or undecodable, which
    /// is the normal answer for a sequence with no painted reference.
    ///
    /// The decode runs synchronously inside the actor on purpose.  Frames reach this
    /// point in a batch — the crash log had 14 arrive inside one millisecond — and every
    /// one of them wants this same file, so there is nothing else worth interleaving.
    /// Holding the actor for the one cold decode is what collapses that batch into a
    /// single read; releasing it would let all 14 decode the file in parallel, which is
    /// the behaviour being removed.
    public func mask(atPath path: String) -> HorizonMask? {
        guard let stamp = Stamp(path: path) else {
            // Gone or unreadable.  Drop any entry for this path so that re-creating the
            // same file later is not answered out of the pre-deletion copy.
            forget(path)
            return nil
        }

        if let entry, entry.path == path, entry.stamp == stamp {
            hits += 1
            return entry.mask
        }

        // Same chain the uncached loader used — decodes, converts to CV_8UC1, and has
        // computable bounds — so a file this cache rejects is exactly a file the previous
        // per-frame read rejected.  `HorizonMask.init` normalises again, harmlessly; that
        // second conversion now happens once for the sequence rather than once per frame.
        guard let image = PixelatedImage(filename: path)?.asHorizonMask,
              let mask = HorizonMask(image)
        else {
            forget(path)
            return nil
        }

        loads += 1
        entry = Entry(path: path, stamp: stamp, mask: mask)
        Log.i("HorizonReferenceMaskCache: loaded \(path) " +
              "(\(mask.image.width)×\(mask.image.height), " +
              "\(loads) load(s) so far, \(hits) hit(s) served)")
        return mask
    }

    /// Drop the entry for `path`, if it is the one held.  Call after writing the file to
    /// make the new contents visible immediately; the stamp check would catch it anyway.
    public func invalidate(path: String) { forget(path) }

    /// Drop whatever is held, whichever path it came from.
    public func invalidateAll() { entry = nil }

    /// Loads performed and hits served, for tests and for logging the I/O this saved.
    public func stats() -> (loads: Int, hits: Int) { (loads, hits) }

    private func forget(_ path: String) {
        if entry?.path == path { entry = nil }
    }
}

/// Module-level, matching `imageCache` and `referenceHorizonStatsCache`: the reference is
/// shared by every frame of a sequence, so the cache that serves it has to outlive any
/// one frame's processor.
public let horizonReferenceMaskCache = HorizonReferenceMaskCache()
