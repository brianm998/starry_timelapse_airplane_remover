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
    /// Every `load` call, and how many were answered from a pinned, already-decoded entry.
    public private(set) var loadCount = 0
    public private(set) var cacheHitCount = 0

    /// One line for the run's end-of-run log: how much decoding the merges did per frame.
    public func statsLine(frames: Int) -> String {
        condition.lock()
        defer { condition.unlock() }
        let perFrame = frames > 0 ? String(format: "%.2f", Double(decodeCount) / Double(frames)) : "n/a"
        return "DecodedFrameStore: \(loadCount) loads, \(cacheHitCount) served from pinned decodes, " +
               "\(decodeCount) decodes (\(perFrame) per frame over \(frames) frames)"
    }

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
        waitForFrameIfExtracting(filename)
        condition.lock()
        loadCount += 1
        guard let entry = entries[filename] else {
            // Not pinned: decode uncached.
            condition.unlock()
            countDecode()
            return decoder(filename)
        }
        while entry.loading { condition.wait() }
        if let mat = entry.mat {
            cacheHitCount += 1
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

    // MARK: frames that are still being extracted

    /// The sources whose frames the loader may be asked for before they exist (videos being extracted), by their folder.
    private let sourcesLock = NSLock()
    private var extractingSources: [String: FrameSource] = [:]

    /// Registers a source for the backstop below; `ImageSequence` does it for a source that is still extracting.
    public func register(source: FrameSource, folder: String) {
        sourcesLock.lock()
        extractingSources[folder] = source
        sourcesLock.unlock()
    }

    public func unregisterSource(folder: String) {
        sourcesLock.lock()
        extractingSources[folder] = nil
        sourcesLock.unlock()
    }

    /// The loader is called by the C++ merge on a native thread, by filename.  A frame of a video that is still being extracted is
    /// waited for there (blocking, which is safe because this thread is never one of the cooperative pool's: see
    /// `waitUntilAvailableBlocking`).  The merge ops depend on `FrameAvailableOp`s, so this is a backstop for one that was missed.
    private func waitForFrameIfExtracting(_ filename: String) {
        sourcesLock.lock()
        let folder = (filename as NSString).deletingLastPathComponent
        let source = extractingSources[folder]
        sourcesLock.unlock()
        guard let source else { return }
        // The name says which frame: look it up rather than parse it.
        let count = source.frameCount
        guard let index = frameIndex(of: filename, in: source, count: count), !source.isAvailable(index) else { return }
        OriginalWaitWarnings.warnOnce(frameIndex: index)
        source.prioritize([index], reason: .pipeline)
        try? source.waitUntilAvailableBlocking(index)
    }

    private func frameIndex(of filename: String, in source: FrameSource, count: Int) -> Int? {
        // Binary search is not possible on names; the number is in the name after "image_" for a video's frames.
        let base = ((filename as NSString).lastPathComponent as NSString).deletingPathExtension
        guard base.hasPrefix("image_"), let number = Int(base.dropFirst("image_".count)) else { return nil }
        let index = number - 1
        guard index >= 0, index < count, source.path(forFrame: index) == filename else { return nil }
        return index
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
