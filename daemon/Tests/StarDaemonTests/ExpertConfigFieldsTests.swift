import XCTest
import StarCore
import StarDaemonMessages

// The expert Config fields are `optional` in the proto on purpose: an unset field has to
// keep StarCore's own (non-zero) default instead of being clobbered by a proto3 zero.
// horizonReservationFloorMb makes that load-bearing rather than merely tidy — 0 is a
// meaningful value there, meaning "no floor, use the multiplier alone". With implicit
// presence a client asking for no floor would be indistinguishable from a client not
// mentioning the field, and the daemon would silently apply the 900MB default instead.
final class ExpertConfigFieldsTests: XCTestCase {

    func testHorizonFieldsRoundTripOverTheWire() throws {
        var c = Star_V1_Config()
        c.horizonMemoryMultiplier = 7
        c.horizonReservationFloorMb = 1200

        let back = try Star_V1_Config(serializedBytes: try c.serializedData())
        XCTAssertTrue(back.hasHorizonMemoryMultiplier)
        XCTAssertTrue(back.hasHorizonReservationFloorMb)
        XCTAssertEqual(back.horizonMemoryMultiplier, 7)
        XCTAssertEqual(back.horizonReservationFloorMb, 1200)
    }

    func testAPresentZeroFloorStaysPresent() throws {
        var c = Star_V1_Config()
        c.horizonReservationFloorMb = 0      // "no floor", not "unspecified"

        let back = try Star_V1_Config(serializedBytes: try c.serializedData())
        XCTAssertTrue(back.hasHorizonReservationFloorMb,
                      "a floor of 0 must survive as PRESENT, or disabling the floor is "
                      + "indistinguishable from not setting it and the default wins")
        XCTAssertEqual(back.horizonReservationFloorMb, 0)
    }

    func testUnsetHorizonFieldsStayAbsent() throws {
        let c = Star_V1_Config()
        let back = try Star_V1_Config(serializedBytes: try c.serializedData())
        XCTAssertFalse(back.hasHorizonMemoryMultiplier)
        XCTAssertFalse(back.hasHorizonReservationFloorMb,
                       "an untouched field must stay absent so StarCore's default survives")
    }

    /// The defaults the daemon reports to a client should be StarCore's, not zeros.
    func testStarCoreDefaultsAreWhatTheClientWouldSee() {
        let c = Config()
        XCTAssertEqual(c.horizonMemoryMultiplier, 7)
        XCTAssertEqual(c.horizonReservationFloorMB, 900)
        // And the floor is the binding one below ~17MP, which is the whole reason it exists.
        var small = c
        small.imageWidth = 3000; small.imageHeight = 2000
        small.imageBytesPerPixel = 6; small.imageBitsPerComponent = 16
        XCTAssertGreaterThan(small.effectiveHorizonMemoryMultiplier(),
                             small.horizonMemoryMultiplier)
    }
}
