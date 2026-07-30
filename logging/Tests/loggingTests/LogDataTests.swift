import XCTest
@testable import logging

/// The data side of the logging package: `StringLogData` is what every `Log.x(message, data)`
/// call wraps its payload in, and the `Encodable`/`Data` extensions are the json helpers the
/// handlers use to render it.  None of it was covered.
final class LogDataTests: XCTestCase {

    // MARK: - StringLogData

    func testAStringIsCarriedThroughVerbatim() {
        XCTAssertEqual(StringLogData(with: "hello").description, "hello")
        XCTAssertEqual(StringLogData(with: "").description, "")
    }

    /// Unicode and newlines have to survive — filenames and error messages contain both.
    func testAwkwardStringsSurvive() {
        for text in ["a\nb", "  spaced  ", "emoji 🚩", "tab\there", "quote\"inside"] {
            XCTAssertEqual(StringLogData(with: text).description, text)
        }
    }

    /// A `CustomStringConvertible` uses its own `description` rather than a reflected form, which
    /// is what lets the value types in StarCore print themselves usefully in a log line.
    func testACustomStringConvertibleUsesItsOwnDescription() {
        struct Described: CustomStringConvertible {
            let description = "I describe myself"
        }
        XCTAssertEqual(StringLogData(with: Described() as CustomStringConvertible).description,
                       "I describe myself")
    }

    /// Anything else falls back to `String(describing:)`, so a plain struct still logs something
    /// readable instead of nothing.
    func testAPlainValueFallsBackToStringDescribing() {
        struct Plain { let number: Int }
        let data = StringLogData(with: Plain(number: 42))
        XCTAssertFalse(data.description.isEmpty)
        XCTAssertTrue(data.description.contains("42"),
                      "the reflected form should include the value: \(data.description)")
    }

    func testNumbersAndCollectionsAreDescribable() {
        XCTAssertEqual(StringLogData(with: 42).description, "42")
        XCTAssertEqual(StringLogData(with: 1.5).description, "1.5")
        XCTAssertEqual(StringLogData(with: true).description, "true")
        XCTAssertEqual(StringLogData(with: [1, 2, 3]).description, "[1, 2, 3]")
    }

    /// An optional is a common accident at a log site.  It must not trap, and it should be
    /// visibly nil rather than silently empty.
    func testAnOptionalDescribesItselfWithoutTrapping() {
        let absent: Int? = nil
        XCTAssertEqual(StringLogData(with: absent).description, "nil")

        let present: Int? = 7
        XCTAssertTrue(StringLogData(with: present).description.contains("7"))
    }

    /// `StringLogData` is the concrete `LogData` every handler receives, so it has to satisfy
    /// the protocol's `Sendable` and `CustomStringConvertible` requirements.
    func testItIsUsableAsTheLogDataProtocol() {
        let data: LogData = StringLogData(with: "payload")
        XCTAssertEqual(data.description, "payload")
    }

    // MARK: - the json helpers

    func testAnEncodableValueRendersAsJson() throws {
        struct Payload: Codable, Equatable {
            let foo: String
            let bar: Int?
        }
        let payload = Payload(foo: "hi", bar: 3)

        let data = try XCTUnwrap(payload.jsonData)
        let text = try XCTUnwrap(data.utf8String)
        XCTAssertTrue(text.contains("\"foo\""))
        XCTAssertTrue(text.contains("\"hi\""))
        XCTAssertTrue(text.contains("3"))

        // and it is real json, not just a description that looks like it
        XCTAssertEqual(try JSONDecoder().decode(Payload.self, from: data), payload)
    }

    func testAnAbsentOptionalIsOmittedFromTheJson() throws {
        struct Payload: Codable { let foo: String; let bar: Int? }
        let text = try XCTUnwrap(Payload(foo: "hi", bar: nil).jsonData?.utf8String)
        XCTAssertTrue(text.contains("foo"))
        XCTAssertFalse(text.contains("bar"), "a nil optional should not appear: \(text)")
    }

    func testJsonDataIsNilRatherThanThrowingForAValueThatCannotEncode() {
        /// A non-conforming Double is the classic un-encodable value for JSONEncoder's default
        /// strategy.  `jsonData` swallows the error into a nil, which is what keeps a log call
        /// from taking down the process.
        struct Bad: Encodable { let value = Double.nan }
        XCTAssertNil(Bad().jsonData)
    }

    func testUtf8StringRoundTripsText() {
        for text in ["plain", "", "emoji 🚩", "multi\nline"] {
            XCTAssertEqual(Data(text.utf8).utf8String, text)
        }
    }

    func testUtf8StringIsNilForBytesThatAreNotUtf8() {
        // 0xFF is never a valid utf8 byte
        XCTAssertNil(Data([0xFF, 0xFE, 0xFD]).utf8String)
    }

    func testUtf8StringOfNoBytesIsAnEmptyStringNotNil() {
        XCTAssertEqual(Data().utf8String, "")
    }
}
