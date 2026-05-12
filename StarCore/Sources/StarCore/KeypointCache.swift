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
/// Unlike ImageCache, this uses strong references.  Keypoint files are small
/// (typically 100 KB–1 MB each) and the full set for an entire sequence easily
/// fits in memory, so there is no benefit to weak eviction here.
public actor KeypointCache {

    private var cache: [String: OCVFeatureSet] = [:]
    private var inFlight: [String: Task<OCVFeatureSet?, Never>] = [:]

    private var cacheHits: UInt = 0
    private var cacheMisses: UInt = 0

    // MARK: - Public API

    /// Load (and cache) a feature set from `filename`.
    /// Returns `nil` when the file does not exist or cannot be parsed.
    public func load(fromFilename filename: String) async -> OCVFeatureSet? {
        if let cached = cache[filename] {
            cacheHits += 1
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
            cache[filename] = result
        }
        return result
    }

    /// Store a freshly-computed feature set so that neighbor HomographyOps
    /// that need the same file find it in cache rather than parsing from disk.
    public func store(_ featureSet: OCVFeatureSet, forFilename filename: String) {
        cache[filename] = featureSet
    }

    /// Remove all cached entries (e.g. after a full sequence is processed).
    public func clear() {
        cache.removeAll()
        inFlight.removeAll()
        Log.d("KeypointCache cleared — hits: \(cacheHits)  misses: \(cacheMisses)")
    }

    public func stats() -> String {
        "KeypointCache — entries: \(cache.count)  hits: \(cacheHits)  misses: \(cacheMisses)"
    }
}
