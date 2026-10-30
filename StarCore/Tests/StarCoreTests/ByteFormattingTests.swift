import XCTest
@testable import StarCore

/// Layer 0 of the parity plan (§6.2.4): `gherkin/ui/vectors/byteFormat.json` is what `UInt64.humanReadableBytes` says, and the desktop's
/// `VideoImport.formatBytes` is held to the same file. The desktop used decimal units with a space ("1.5 KB"), so the same volume read
/// differently in its dialogs and in the daemon's own warnings (S9).
final class ByteFormattingTests: XCTestCase {

    private func vector() throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("gherkin/ui/vectors/byteFormat.json")
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(doc["cases"] as? [[String: Any]])
    }

    func testTheVectorIsWhatTheFormatterSays() throws {
        let cases = try vector()
        XCTAssertGreaterThan(cases.count, 10)
        for c in cases {
            let bytes = (c["bytes"] as! NSNumber).uint64Value
            XCTAssertEqual(bytes.humanReadableBytes, c["expected"] as? String, "\(bytes) bytes")
        }
    }
}
