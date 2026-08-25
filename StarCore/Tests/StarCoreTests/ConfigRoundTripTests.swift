import XCTest
@testable import StarCore

/// `Config` encodes with the synthesized `Encodable` conformance and decodes with a
/// hand-written `init(from:)`. That asymmetry is load-bearing — see the comment on that
/// initializer for why the synthesized decoder cannot be used — and it is also a trap:
/// every stored property is *written* to config.json, but only the ones the initializer
/// names are *read back*. The rest decode to their `Config()` defaults, and then
/// `ConfigManager.update` -> `save()` writes the defaulted config out again, so the setting
/// is not merely ignored on resume, it is erased from the file.
///
/// It had gone wrong for 16 of 93 properties. The one that bit was `finalOutputDir`:
/// `star <seq> <outputDir>` recorded it, the resume decoded nil, `outputSequenceDirname`
/// fell through to `<outputPath>/<basename>`, and the resume rendered a whole second output
/// dir while re-running every merge — because the finals it should have found were in the
/// first dir.
///
/// A test that listed the properties it expected would rot the same way the decoder did, so
/// these drive off `Mirror`, which reports the stored properties of whatever `Config` is
/// today. Adding a property to the struct extends this test automatically.
final class ConfigRoundTripTests: XCTestCase {

    // MARK: - the invariant

    /// Every stored property must survive a JSON round trip.
    ///
    /// The mechanism: encode the defaults, replace every value with a different one, decode,
    /// and compare against the defaults. A property that comes back *equal to its default*
    /// was handed a different value and threw it away — i.e. it is not decoded.
    func testEveryStoredPropertySurvivesAJsonRoundTrip() throws {
        let defaults = Config()
        let mutated = try mutatedEncoding(of: defaults)

        let decoded: Config
        do {
            decoded = try JSONDecoder().decode(Config.self,
                                               from: try JSONEncoder().encode(mutated))
        } catch let error as DecodingError {
            // Almost certainly `alternates` needs an entry: the generic perturbation handed
            // some property a value of the right JSON type but outside what it accepts, e.g.
            // a string that is not one of an enum's raw values.
            XCTFail("""
                    the perturbed config did not decode\(Self.describe(error))
                    This test builds its input by perturbing the encoded defaults. If a \
                    property cannot take an arbitrary value of its own JSON type, add an \
                    explicit alternate for it to `alternates()` below.
                    """)
            return
        }

        let before = Self.propertiesByName(of: defaults)
        let after = Self.propertiesByName(of: decoded)

        for (name, defaultValue) in before.sorted(by: { $0.key < $1.key }) {
            let decodedValue = try XCTUnwrap(after[name])
            XCTAssertNotEqual(
              decodedValue, defaultValue,
              """
              Config.\(name) is encoded but not decoded: config.json carried \
              \(mutated[name].map(String.init(describing:)) ?? "a non-default value") \
              and it came back as the default \(defaultValue).

              Add it to Config.init(from:). Until then, anything that sets Config.\(name) \
              loses it on the next resume, and the resume's own save() writes the default \
              back over it in config.json.
              """
            )
        }
    }

    /// The test above can only speak for properties it managed to put a value in front of.
    /// A property absent from the encoded defaults — a `nil` Optional, which is how
    /// `finalOutputDir` hid — has nothing to perturb, so it needs an explicit alternate.
    func testEveryStoredPropertyIsActuallyExercised() throws {
        let mutated = try mutatedEncoding(of: Config())

        for name in Self.propertiesByName(of: Config()).keys.sorted() {
            XCTAssertNotNil(
              mutated[name],
              """
              Config.\(name) is not covered by \
              testEveryStoredPropertySurvivesAJsonRoundTrip, so that test cannot tell \
              whether it decodes.

              A property is missing from the encoded defaults when it is an Optional that \
              defaults to nil, since the encoder omits it. Add an entry for \(name) to \
              `alternates()` below so there is a value to round-trip.
              """
            )
        }
    }

    /// A config.json from before a property existed still has to decode, defaulting the keys
    /// it does not carry. This is the reason `init(from:)` is hand-written at all, and the
    /// thing that breaks the moment it is "simplified" away to the synthesized conformance,
    /// which ignores inline defaults and demands every key.
    func testAnOldConfigDecodesWithDefaultsForKeysItDoesNotHave() throws {
        let json = #"{"imageSequenceDirname":"seq","imageSequencePath":"/tmp"}"#
        let decoded = try JSONDecoder().decode(Config.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.imageSequenceDirname, "seq")
        XCTAssertEqual(decoded.imageSequencePath, "/tmp")
        // untouched by that json, so they have to be what Config() says
        XCTAssertEqual(decoded.outputPath, Config().outputPath)
        XCTAssertEqual(decoded.numberStaticNeighborFrames, Config().numberStaticNeighborFrames)
        XCTAssertNil(decoded.finalOutputDir)
    }

    /// And the other direction: a config.json from *after* a property was removed still has
    /// to decode, ignoring the key it no longer knows.
    ///
    /// Every sequence anyone has temp files for carries `horizonStripWidth`, which was
    /// removed once it turned out nothing read it. If decoding rejected unknown keys, all
    /// of those would stop resuming — so this pins the tolerance rather than leaving it to
    /// a `JSONDecoder` default that a future custom decoder could quietly change.
    func testAConfigCarryingARemovedKeyStillDecodes() throws {
        let json = #"""
          {"imageSequenceDirname":"seq","imageSequencePath":"/tmp",
           "horizonStripWidth":1234,"horizonVerticalShiftAmount":8,
           "alignmentMaxKeypoints":1500}
          """#
        let decoded = try JSONDecoder().decode(Config.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.imageSequenceDirname, "seq")
        XCTAssertEqual(decoded.alignmentMaxKeypoints, 1500,
                       "the keys that still exist have to be read as usual")
    }

    /// The specific failure that was observed, stated on its own so a regression names
    /// itself: a run told where to put its finals has to still know on resume.
    func testFinalOutputDirSurvivesResume() throws {
        var saved = Config()
        saved.imageSequenceDirname = "seqC"
        saved.finalOutputDir = "outC"

        let decoded = try JSONDecoder().decode(Config.self,
                                               from: try JSONEncoder().encode(saved))

        XCTAssertEqual(decoded.finalOutputDir, "outC")
        XCTAssertEqual(decoded.outputSequenceDirname, "outC",
                       "with finalOutputDir lost this falls through to "
                       + "<outputPath>/<basename>, and the resume renders a second output dir")
    }

    // MARK: - building a config in which nothing is left at its default

    /// Values for the properties the generic perturbation cannot make up for itself: those
    /// whose JSON type does not describe what they accept (enums, and the dictionaries that
    /// default to empty), and those absent from the encoded defaults because they are nil.
    ///
    /// Written as real Swift values encoded through `JSONEncoder`, not as hand-written JSON,
    /// so they cannot drift out of shape with the types they stand in for. The enum cases
    /// come from `allCases`, so no raw value is hardcoded here either.
    private func alternates() throws -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]

        func put<T: Encodable>(_ name: String, _ value: T) throws {
            out[name] = try JSONValue(encoding: value)
        }

        // enums whose JSON is a string or an object, where an arbitrary value of that JSON
        // type is not a valid case
        try put("cleanMethod", CleanMethod.selective)          // default is .automatic(false)
        try put("detectionType", Self.other(than: Config().detectionType))
        try put("codec", Self.other(than: Config().codec))
        try put("encoder", Self.other(than: Config().encoder))
        try put("pixelFormat", Self.other(than: Config().pixelFormat))
        try put("muxer", Self.other(than: Config().muxer))
        try put("frameRate", Self.other(than: Config().frameRate))

        // dictionaries that default to empty: there is nothing in them to perturb
        try put("pixelReplacementOverrides", [7: CleanMethod.selective])
        try put("staticNeighborFrameOverrides", [7: 21])
        try put("alignedNeighborFrameOverrides", [7: 13])

        // Optionals that default to nil, so the encoder leaves them out entirely
        try put("finalOutputDir", "some/final/output/dir")
        try put("horizonMinY", 111)
        try put("horizonMaxY", 222)

        return out
    }

    /// The encoded defaults, with every value replaced by a different one of the same shape.
    private func mutatedEncoding(of config: Config) throws -> [String: JSONValue] {
        guard case .object(let encoded) = try JSONValue(encoding: config) else {
            throw Unperturbable("a Config did not encode as a JSON object")
        }

        var out = try alternates()
        for (key, value) in encoded where out[key] == nil {
            out[key] = try Self.perturb(value, key)
        }
        return out
    }

    /// A different value of the same JSON type. Numbers move by one, bools flip, strings
    /// gain a suffix, arrays are perturbed elementwise.
    ///
    /// Exhaustive over `JSONValue` on purpose: a property encoded in a shape this cannot
    /// handle fails the test with instructions rather than being skipped.
    private static func perturb(_ value: JSONValue, _ key: String) throws -> JSONValue {
        switch value {
        case .bool(let bool):
            return .bool(!bool)
        case .int(let int):
            // an Int property never encodes as a fraction, so an integral JSON number is the
            // only safe perturbation; a Double property takes one fine
            return .int(int + 1)
        case .double(let double):
            return .double(double + 1)
        case .string(let string):
            return .string(string + "-perturbed")
        case .array(let array):
            return .array(try array.map { try perturb($0, key) })
        case .object, .null:
            throw Unperturbable("""
                                no way to perturb Config.\(key), which encodes as \
                                \(value). Give it an explicit alternate in \
                                ConfigRoundTripTests.alternates().
                                """)
        }
    }

    // MARK: - reflection helpers

    /// The stored properties of a `Config`, rendered as strings so they can be compared
    /// without `Config` or any of its field types having to be `Equatable`.
    ///
    /// `Mirror` is the point of this file: it reports what the struct has right now, so
    /// neither the test nor its coverage has to be kept in step with `Config` by hand.
    private static func propertiesByName(of config: Config) -> [String: String] {
        var out: [String: String] = [:]
        for child in Mirror(reflecting: config).children {
            if let label = child.label {
                out[label] = String(describing: child.value)
            }
        }
        return out
    }

    /// Any case other than the given one, so the alternates carry no literal raw values.
    private static func other<T: CaseIterable & Equatable>(than value: T) -> T {
        T.allCases.first { $0 != value } ?? value
    }

    private static func describe(_ error: DecodingError) -> String {
        let context: DecodingError.Context?
        switch error {
        case .keyNotFound(_, let c):   context = c
        case .typeMismatch(_, let c):  context = c
        case .valueNotFound(_, let c): context = c
        case .dataCorrupted(let c):    context = c
        @unknown default:              context = nil
        }
        guard let context else { return ": \(error)\n" }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return " at '\(path.isEmpty ? "<root>" : path)': \(context.debugDescription)\n"
    }
}

private struct Unperturbable: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A JSON value that keeps its type.
///
/// The obvious tool here is `JSONSerialization`, but its `Any` values arrive as `NSNumber`,
/// where `1 as? Bool` succeeds — so every Int property that happens to default to 0 or 1
/// would be perturbed into a boolean and then fail to decode. Going through `JSONDecoder`
/// keeps bools and numbers apart, and makes `perturb` exhaustive over a closed set of shapes
/// rather than a chain of dynamic casts.
private enum JSONValue: Codable, CustomStringConvertible {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    /// Whatever `value` encodes to. Wrapped in an array on the way out because a top-level
    /// JSON fragment is not portably encodable.
    init<T: Encodable>(encoding value: T) throws {
        let data = try JSONEncoder().encode([value])
        self = try JSONDecoder().decode([JSONValue].self, from: data)[0]
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)                     // JSONDecoder will not read 1 as true
        } else if let v = try? c.decode(Int.self) {
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v):   try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null:          try c.encodeNil()
        }
    }

    var description: String {
        switch self {
        case .bool(let v):   "\(v)"
        case .int(let v):    "\(v)"
        case .double(let v): "\(v)"
        case .string(let v): "\"\(v)\""
        case .array(let v):  "[\(v.map(\.description).joined(separator: ", "))]"
        case .object(let v): "{\(v.map { "\($0.key): \($0.value)" }.joined(separator: ", "))}"
        case .null:          "null"
        }
    }
}
