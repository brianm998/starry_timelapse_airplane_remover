import Foundation
import StarCppBridge

/// Decodes each original once per merge op, however many merges inside the op ask for it.
///
/// `createAutoProcessedImage` runs a star-aligned build and then an earth-aligned build,
/// and each hands the same 9 neighbour *filenames* to the C++ merge, which decodes them
/// through the loader registered in `ImageCache.init`. Over a moving run that made every
/// original decode about 21 times. This sits behind that loader.
///
/// Entries exist only while pinned. An op pins the paths it is about to merge, and the
/// store keeps what the loader decodes for them until the last pin on that path goes. Any
/// concurrent op asking for the same path shares the entry. Paths nobody pinned decode
/// uncached, exactly as before, so nothing here can grow without a pin to account for it.
///
/// No extra memory is reserved for it: the pinning op's `MemoryMonitor` reservation
/// already covers the neighbours it would have decoded anyway.
public final class DecodedFrameStore: @unchecked Sendable {

    public static let shared = DecodedFrameStore()

    private final class Entry {
        var pins: Int
        var mat: MatWrapper?
        /// A decode in flight, so two merges asking at once wait for one read.
        var loading = false
        init(pins: Int) { self.pins = pins }
    }

    private let condition = NSCondition()
    private var entries: [String: Entry] = [:]

    /// Distinct decodes performed through `load`, for tests and diagnostics.
    public private(set) var decodeCount = 0

    /// The actual decode. Replaceable so tests can count calls without real files.
    ///
    /// By default a read through `IOWork`, so a native thread inside a C++ merge takes one
    /// of its volume's streams for exactly as long as the read takes. This runs
    /// synchronously on that thread — see `StarCppBridge.ImageCache.setLoader` — so the
    /// gate is acquired blocking. It cannot deadlock: a stream is held only for the read,
    /// which waits on nothing else.
    nonisolated(unsafe) var decoder: @Sendable (String) -> MatWrapper? = { filename in
        IOWork.runBlocking(path: filename, bytes: DecodedFrameStore.fileSize(filename)) {
            MatWrapper.load(fromFilename: filename)
        }
    }

    static func fileSize(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.intValue ?? 0
    }

    init() {}

    /// A hold on a set of paths, released by `release()` or on deinit. Idempotent.
    public final class Pin: @unchecked Sendable {
        private let store: DecodedFrameStore
        private var paths: [String]
        private let lock = NSLock()

        fileprivate init(store: DecodedFrameStore, paths: [String]) {
            self.store = store
            self.paths = paths
        }

        public func release() {
            lock.lock()
            let held = paths
            paths = []
            lock.unlock()
            if !held.isEmpty { store.unpin(held) }
        }

        deinit { release() }
    }

    /// Keep what the loader decodes for `paths` until the returned pin is released.
    public func pin(_ paths: [String]) -> Pin {
        let unique = Array(Set(paths))
        condition.lock()
        for path in unique {
            if let entry = entries[path] {
                entry.pins += 1
            } else {
                entries[path] = Entry(pins: 1)
            }
        }
        condition.unlock()
        return Pin(store: self, paths: unique)
    }

    private func unpin(_ paths: [String]) {
        condition.lock()
        for path in paths {
            guard let entry = entries[path] else { continue }
            entry.pins -= 1
            if entry.pins <= 0 { entries[path] = nil }
        }
        condition.unlock()
    }

    /// The loader behind `image_cache_load`. Synchronous, on the calling native thread.
    public func load(_ filename: String) -> MatWrapper? {
        condition.lock()
        guard let entry = entries[filename] else {
            // Not pinned: decode uncached.
            condition.unlock()
            countDecode()
            return decoder(filename)
        }
        while entry.loading { condition.wait() }
        if let mat = entry.mat {
            condition.unlock()
            return mat
        }
        entry.loading = true
        condition.unlock()

        countDecode()
        let mat = decoder(filename)

        condition.lock()
        entry.loading = false
        // A failed decode is not cached: the next asker retries.
        if let mat, !mat.isEmpty { entry.mat = mat }
        condition.broadcast()
        condition.unlock()
        return mat
    }

    /// Paths currently held, for tests.
    public var pinnedPathCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return entries.count
    }

    private func countDecode() {
        condition.lock()
        decodeCount += 1
        condition.unlock()
    }
}
