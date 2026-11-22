import Foundation

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// The first ground row of every column of a horizon mask file, kept per file version.
///
/// Drawing a frame's horizon lines needs one row per column, and getting it from the mask
/// meant decoding a full-size plane and scanning all of it, for each of the thumbnail, frame
/// and grid overlays of every frame, and every refresh.  A static sequence's frames all draw
/// the same painted reference.  Here the rows are computed once per (path, size, modification
/// time): a mask rewritten in place has a new size or time, so it is a new key, and nothing
/// has to remember to invalidate (`invalidate` just drops an entry early).
///
/// Concurrent asks for one file share a single decode.  Bounded to `capacity` entries, each
/// about nine bytes per image column.
public actor HorizonColumnsCache {

    public typealias Columns = (rows: [Int?], width: Int, height: Int)

    private struct Stamp: Equatable {
        let size: Int
        let modified: Date

        init?(path: String) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date
            else { return nil }
            self.size = size.intValue
            self.modified = modified
        }
    }

    private struct Entry {
        let stamp: Stamp
        let rows: [Int?]
        let width: Int
        let height: Int
        var lastUse: Int
    }

    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: (stamp: Stamp, task: Task<Columns?, Never>)] = [:]
    private var clock = 0
    private var extractionCount = 0
    private var hitCount = 0

    public init(capacity: Int = 300) { self.capacity = capacity }

    /// The columns of the mask at `path`.  On a miss `loadMask` supplies the decoded mask, the
    /// rows are extracted from it and kept.  Nil when the file is absent or `loadMask` gives
    /// nothing.
    public func columns(atPath path: String,
                        loadMask: @escaping @Sendable () async -> PixelatedImage?) async -> Columns? {
        guard let stamp = Stamp(path: path) else {
            entries[path] = nil
            return nil
        }
        clock += 1
        if var entry = entries[path], entry.stamp == stamp {
            hitCount += 1
            entry.lastUse = clock
            entries[path] = entry
            return (entry.rows, entry.width, entry.height)
        }
        if let running = inFlight[path], running.stamp == stamp {
            return await running.task.value
        }
        let task = Task<Columns?, Never> {
            guard let mask = await loadMask() else { return nil }
            let rows = await NativeWork.run { CombinedHorizonDetector.extractHorizonY(from: mask) }
            return (rows, mask.width, mask.height)
        }
        inFlight[path] = (stamp, task)
        let result = await task.value
        if inFlight[path]?.task == task { inFlight[path] = nil }
        if let result {
            extractionCount += 1
            store(path: path, stamp: stamp, columns: result)
        }
        return result
    }

    /// The kept columns for `path` as the file is now, without computing any.
    public func cached(atPath path: String) -> Columns? {
        guard let stamp = Stamp(path: path), var entry = entries[path], entry.stamp == stamp
        else { return nil }
        clock += 1
        hitCount += 1
        entry.lastUse = clock
        entries[path] = entry
        return (entry.rows, entry.width, entry.height)
    }

    /// Keep columns obtained some other way (a sidecar), so the next ask is a hit.
    public func remember(atPath path: String, rows: [Int?], width: Int, height: Int) {
        guard let stamp = Stamp(path: path) else { return }
        clock += 1
        store(path: path, stamp: stamp, columns: (rows, width, height))
    }

    /// Drop `path`'s entry now rather than when the next ask notices the file moved on.
    public func invalidate(path: String) {
        entries[path] = nil
    }

    public func invalidateAll() { entries.removeAll() }

    /// Extractions performed and hits served, for tests and logging.
    public func stats() -> (extractions: Int, hits: Int) { (extractionCount, hitCount) }

    public var count: Int { entries.count }

    private func store(path: String, stamp: Stamp, columns: Columns) {
        entries[path] = Entry(stamp: stamp, rows: columns.rows, width: columns.width,
                              height: columns.height, lastUse: clock)
        while entries.count > capacity,
              let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            entries[oldest] = nil
        }
    }
}

/// Module-level like `horizonReferenceMaskCache`: shared by every frame and every overlay size.
public let horizonColumnsCache = HorizonColumnsCache()
