import XCTest
import StarCore
import StarDaemonMessages
@testable import stard

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

    // MARK: - the memory budget

    func testTheMemoryBudgetRoundTripsAndIsClampedToItsRange() {
        var config = Config()
        XCTAssertEqual(config.maxMatMemoryFraction, 0.85, accuracy: 1e-12, "the default leaves about 15% headroom")
        XCTAssertEqual(Mapping.protoConfig(config).maxMatMemoryFraction, 0.85, accuracy: 1e-12)

        var p = Star_V1_Config()
        p.maxMatMemoryFraction = 0.6
        Mapping.applyExpertConfig(&config, from: p)
        XCTAssertEqual(config.maxMatMemoryFraction, 0.6, accuracy: 1e-12)

        for (sent, kept) in [(0.0, 0.1), (-3.0, 0.1), (0.05, 0.1), (1.0, 0.95), (40.0, 0.95), (0.1, 0.1), (0.95, 0.95)] {
            p.maxMatMemoryFraction = sent
            Mapping.applyExpertConfig(&config, from: p)
            XCTAssertEqual(config.maxMatMemoryFraction, kept, accuracy: 1e-12, "sent \(sent)")
        }
    }

    func testANonNumberIsNotAPercentage() {
        var config = Config()
        var p = Star_V1_Config()
        p.maxMatMemoryFraction = .nan
        Mapping.applyExpertConfig(&config, from: p)
        XCTAssertEqual(config.maxMatMemoryFraction, 0.85, accuracy: 1e-12, "NaN leaves the budget alone")
    }

    func testAnAbsentMemoryBudgetLeavesTheConfigAlone() {
        var config = Config()
        config.maxMatMemoryFraction = 0.5
        Mapping.applyExpertConfig(&config, from: Star_V1_Config())
        XCTAssertEqual(config.maxMatMemoryFraction, 0.5, accuracy: 1e-12)
    }

    // MARK: - the pixel threshold (P2 of the parity plan: the Kotlin client had no control for it)

    func testThePixelThresholdRoundTripsAndIsClampedToTheGuisRange() {
        var config = Config()
        XCTAssertEqual(config.pixelThreshold, 1.2, accuracy: 1e-12)
        XCTAssertEqual(Mapping.protoConfig(config).pixelThreshold, 1.2, accuracy: 1e-12)
        XCTAssertTrue(Mapping.protoConfig(config).hasPixelThreshold, "always sent, so the client's dialog shows the current value")

        var p = Star_V1_Config()
        p.pixelThreshold = 2.5
        Mapping.applyExpertConfig(&config, from: p)
        XCTAssertEqual(config.pixelThreshold, 2.5, accuracy: 1e-12)

        for (sent, kept) in [(0.0, 0.001), (-1.0, 0.001), (0.0001, 0.001), (10.0, 10.0), (11.0, 10.0), (500.0, 10.0)] {
            p.pixelThreshold = sent
            Mapping.applyExpertConfig(&config, from: p)
            XCTAssertEqual(config.pixelThreshold, kept, accuracy: 1e-12, "sent \(sent)")
        }
    }

    func testANonNumberOrAnAbsentThresholdLeavesTheConfigAlone() {
        var config = Config()
        config.pixelThreshold = 3
        var p = Star_V1_Config()
        p.pixelThreshold = .nan
        Mapping.applyExpertConfig(&config, from: p)
        XCTAssertEqual(config.pixelThreshold, 3, accuracy: 1e-12)
        Mapping.applyExpertConfig(&config, from: Star_V1_Config())
        XCTAssertEqual(config.pixelThreshold, 3, accuracy: 1e-12)
    }

    // MARK: - the limits behind Custom (P9 of the parity plan: the Kotlin client had no popover for them)

    func testTheCustomLimitsAreAlwaysSentAndComeBackApplied() {
        var config = Config()
        let sent = Mapping.protoConfig(config)
        XCTAssertTrue(sent.hasCustomCpuWidth && sent.hasCustomQos && sent.hasCustomGpuWidth && sent.hasCustomGpuDutyCycle
                      && sent.hasCustomDiskStreamsPerVolume && sent.hasCustomIoPolicy, "always sent, so the popover opens on the current values")
        XCTAssertEqual(Int(sent.customCpuWidth), config.customResources.cpuWidth)
        XCTAssertEqual(sent.customQos, config.customResources.qos.rawValue)

        var p = Star_V1_Config()
        p.customCpuWidth = 6
        p.customQos = "background"
        p.customGpuWidth = 3
        p.customGpuDutyCycle = 0.4
        p.customDiskStreamsPerVolume = 2
        p.customIoPolicy = "throttle"
        Mapping.applyExpertConfig(&config, from: p)
        XCTAssertEqual(config.customResources, CustomResourceLimits(cpuWidth: 6, qos: .background, gpuWidth: 3, gpuDutyCycle: 0.4,
                                                                    diskStreamsPerVolume: 2, ioPolicy: .throttle))
        XCTAssertEqual(config.resourceProfile, .full, "the limits are stored; the profile is chosen separately")
    }

    func testTheCustomLimitsAreClampedToThePopoversRanges() {
        var config = Config()
        var p = Star_V1_Config()
        for (sent, kept) in [(0, 1), (-4, 1), (256, 256), (1000, 256)] {
            p.customCpuWidth = Int32(sent)
            Mapping.applyExpertConfig(&config, from: p)
            XCTAssertEqual(config.customResources.cpuWidth, kept, "cpu \(sent)")
        }
        for (sent, kept) in [(0, 1), (32, 32), (99, 32)] {
            p.customGpuWidth = Int32(sent)
            Mapping.applyExpertConfig(&config, from: p)
            XCTAssertEqual(config.customResources.gpuWidth, kept, "gpu \(sent)")
        }
        for (sent, kept) in [(0.0, 0.05), (-1.0, 0.05), (0.5, 0.5), (1.0, 1.0), (7.0, 1.0)] {
            p.customGpuDutyCycle = sent
            Mapping.applyExpertConfig(&config, from: p)
            XCTAssertEqual(config.customResources.gpuDutyCycle, kept, accuracy: 1e-12, "duty \(sent)")
        }
        for (sent, kept) in [(0, 1), (16, 16), (40, 16)] {
            p.customDiskStreamsPerVolume = Int32(sent)
            Mapping.applyExpertConfig(&config, from: p)
            XCTAssertEqual(config.customResources.diskStreamsPerVolume, kept, "disk \(sent)")
        }
    }

    func testANameThatIsNotOneOfTheListedAndANonNumberAreIgnored() {
        var config = Config()
        let before = config.customResources
        var p = Star_V1_Config()
        p.customQos = "realtime"
        p.customIoPolicy = "turbo"
        p.customGpuDutyCycle = .nan
        Mapping.applyExpertConfig(&config, from: p)
        XCTAssertEqual(config.customResources, before)
    }

    /// Opening Custom must change nothing until a limit is edited: the limits start as the profile that was in effect, as the gui's
    /// `resourceProfile` observer does with `makeCustom`.  The client's copy of the config still holds whatever the limits were last, so
    /// the client says so when it is opening Custom.
    func testOpeningCustomWhenAskedTakesTheLimitsOfTheProfileItLeaves() {
        var config = Config()
        config.resourceProfile = .light
        var p = Mapping.protoConfig(config)       // the client's copy, echoing every limit
        p.resourceProfile = "custom"
        p.startCustomFromProfile = true
        p.maxMatMemoryFraction = 0.9
        Mapping.applyExpertConfig(&config, from: p)

        let light = ResourceLimits.preset(.light)
        XCTAssertEqual(config.resourceProfile, .custom)
        XCTAssertEqual(config.customResources.cpuWidth, light.cpuWidth)
        XCTAssertEqual(config.customResources.qos, light.qos)
        XCTAssertEqual(config.customResources.gpuWidth, light.gpuWidth)
        XCTAssertEqual(config.customResources.gpuDutyCycle, light.gpuDutyCycle, accuracy: 1e-12)
        XCTAssertEqual(config.customResources.diskStreamsPerVolume, light.diskStreamsPerVolume)
        XCTAssertEqual(config.customResources.ioPolicy, light.ioPolicy)
        XCTAssertEqual(config.maxMatMemoryFraction, light.memoryFraction, accuracy: 1e-12, "the memory budget starts as the profile's too")
        XCTAssertEqual(config.numberOfFramesToProcessConcurrently, light.pipelineDepth)
        XCTAssertEqual(config.resources, light, "nothing changes until the user edits a limit")
    }

    /// The settings sheet switches to Custom and edits the pipeline depth in one save; without the flag, what it sends is what it means.
    func testASwitchToCustomWithoutTheFlagKeepsWhatItCarries() {
        var config = Config()
        config.resourceProfile = .balanced
        var p = Star_V1_Config()
        p.resourceProfile = "custom"
        p.customCpuWidth = 3
        Mapping.applyExpertConfig(&config, from: p)
        XCTAssertEqual(config.resourceProfile, .custom)
        XCTAssertEqual(config.customResources.cpuWidth, 3)
        XCTAssertEqual(config.numberOfFramesToProcessConcurrently, Config().numberOfFramesToProcessConcurrently, "nothing was taken over from Balanced")
    }

    func testTheFlagMeansNothingUnlessTheProfileIsChangingToCustom() {
        var config = Config()
        config.customResources.cpuWidth = 5
        var p = Star_V1_Config()
        p.startCustomFromProfile = true
        p.resourceProfile = "balanced"
        Mapping.applyExpertConfig(&config, from: p)
        XCTAssertEqual(config.resourceProfile, .balanced)
        XCTAssertEqual(config.customResources.cpuWidth, 5, "leaving Custom keeps what was set, for the next time")

        config.resourceProfile = .custom
        p.resourceProfile = "custom"
        Mapping.applyExpertConfig(&config, from: p)
        XCTAssertEqual(config.customResources.cpuWidth, 5, "already custom: nothing to take over")
        XCTAssertFalse(Mapping.protoConfig(config).hasStartCustomFromProfile, "the daemon never sends it")
    }

    // MARK: - who chose the divisor

    /// `set(imageInfo:)` picks a divisor for a client that did not (`resolveAutomaticKeypointDivisor`), and must not pick one over the
    /// top of a client that did.  The daemon cannot tell the two apart except by the field being present, so presence has to be what
    /// marks it chosen, and a message that never mentions it has to leave the decision open.
    func testSendingADivisorMarksItChosen() {
        var p = Star_V1_Config()
        p.alignmentKeypointDetectionDivisor = 1.0     // an explicit "full resolution" is a choice too

        var c = Config()
        XCTAssertFalse(c.keypointDivisorWasChosen)
        Mapping.applyExpertConfig(&c, from: p)

        XCTAssertTrue(c.keypointDivisorWasChosen)
        XCTAssertEqual(c.alignmentKeypointDetectionDivisor, 1.0)
    }

    func testNotSendingADivisorLeavesTheChoiceToTheAutomaticDefault() {
        var c = Config()
        Mapping.applyExpertConfig(&c, from: Star_V1_Config())
        XCTAssertFalse(c.keypointDivisorWasChosen,
                       "a client that never mentioned the divisor gets the automatic default, not a settled full resolution")
    }

    // MARK: - the unfinished horizon selection

    /// The pair that records a hand-painted horizon selection the user did not finish. Not
    /// an expert setting — recorded state — but it lives in the same message and has the
    /// same presence hazard, in a sharper form: `repeated` cannot be `optional`, so an
    /// empty list is indistinguishable from an unset one.

    func testAnUnfinishedSelectionRoundTripsOverTheWire() throws {
        var c = Star_V1_Config()
        c.startupHorizonFrameIndices = [0, 25, 50, 75, 99]
        c.startupHorizonFramePosition = 2

        let back = try Star_V1_Config(serializedBytes: try c.serializedData())
        XCTAssertEqual(back.startupHorizonFrameIndices, [0, 25, 50, 75, 99])
        XCTAssertEqual(back.startupHorizonFramePosition, 2)
    }

    /// Position 0 — stopped before painting anything — is the most likely value of all, and
    /// the one a proto3 zero would lose.
    func testAPresentZeroPositionStaysPresent() throws {
        var c = Star_V1_Config()
        c.startupHorizonFrameIndices = [0, 50, 99]
        c.startupHorizonFramePosition = 0

        let back = try Star_V1_Config(serializedBytes: try c.serializedData())
        XCTAssertTrue(back.hasStartupHorizonFramePosition,
                      "the position is what applyExpertConfig gates the pair on; losing "
                      + "presence at 0 drops the commonest record of all")
    }

    func testAnUntouchedSelectionStaysAbsent() throws {
        let back = try Star_V1_Config(serializedBytes: try Star_V1_Config().serializedData())
        XCTAssertFalse(back.hasStartupHorizonFramePosition)
        XCTAssertTrue(back.startupHorizonFrameIndices.isEmpty)
    }

    /// What the gate is for. The expert dialog builds its update from the config the daemon
    /// sent, but a client built before these fields existed does not — and applying its
    /// empty list would wipe the selection the user is part way through.
    func testAConfigThatNeverMentionsTheSelectionLeavesItAlone() {
        var c = Config()
        c.startupHorizonFrameIndices = [0, 50, 99]
        c.startupHorizonFramePosition = 1

        Mapping.applyExpertConfig(&c, from: Star_V1_Config())

        XCTAssertEqual(c.startupHorizonFrameIndices, [0, 50, 99])
        XCTAssertEqual(c.startupHorizonFramePosition, 1)
    }

    /// And the other direction: a client that *does* know about them can clear the record,
    /// which is how finishing or cancelling the selection is reported.
    func testAPresentEmptySelectionClearsTheRecord() {
        var c = Config()
        c.startupHorizonFrameIndices = [0, 50, 99]
        c.startupHorizonFramePosition = 1

        var p = Star_V1_Config()
        p.startupHorizonFramePosition = 0    // present, with no indices alongside it
        Mapping.applyExpertConfig(&c, from: p)

        XCTAssertTrue(c.startupHorizonFrameIndices.isEmpty)
        XCTAssertEqual(c.startupHorizonFramePosition, 0)
    }

    /// The daemon always reports the record, so a client can tell on open that the last
    /// session left a selection unfinished without asking a second question.
    func testTheDaemonReportsTheSelectionToClients() {
        var c = Config()
        c.startupHorizonFrameIndices = [4, 8, 15]
        c.startupHorizonFramePosition = 1

        let p = Mapping.protoConfig(c)
        XCTAssertEqual(p.startupHorizonFrameIndices, [4, 8, 15])
        XCTAssertEqual(p.startupHorizonFramePosition, 1)
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

/// The resource profile ("Use of this Mac") over the wire. Hand-added to star.pb.swift
/// (`protoc` was not available), so the round trip below is what proves the generated
/// code's name map, decode, visit and equality agree with each other.
final class ResourceProfileFieldTests: XCTestCase {

    func testTheProfileRoundTripsOverTheWire() throws {
        var c = Star_V1_Config()
        c.resourceProfile = "light"
        let back = try Star_V1_Config(serializedBytes: try c.serializedData())
        XCTAssertTrue(back.hasResourceProfile)
        XCTAssertEqual(back.resourceProfile, "light")
        XCTAssertEqual(back, c)
    }

    func testTheNameMapKnowsTheField() throws {
        var c = Star_V1_Config()
        c.resourceProfile = "balanced"
        let json = try c.jsonString()
        XCTAssertTrue(json.contains("resourceProfile"), json)
        let back = try Star_V1_Config(jsonString: json)
        XCTAssertEqual(back.resourceProfile, "balanced")
    }

    func testAnUnsetProfileKeepsTheConfigsOwn() {
        var c = Config()
        c.resourceProfile = .balanced
        Mapping.applyExpertConfig(&c, from: Star_V1_Config())
        XCTAssertEqual(c.resourceProfile, .balanced)
    }

    func testAPresentProfileIsApplied() {
        var c = Config()
        var p = Star_V1_Config()
        p.resourceProfile = "light"
        Mapping.applyExpertConfig(&c, from: p)
        XCTAssertEqual(c.resourceProfile, .light)
    }

    func testAnUnknownProfileIsIgnored() {
        var c = Config()
        var p = Star_V1_Config()
        p.resourceProfile = "turbo"
        Mapping.applyExpertConfig(&c, from: p)
        XCTAssertEqual(c.resourceProfile, .full)
    }

    func testTheDaemonReportsTheProfile() {
        var c = Config()
        c.resourceProfile = .custom
        XCTAssertEqual(Mapping.protoConfig(c).resourceProfile, "custom")
    }
}
