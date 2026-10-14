import Foundation

/// The data model the generated feature files are written in. Plain values: nothing here parses
/// or decodes anything at run time.

public enum StepKeyword: String, Sendable {
    case given = "Given"
    case when = "When"
    case then = "Then"
    case and = "And"
    case but = "But"
}

public struct Step: Sendable {
    public let keyword: StepKeyword
    public let action: StepAction

    public init(_ keyword: StepKeyword, _ action: StepAction) {
        self.keyword = keyword
        self.action = action
    }

    /// The step as written in the feature file, e.g. `Given I open the sequence {sequence}`.
    public var description: String { "\(keyword.rawValue) \(action.rawValue)" }
}

public struct Feature: Sendable {
    public let name: String
    public let tags: [String]
    public let scenario: String
    public let steps: [Step]

    public init(name: String, tags: [String], scenario: String, steps: [Step]) {
        self.name = name
        self.tags = tags
        self.scenario = scenario
        self.steps = steps
    }
}

/// Placeholder values. `Params.defaults` and `Params.overrides` are generated from `params.json`.
public enum Params {
    /// Resolves `{name}`: env var `STAR_GHERKIN_<UPPER_NAME>`, then the client's override, then the default.
    public static func resolve(_ name: String, client: String, environment: [String: String]) -> String? {
        let envName = "STAR_GHERKIN_" + name.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }.map(String.init).joined()
        if let v = environment[envName], !v.isEmpty { return v }
        if let v = overrides[client]?[name] { return v }
        return defaults[name]
    }

    /// Every `{placeholder}` in `text`, in order.
    public static func placeholders(in text: String) -> [String] {
        var result: [String] = []
        var current: String?
        for ch in text {
            if ch == "{" { current = "" }
            else if ch == "}", let c = current { result.append(c); current = nil }
            else if current != nil { current!.append(ch) }
        }
        return result
    }

    /// `text` with every `{placeholder}` replaced; nil if one has no value.
    public static func substitute(_ text: String, client: String, environment: [String: String]) -> String? {
        var out = text
        for p in placeholders(in: text) {
            guard let v = resolve(p, client: client, environment: environment) else { return nil }
            out = out.replacingOccurrences(of: "{\(p)}", with: v)
        }
        return out
    }
}

/// `data:<name>` param values: a dataset fetched by `test_data/fetch.sh` into `<cache>/<name>`. Runners resolve, never download.
public enum TestData {
    public struct Missing: Error, CustomStringConvertible {
        public let description: String
    }

    public static let prefix = "data:"

    /// The directory a `data:<name>` value names, or nil when `value` is a plain path. Throws `Missing`, with the command to run,
    /// when the directory or its `.complete` marker is absent (never skip: a skipped scenario is a vacuous green).
    public static func resolve(_ value: String, cache: URL) throws -> URL? {
        guard value.hasPrefix(prefix) else { return nil }
        let name = String(value.dropFirst(prefix.count))
        let dir = cache.appendingPathComponent(name)
        let complete = dir.appendingPathComponent(".complete")
        guard FileManager.default.fileExists(atPath: complete.path) else {
            throw Missing(description: "test dataset `\(name)` is not fetched (no \(complete.path)). Run: test_data/fetch.sh \(name)"
                          + "  (cache: \(cache.path); set STAR_TEST_DATA to share one)")
        }
        return dir
    }
}
