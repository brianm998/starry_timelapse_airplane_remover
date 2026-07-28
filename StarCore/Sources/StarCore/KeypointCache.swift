import Foundation
import logging
import StarCppBridge

public let keypointCache = KeypointCache()

/// In-memory cache for OCVFeatureSet (keypoint YAML) files.
///
/// Each HomographyOp loads keypoint files for all of its neighbor frames.  With
/// N neighbors, the same YAML is parsed once per neighboring HomographyOp that
/// needs it.  This cache deduplicates those loads: the first caller parses the
/// file; concurrent callers for the same path join the in-flight task; later
/// callers get the already-parsed result directly.
///
/// Unlike ImageCache this holds strong references, so it needs a bound of its own.
///
/// It used to have none, on the reasoning that "keypoint files are small (typically
/// 100 KB–1 MB each) and the full set for an entire sequence easily fits in memory".
/// That is true for sky sets, which `alignmentMaxKeypoints` caps at 2000 keypoints —
/// about 1 MB of CV_32F descriptors. It is not true for earth: `ia_find_features` builds
/// AKAZE with `cv::AKAZE::create()` and a 1e-5 threshold and never applies
/// `maxKeypoints`, so a 42MP frame can yield orders of magnitude more. And "the full set
/// for an entire sequence" is one entry per frame per alignment type — 2000 entries on a
/// 1000-frame sequence, which does not easily fit in memory at any per-entry size.
///
/// So entries are now charged by estimated size and evicted least-recently-used once the
/// total passes `configure(maxBytes:)`. The access pattern is strongly local — a
/// HomographyOp reads only its own neighbours — so a modest budget keeps the hit rate
/// while bounding the footprint.
public actor KeypointCache {

    private var cache: [String: OCVFeatureSet] = [:]
    private var inFlight: [String: Task<OCVFeatureSet?, Never>] = [:]

    /// Keys least-recently-used first. Linear to touch, which is fine at the few hundred
    /// entries a sensible budget allows.
    private var lru: [String] = []
    private var entryBytes: [String: Int] = [:]
    private var totalBytes: Int = 0

    /// 0 means unbounded, which is the old behaviour.
    private var maxBytes: Int = 0

    private var cacheHits: UInt = 0
    private var cacheMisses: UInt = 0
    private var evictions: UInt = 0

    // MARK: - Public API

    /// Set the byte budget. 0 disables eviction.
    public func configure(maxBytes: Int) {
        self.maxBytes = max(0, maxBytes)
        Log.i("KeypointCache budget \(self.maxBytes / (1024*1024))MB " +
              "(holding \(totalBytes / (1024*1024))MB in \(cache.count) entries)")
        evictIfNeeded()
    }

    /// Load (and cache) a feature set from `filename`.
    /// Returns `nil` when the file does not exist or cannot be parsed.
    public func load(fromFilename filename: String) async -> OCVFeatureSet? {
        if let cached = cache[filename] {
            cacheHits += 1
            touch(filename)
            return cached
        }

        if let task = inFlight[filename] {
            cacheMisses += 1
            return await task.value
        }

        cacheMisses += 1

        let task: Task<OCVFeatureSet?, Never> = Task.detached(priority: .userInitiated) {
            OCVFeatureSet.load(fromFilename: filename)
        }
        inFlight[filename] = task
        let result = await task.value
        inFlight[filename] = nil
        if let result {
            insert(result, forFilename: filename)
        }
        return result
    }

    /// Store a freshly-computed feature set so that neighbor HomographyOps
    /// that need the same file find it in cache rather than parsing from disk.
    public func store(_ featureSet: OCVFeatureSet, forFilename filename: String) {
        insert(featureSet, forFilename: filename)
    }

    /// Remove all cached entries.  Call between sequences: entries are keyed by path, so
    /// a new sequence never hits them, and without this the old sequence's set is pinned
    /// for the life of the process.
    public func clear() {
        cache.removeAll()
        inFlight.removeAll()
        lru.removeAll()
        entryBytes.removeAll()
        totalBytes = 0
        Log.i("KeypointCache cleared — hits: \(cacheHits)  misses: \(cacheMisses)  " +
              "evictions: \(evictions)")
    }

    public func hitCount() -> UInt { cacheHits }

    public func stats() -> String {
        "KeypointCache — entries: \(cache.count)  " +
        "\(totalBytes / (1024*1024))MB" +
        (maxBytes > 0 ? " / \(maxBytes / (1024*1024))MB" : " (unbounded)") +
        "  hits: \(cacheHits)  misses: \(cacheMisses)  evictions: \(evictions)"
    }

    // MARK: - Internal

    private func insert(_ featureSet: OCVFeatureSet, forFilename filename: String) {
        if let existing = entryBytes[filename] {
            totalBytes -= existing
        }
        let bytes = featureSet.estimatedBytes
        cache[filename] = featureSet
        entryBytes[filename] = bytes
        totalBytes += bytes
        touch(filename)
        evictIfNeeded()
    }

    private func touch(_ filename: String) {
        if let idx = lru.firstIndex(of: filename) { lru.remove(at: idx) }
        lru.append(filename)
    }

    private func evictIfNeeded() {
        guard maxBytes > 0 else { return }
        while totalBytes > maxBytes, let oldest = lru.first {
            lru.removeFirst()
            cache[oldest] = nil
            totalBytes -= entryBytes.removeValue(forKey: oldest) ?? 0
            evictions += 1
        }
        if totalBytes < 0 { totalBytes = 0 }
    }
}

extension OCVFeatureSet {
    /// Rough in-memory size. Descriptors dominate: one row per keypoint, `descriptorCols`
    /// elements wide (128 CV_32F for SIFT, 61 CV_8U for AKAZE). cv::KeyPoint itself is
    /// 7 floats plus padding, counted at 32 bytes.
    public var estimatedBytes: Int {
        let bytesPerElement: Int
        switch descriptorType & 7 {          // CV_MAT_DEPTH
        case 0, 1: bytesPerElement = 1       // CV_8U  / CV_8S
        case 2, 3: bytesPerElement = 2       // CV_16U / CV_16S
        case 4, 5: bytesPerElement = 4       // CV_32S / CV_32F
        case 6:    bytesPerElement = 8       // CV_64F
        default:   bytesPerElement = 4
        }
        return descriptorRows * descriptorCols * bytesPerElement + keypointCount * 32
    }
}
