import XCTest
@testable import logging

/// `Log.Level`'s comparison operators are the thing every handler's filtering runs through, and
/// their direction is the opposite of what the case order suggests: the enum reads
/// verbose, debug, info, warn, error, but the private `num` backing the operators runs the other
/// way — error is 0 and verbose is 4.  So `.error < .verbose`, and `LogGremlin.logNext` keeps a
/// line when `logLevel <= handler.level`.
///
/// Getting that backwards would either drop every error or print every verbose line, so it is
/// worth stating explicitly.
final class LogLevelTests: XCTestCase {

    /// Ordered most severe first, which is also ascending `num` order.
    private let bySeverity: [Log.Level] = [.error, .warn, .info, .debug, .verbose]

    // MARK: - ordering

    func testTheOrderRunsFromErrorUpToVerbose() {
        for (index, lower) in bySeverity.enumerated() {
            for higher in bySeverity[(index + 1)...] {
                XCTAssertTrue(lower < higher, "\(lower) should sort below \(higher)")
                XCTAssertTrue(lower <= higher)
                XCTAssertTrue(higher > lower)
                XCTAssertTrue(higher >= lower)
                XCTAssertFalse(lower == higher)
            }
        }
    }

    func testEachLevelIsEqualToItselfAndNotLessThanItself() {
        for level in bySeverity {
            XCTAssertTrue(level == level)
            XCTAssertTrue(level <= level)
            XCTAssertTrue(level >= level)
            XCTAssertFalse(level < level)
            XCTAssertFalse(level > level)
        }
    }

    /// The filtering rule as the gremlin actually applies it: a handler set to `level` keeps
    /// every line whose own level is `<=` its own.  Spelled out per handler level so a reversed
    /// comparison could not pass.
    func testAHandlerKeepsItsOwnLevelAndEverythingMoreSevere() {
        let expected: [Log.Level: [Log.Level]] = [
          .error:   [.error],
          .warn:    [.error, .warn],
          .info:    [.error, .warn, .info],
          .debug:   [.error, .warn, .info, .debug],
          .verbose: [.error, .warn, .info, .debug, .verbose],
        ]
        for (handlerLevel, kept) in expected {
            for line in bySeverity {
                XCTAssertEqual(line <= handlerLevel, kept.contains(line),
                               "a handler at \(handlerLevel) got \(line) wrong")
            }
        }
    }

    /// The most common configuration in the codebase — a console handler at `.info` — must show
    /// errors.  This is the concrete case the inverted ordering would break.
    func testAnInfoHandlerStillShowsErrorsAndWarnings() {
        XCTAssertTrue(Log.Level.error <= .info)
        XCTAssertTrue(Log.Level.warn <= .info)
        XCTAssertTrue(Log.Level.info <= .info)
        XCTAssertFalse(Log.Level.debug <= .info, "debug is noisier than info and is dropped")
        XCTAssertFalse(Log.Level.verbose <= .info)
    }

    func testTheOrderingIsTransitive() {
        XCTAssertTrue(Log.Level.error < .info)
        XCTAssertTrue(Log.Level.info < .verbose)
        XCTAssertTrue(Log.Level.error < .verbose)
    }

    // MARK: - the case list

    func testEveryLevelIsInAllCasesExactlyOnce() {
        XCTAssertEqual(Log.Level.allCases.count, 5)
        XCTAssertEqual(Set(Log.Level.allCases.map(\.rawValue)).count, 5)
        for level in bySeverity {
            XCTAssertTrue(Log.Level.allCases.contains(level), "\(level) is missing from allCases")
        }
    }

    /// `allCases` is declared in the source order, which is verbose first — the reverse of
    /// severity.  Anything presenting the list to a user (a picker, `--help`) sees this order.
    func testAllCasesIsInSourceOrderNotSeverityOrder() {
        XCTAssertEqual(Log.Level.allCases.map(\.rawValue),
                       ["verbose", "debug", "info", "warn", "error"])
    }

    // MARK: - string forms

    /// The raw value is what the cli parses from `-l`, so it has to be the lowercase name.
    func testTheRawValueIsTheLowercaseName() {
        XCTAssertEqual(Log.Level.verbose.rawValue, "verbose")
        XCTAssertEqual(Log.Level.debug.rawValue, "debug")
        XCTAssertEqual(Log.Level.info.rawValue, "info")
        XCTAssertEqual(Log.Level.warn.rawValue, "warn")
        XCTAssertEqual(Log.Level.error.rawValue, "error")
    }

    /// The description is what lands in the log file, uppercased.
    func testTheDescriptionIsTheUppercaseName() {
        XCTAssertEqual(Log.Level.verbose.description, "VERBOSE")
        XCTAssertEqual(Log.Level.debug.description, "DEBUG")
        XCTAssertEqual(Log.Level.info.description, "INFO")
        XCTAssertEqual(Log.Level.warn.description, "WARN")
        XCTAssertEqual(Log.Level.error.description, "ERROR")
    }

    func testEveryLevelHasItsOwnDescriptionAndEmoji() {
        XCTAssertEqual(Set(Log.Level.allCases.map(\.description)).count, 5)
        XCTAssertEqual(Set(Log.Level.allCases.map(\.emo)).count, 5,
                       "two levels share an emoji, so console output could not be told apart")
        for level in Log.Level.allCases {
            XCTAssertFalse(level.emo.isEmpty)
            XCTAssertFalse(level.description.isEmpty)
        }
    }

    func testTheDescriptionIsTheRawValueUppercased() {
        for level in Log.Level.allCases {
            XCTAssertEqual(level.description, level.rawValue.uppercased())
        }
    }

    // MARK: - decoding

    /// A level can come out of a config file, so decoding has to accept exactly the raw values
    /// and reject anything else rather than defaulting.
    func testEveryLevelDecodesFromItsRawValue() throws {
        for level in Log.Level.allCases {
            let json = Data("\"\(level.rawValue)\"".utf8)
            XCTAssertEqual(try JSONDecoder().decode(Log.Level.self, from: json), level)
        }
    }

    func testAnUnknownLevelFailsToDecode() {
        XCTAssertThrowsError(try JSONDecoder().decode(Log.Level.self, from: Data("\"chatty\"".utf8)))
    }

    func testTheDecodingIsCaseSensitive() {
        XCTAssertThrowsError(try JSONDecoder().decode(Log.Level.self, from: Data("\"INFO\"".utf8)),
                             "the uppercase form is the description, not the raw value")
    }
}
