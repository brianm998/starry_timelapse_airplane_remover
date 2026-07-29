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

    /// Every field whose 0 means something, not just the floor. StarCore's defaults are
    /// 900, 0 and 2048, so for two of these a lost presence bit silently substitutes a
    /// different behaviour: the client asks for "never stream" and gets streaming at
    /// 2048MB, or asks for "no floor" and gets 900MB.
    func testEveryMeaningfulZeroSurvivesAsPresent() throws {
        var c = Star_V1_Config()
        c.horizonReservationFloorMb = 0      // no floor
        c.maxConcurrentKeypointOps = 0       // no explicit cap
        c.mergeStreamingThresholdMb = 0      // never stream, keep every source resident

        let back = try Star_V1_Config(serializedBytes: try c.serializedData())
        XCTAssertTrue(back.hasHorizonReservationFloorMb)
        XCTAssertTrue(back.hasMaxConcurrentKeypointOps)
        XCTAssertTrue(back.hasMergeStreamingThresholdMb,
                      "0 here means never stream; losing presence would stream at the "
                      + "2048MB default instead, which is the opposite of the request")
        XCTAssertEqual(back.mergeStreamingThresholdMb, 0)
    }

    /// A false bool has the same hazard in principle. It is harmless today only because
    /// StarCore's default happens to be false too — this test is what would catch it if
    /// that default ever flipped.
    func testAPresentFalseHalfResStaysPresent() throws {
        var c = Star_V1_Config()
        c.alignmentHalfResolutionKeypoints = false

        let back = try Star_V1_Config(serializedBytes: try c.serializedData())
        XCTAssertTrue(back.hasAlignmentHalfResolutionKeypoints)
        XCTAssertFalse(back.alignmentHalfResolutionKeypoints)
    }

    func testHalfResAndCapsRoundTrip() throws {
        var c = Star_V1_Config()
        c.alignmentHalfResolutionKeypoints = true
        c.maxConcurrentKeypointOps = 3
        c.mergeStreamingThresholdMb = 1024

        let back = try Star_V1_Config(serializedBytes: try c.serializedData())
        XCTAssertTrue(back.alignmentHalfResolutionKeypoints)
        XCTAssertEqual(back.maxConcurrentKeypointOps, 3)
        XCTAssertEqual(back.mergeStreamingThresholdMb, 1024)
    }

    func testUnsetHorizonFieldsStayAbsent() throws {
        let c = Star_V1_Config()
        let back = try Star_V1_Config(serializedBytes: try c.serializedData())
        XCTAssertFalse(back.hasHorizonMemoryMultiplier)
        XCTAssertFalse(back.hasHorizonReservationFloorMb,
                       "an untouched field must stay absent so StarCore's default survives")
        XCTAssertFalse(back.hasAlignmentHalfResolutionKeypoints)
        XCTAssertFalse(back.hasMaxConcurrentKeypointOps)
        XCTAssertFalse(back.hasMergeStreamingThresholdMb)
    }

    /// The defaults the daemon reports to a client should be StarCore's, not zeros.
    func testStarCoreDefaultsAreWhatTheClientWouldSee() {
        let c = Config()
        XCTAssertEqual(c.horizonMemoryMultiplier, 7)
        XCTAssertEqual(c.horizonReservationFloorMB, 900)
        XCTAssertEqual(c.alignmentHalfResolutionKeypoints, false)
        XCTAssertEqual(c.maxConcurrentKeypointOps, 0)
        XCTAssertEqual(c.mergeStreamingThresholdMB, 2048)
        // And the floor is the binding one below ~17MP, which is the whole reason it exists.
        var small = c
        small.imageWidth = 3000; small.imageHeight = 2000
        small.imageBytesPerPixel = 6; small.imageBitsPerComponent = 16
        XCTAssertGreaterThan(small.effectiveHorizonMemoryMultiplier(),
                             small.horizonMemoryMultiplier)
    }
}
