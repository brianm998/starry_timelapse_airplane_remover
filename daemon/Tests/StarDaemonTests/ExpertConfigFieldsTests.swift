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
    /// 900, 0 and 8192, so for two of these a lost presence bit silently substitutes a
    /// different behaviour: the client asks for "never stream" and gets streaming at
    /// 8192MB, or asks for "no floor" and gets 900MB.
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
                      + "8192MB default instead, which is the opposite of the request")
        XCTAssertEqual(back.mergeStreamingThresholdMb, 0)
    }

    /// The keypoint divisor's hazard is the mirror of the ones above. proto3's implicit
    /// default for a double is 0, StarCore's is 1.0, and 0 is not a value the pipeline can
    /// honour — Config clamps anything <= 1 to full resolution. So presence is what keeps a
    /// deliberate "detect at full resolution" distinguishable from a client that never
    /// mentioned the field, and keeps a 0 arriving from the Kotlin client's unclamped
    /// DoubleField from reading as a real request.
    func testAPresentFullResolutionDivisorStaysPresent() throws {
        var c = Star_V1_Config()
        c.alignmentKeypointDetectionDivisor = 1.0

        let back = try Star_V1_Config(serializedBytes: try c.serializedData())
        XCTAssertTrue(back.hasAlignmentKeypointDetectionDivisor)
        XCTAssertEqual(back.alignmentKeypointDetectionDivisor, 1.0)
    }

    func testKeypointDivisorAndCapsRoundTrip() throws {
        var c = Star_V1_Config()
        c.alignmentKeypointDetectionDivisor = 2.0
        c.maxConcurrentKeypointOps = 3
        c.mergeStreamingThresholdMb = 1024

        let back = try Star_V1_Config(serializedBytes: try c.serializedData())
        XCTAssertEqual(back.alignmentKeypointDetectionDivisor, 2.0)
        XCTAssertEqual(back.maxConcurrentKeypointOps, 3)
        XCTAssertEqual(back.mergeStreamingThresholdMb, 1024)
    }

    /// The value the change exists for: a divisor between the two the bool could express.
    func testANonIntegerDivisorSurvivesTheWire() throws {
        var c = Star_V1_Config()
        c.alignmentKeypointDetectionDivisor = 1.5

        let back = try Star_V1_Config(serializedBytes: try c.serializedData())
        XCTAssertTrue(back.hasAlignmentKeypointDetectionDivisor)
        XCTAssertEqual(back.alignmentKeypointDetectionDivisor, 1.5, accuracy: 1e-12,
                       "a double field, not the int the other memory knobs use — 1.5 has "
                       + "to arrive as 1.5 and not be truncated to 1")
    }

    func testUnsetHorizonFieldsStayAbsent() throws {
        let c = Star_V1_Config()
        let back = try Star_V1_Config(serializedBytes: try c.serializedData())
        XCTAssertFalse(back.hasHorizonMemoryMultiplier)
        XCTAssertFalse(back.hasHorizonReservationFloorMb,
                       "an untouched field must stay absent so StarCore's default survives")
        XCTAssertFalse(back.hasAlignmentKeypointDetectionDivisor)
        XCTAssertFalse(back.hasMaxConcurrentKeypointOps)
        XCTAssertFalse(back.hasMergeStreamingThresholdMb)
    }

    /// The defaults the daemon reports to a client should be StarCore's, not zeros.
    func testStarCoreDefaultsAreWhatTheClientWouldSee() {
        let c = Config()
        XCTAssertEqual(c.horizonMemoryMultiplier, 7)
        XCTAssertEqual(c.horizonReservationFloorMB, 900)
        XCTAssertEqual(c.alignmentKeypointDetectionDivisor, 1.0)
        XCTAssertEqual(c.maxConcurrentKeypointOps, 0)
        XCTAssertEqual(c.mergeStreamingThresholdMB, 8192)
        // And the floor is the binding one below ~17MP, which is the whole reason it exists.
        var small = c
        small.imageWidth = 3000; small.imageHeight = 2000
        small.imageBytesPerPixel = 6; small.imageBitsPerComponent = 16
        XCTAssertGreaterThan(small.effectiveHorizonMemoryMultiplier(),
                             small.horizonMemoryMultiplier)
    }
}
