import Foundation

public struct Threshold: Codable, Sendable {
    /// nil until Phase 4 has measured it. Never guessed.
    public var value: Double?
    /// The distribution, dataset and date the value was set from.
    public var measured: String?
}

public struct Thresholds: Codable, Sendable {
    public var removed_max: Threshold?
    public var kept_min: Threshold?
    public var stars_median_min: Threshold?
    public var stars_median_max: Threshold?
    public var stars_lost_max: Threshold?
    public var unchanged_outside_max_area: Threshold?
    public var differential_outside_max: Threshold?
    /// Objects whose median measurable input contrast (0...1 brightness units) is below this are
    /// reported as `faint` and not required to be removed (selective mode leaves faint streaks alone).
    public var min_required_contrast: Threshold?

    public init() {}

    public static func load(from url: URL) throws -> Thresholds {
        try JSONDecoder().decode(Thresholds.self, from: Data(contentsOf: url))
    }

    /// Thresholds a given set of checks needs but doesn't have a value for.
    public func missing(forRemoved removed: Bool, kept: Bool, stars: Bool, unchanged: Bool, differential: Bool) -> [String] {
        var m: [String] = []
        func need(_ name: String, _ t: Threshold?) { if t?.value == nil { m.append(name) } }
        if removed || differential { need("removed_max", removed_max) }
        if kept { need("kept_min", kept_min) }
        if stars { need("stars_median_min", stars_median_min); need("stars_median_max", stars_median_max); need("stars_lost_max", stars_lost_max) }
        if unchanged { need("unchanged_outside_max_area", unchanged_outside_max_area) }
        if differential { need("differential_outside_max", differential_outside_max) }
        return m
    }
}

public struct BaselineEntry: Codable, Sendable, Hashable {
    public var dataset: String
    public var frame: String
    public var object: String
    public var cleanMethod: String
    public var worstRatio: Double?
    public var date: String?
}

public struct Baseline: Codable, Sendable {
    public var entries: [BaselineEntry]
    public init(entries: [BaselineEntry] = []) { self.entries = entries }
    public static func load(from url: URL) throws -> Baseline {
        try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: url))
    }

    public enum Outcome: String, Codable, Sendable {
        case pass
        case knownFailure      // in baseline, still failing: passes, and says so
        case regression        // not in baseline, failing: fails
        case fixed             // in baseline, now passing: fails, "remove it from removal-baseline.json"
    }

    public func outcome(dataset: String, frame: String, object: String, cleanMethod: String, passed: Bool) -> Outcome {
        let known = entries.contains { $0.dataset == dataset && $0.frame == frame && $0.object == object && $0.cleanMethod == cleanMethod }
        switch (known, passed) {
        case (false, true): return .pass
        case (true, false): return .knownFailure
        case (false, false): return .regression
        case (true, true): return .fixed
        }
    }
}
