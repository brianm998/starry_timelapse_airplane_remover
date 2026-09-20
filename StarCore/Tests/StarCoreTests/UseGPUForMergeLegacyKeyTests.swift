import XCTest
@testable import StarCore

/// Tests for `useGPUForMerge`, which replaced the plain `useGPU` name (renamed so it could
/// not be misread as a single GPU-for-everything switch — `useGPUForSIFT`/`useGPUForAKAZE`
/// are separate flags that this rename does not touch). Same shape as
/// `KeypointDivisorTests`: old config.json files hold the old key, and `LegacyCodingKeys`
/// is the only place that key is still read.
final class UseGPUForMergeLegacyKeyTests: XCTestCase {

    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    func testLegacyKeyIsHonored() throws {
        let c = try decode(#"{"useGPU": false}"#)
        XCTAssertFalse(c.useGPUForMerge, "an old config.json's useGPU: false must still apply")
    }

    func testLegacyKeyDoesNotBreakTheWholeDecode() throws {
        let json = #"{"useGPU": false, "imageWidth": 7952}"#
        let c = try decode(json)
        XCTAssertEqual(c.imageWidth, 7952,
                       "a legacy key must not throw and take every other setting with it")
    }

    func testNewKeyWinsWhenBothArePresent() throws {
        let c = try decode(#"{"useGPUForMerge": true, "useGPU": false}"#)
        XCTAssertTrue(c.useGPUForMerge, "a config written by a newer star already has the new key")
    }

    func testAbsentKeysLeaveTheDefault() throws {
        let c = try decode(#"{"imageWidth": 100}"#)
        XCTAssertTrue(c.useGPUForMerge, "on by default")
    }
}
