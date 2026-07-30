import XCTest
import StarCore
import StarCppBridge
import StarDaemonMessages
@testable import stard

/// `Mapping` is the whole surface between StarCore's types and the wire.  `EnumParityTests`
/// covers the enums and `ExpertConfigFieldsTests` covers the optional expert settings, which
/// leaves the value types and the plain (non-optional) half of `Config` — everything a client
/// needs to draw a frame, a bounding box or an alignment result — with no coverage at all.
///
/// The recurring hazard on this boundary is proto3 implicit presence: an `Int32` field that is
/// not `optional` cannot tell "zero" from "unset", so anything with a meaningful zero has to be
/// carried some other way.  These tests pin which fields are which.
final class MappingTests: XCTestCase {

    // MARK: - BoundingBox

    func testABoundingBoxCrossesTheWireIntact() {
        let box = BoundingBox(min: Coord(x: 12, y: 34), max: Coord(x: 567, y: 890))
        let proto = Mapping.protoBoundingBox(box)

        XCTAssertEqual(proto.minX, 12)
        XCTAssertEqual(proto.minY, 34)
        XCTAssertEqual(proto.maxX, 567)
        XCTAssertEqual(proto.maxY, 890)
    }

    /// A blob touching the top-left corner has zeroes in it, and a box is always sent whole,
    /// so the zeroes have to survive rather than being read as "absent".
    func testABoundingBoxAtTheOriginKeepsItsZeroes() {
        let proto = Mapping.protoBoundingBox(BoundingBox(min: Coord(x: 0, y: 0),
                                                         max: Coord(x: 0, y: 0)))
        XCTAssertEqual(proto.minX, 0)
        XCTAssertEqual(proto.minY, 0)
        XCTAssertEqual(proto.maxX, 0)
        XCTAssertEqual(proto.maxY, 0)
    }

    func testABoundingBoxSurvivesProtobufSerialisation() throws {
        let box = BoundingBox(min: Coord(x: 1, y: 2), max: Coord(x: 3000, y: 4000))
        let data = try Mapping.protoBoundingBox(box).serializedData()
        let decoded = try Star_V1_BoundingBox(serializedBytes: data)

        XCTAssertEqual(Int(decoded.minX), box.min.x)
        XCTAssertEqual(Int(decoded.minY), box.min.y)
        XCTAssertEqual(Int(decoded.maxX), box.max.x)
        XCTAssertEqual(Int(decoded.maxY), box.max.y)
    }

    /// The four corners must not be transposed on the way out — a client drawing the box would
    /// put it in the wrong place, and it would look like a detection bug rather than a mapping
    /// one.
    func testTheCornersAreNotTransposed() {
        let wide = BoundingBox(min: Coord(x: 1, y: 100), max: Coord(x: 900, y: 200))
        let proto = Mapping.protoBoundingBox(wide)
        XCTAssertGreaterThan(proto.maxX - proto.minX, proto.maxY - proto.minY,
                             "a wide box came out tall")
    }

    // MARK: - AlignmentState

    /// Every alignment outcome needs its own wire value: the client shows a different thing for
    /// "no keypoints" than for "success", and two states collapsing onto one would be invisible
    /// until someone noticed the ui never showed a particular message.
    func testEveryAlignmentStateGetsItsOwnWireValue() {
        let states: [AlignmentState] = [.unableToDetectKeypoints, .notEnoughKeypoints,
                                        .noHomographyFound, .homographySuccess,
                                        .usedExistingHomography, .noAlignment, .unknown]
        let mapped = states.map { Mapping.protoAlignmentState($0) }
        XCTAssertEqual(Set(mapped).count, states.count,
                       "two alignment states share a wire value: \(mapped)")
    }

    func testEachAlignmentStateMapsToItsNamesake() {
        XCTAssertEqual(Mapping.protoAlignmentState(.unableToDetectKeypoints),
                       .alignUnableToDetectKeypoints)
        XCTAssertEqual(Mapping.protoAlignmentState(.notEnoughKeypoints), .alignNotEnoughKeypoints)
        XCTAssertEqual(Mapping.protoAlignmentState(.noHomographyFound), .alignNoHomographyFound)
        XCTAssertEqual(Mapping.protoAlignmentState(.homographySuccess), .alignHomographySuccess)
        XCTAssertEqual(Mapping.protoAlignmentState(.usedExistingHomography),
                       .alignUsedExistingHomography)
        XCTAssertEqual(Mapping.protoAlignmentState(.noAlignment), .alignNoAlignment)
        XCTAssertEqual(Mapping.protoAlignmentState(.unknown), .alignUnknown)
    }

    // MARK: - FrameViewMode

    func testEachViewModeMapsFromItsWireValue() {
        XCTAssertEqual(Mapping.frameViewMode(from: .viewOriginal), .original)
        XCTAssertEqual(Mapping.frameViewMode(from: .viewProcessed), .autoProcessed)
        XCTAssertEqual(Mapping.frameViewMode(from: .viewSubtraction), .subtraction)
        XCTAssertEqual(Mapping.frameViewMode(from: .viewValidation), .validation)
    }

    /// A client built against a newer proto can send a mode this daemon does not know.  Falling
    /// back to `.original` is the right answer — showing the untouched frame is always safe.
    func testAnUnrecognisedViewModeFallsBackToTheOriginal() {
        XCTAssertEqual(Mapping.frameViewMode(from: .UNRECOGNIZED(999)), .original)
    }

    func testEveryViewModeWireValueMapsToSomething() {
        for mode in Star_V1_FrameViewMode.allCases where mode != .UNRECOGNIZED(-1) {
            // must not trap, and must produce a usable mode
            _ = Mapping.frameViewMode(from: mode)
        }
    }

    // MARK: - homography results

    private func warp(frameIndex: Int,
                      deviation: Double,
                      state: AlignmentState,
                      homography: [Double]?) -> AlignmentWarpInfoCodable
    {
        AlignmentWarpInfoCodable(homography: homography,
                                 deviation: deviation,
                                 alignmentState: state,
                                 frameIndex: frameIndex)
    }

    /// The identity homography — a real 3x3 so that `compositeDeviation` has something to
    /// average rather than dividing by zero.
    private let identity: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]

    func testANeighborHomographyCarriesItsIndexDeviationAndState() {
        let proto = Mapping.protoNeighborHomography(
          warp(frameIndex: 7, deviation: 1.25, state: .homographySuccess,
               homography: [1, 0, 0, 0, 1, 0, 0, 0, 1]),
          includeHomography: true)

        XCTAssertEqual(proto.frameIndex, 7)
        XCTAssertEqual(proto.deviation, 1.25)
        XCTAssertEqual(proto.state, .alignHomographySuccess)
        XCTAssertEqual(proto.homography, [1, 0, 0, 0, 1, 0, 0, 0, 1])
    }

    /// The nine homography doubles are the bulk of an alignment message, and the client only
    /// needs them when it is going to warp something itself.  `includeHomography: false` is the
    /// bandwidth saving, and it has to drop only the matrix.
    func testExcludingTheHomographyKeepsEverythingElse() {
        let input = warp(frameIndex: 3, deviation: 0.5, state: .homographySuccess,
                         homography: [1, 2, 3, 4, 5, 6, 7, 8, 9])
        let withMatrix = Mapping.protoNeighborHomography(input, includeHomography: true)
        let without = Mapping.protoNeighborHomography(input, includeHomography: false)

        XCTAssertEqual(without.frameIndex, withMatrix.frameIndex)
        XCTAssertEqual(without.deviation, withMatrix.deviation)
        XCTAssertEqual(without.state, withMatrix.state)
        XCTAssertTrue(without.homography.isEmpty, "the matrix should have been left out")
        XCTAssertEqual(withMatrix.homography.count, 9)
    }

    func testAMissingHomographyIsSentAsAnEmptyList() {
        let proto = Mapping.protoNeighborHomography(
          warp(frameIndex: 1, deviation: 9, state: .noHomographyFound, homography: nil),
          includeHomography: true)
        XCTAssertTrue(proto.homography.isEmpty)
        XCTAssertEqual(proto.state, .alignNoHomographyFound)
    }

    func testHomographyResultsCarryEveryNeighbour() {
        let results = HomographyResultsCodable(
          for: 4,
          with: [
            warp(frameIndex: 3, deviation: 1, state: .homographySuccess, homography: identity),
            warp(frameIndex: 5, deviation: 2, state: .notEnoughKeypoints, homography: nil),
            warp(frameIndex: 6, deviation: 3, state: .noAlignment, homography: nil),
          ])

        let proto = Mapping.protoHomographyResults(results, includeHomography: false)

        XCTAssertEqual(proto.frameIndex, 4)
        XCTAssertEqual(proto.neighbors.count, 3)
        XCTAssertEqual(proto.neighbors.map(\.frameIndex), [3, 5, 6],
                       "neighbour order must be preserved")
        XCTAssertEqual(proto.neighbors.map(\.state),
                       [.alignHomographySuccess, .alignNotEnoughKeypoints, .alignNoAlignment])
    }

    /// `HomographyResultsCodable` sorts its neighbours by frame index on the way in, and the
    /// mapping must not reorder them again — the client pairs them up with frame numbers.
    func testNeighboursComeOutInFrameOrderWhateverOrderTheyWentIn() {
        let results = HomographyResultsCodable(
          for: 10,
          with: [
            warp(frameIndex: 12, deviation: 1, state: .homographySuccess, homography: identity),
            warp(frameIndex: 8,  deviation: 1, state: .homographySuccess, homography: identity),
            warp(frameIndex: 11, deviation: 1, state: .homographySuccess, homography: identity),
            warp(frameIndex: 9,  deviation: 1, state: .homographySuccess, homography: identity),
          ])

        let proto = Mapping.protoHomographyResults(results, includeHomography: false)
        XCTAssertEqual(proto.neighbors.map(\.frameIndex), [8, 9, 11, 12])
    }

    func testHomographyResultsWithNoNeighboursAreStillValid() {
        let results = HomographyResultsCodable(for: 0, with: [])
        let proto = Mapping.protoHomographyResults(results, includeHomography: true)
        XCTAssertEqual(proto.frameIndex, 0)
        XCTAssertTrue(proto.neighbors.isEmpty)
    }

    /// `compositeDeviation` and `alignmentLooksOk` are computed on the model, so the mapping's
    /// job is simply to carry them across unchanged — including a NaN, which is what a frame
    /// with no usable homography produces and which the client has to be ready for.
    func testTheComputedDeviationAndOkFlagAreCarriedThroughVerbatim() {
        let good = HomographyResultsCodable(
          for: 5,
          with: [warp(frameIndex: 4, deviation: 0.5, state: .homographySuccess,
                      homography: identity)])
        let goodProto = Mapping.protoHomographyResults(good, includeHomography: false)
        XCTAssertEqual(goodProto.compositeDeviation, good.compositeDeviation)
        XCTAssertEqual(goodProto.alignmentLooksOk, good.alignmentLooksOk)

        let none = HomographyResultsCodable(for: 5, with: [])
        let noneProto = Mapping.protoHomographyResults(none, includeHomography: false)
        XCTAssertTrue(none.compositeDeviation.isNaN,
                      "no usable homography averages to NaN on the model")
        XCTAssertTrue(noneProto.compositeDeviation.isNaN,
                      "and the mapping must not quietly turn that into 0")
    }

    func testHomographyResultsSurviveProtobufSerialisation() throws {
        let results = HomographyResultsCodable(
          for: 11,
          with: [warp(frameIndex: 10, deviation: 1.5,
                      state: .homographySuccess,
                      homography: [9, 8, 7, 6, 5, 4, 3, 2, 1])])

        let data = try Mapping.protoHomographyResults(results, includeHomography: true)
            .serializedData()
        let decoded = try Star_V1_HomographyResults(serializedBytes: data)

        XCTAssertEqual(decoded.frameIndex, 11)
        XCTAssertEqual(decoded.neighbors.count, 1)
        XCTAssertEqual(decoded.neighbors[0].homography, [9, 8, 7, 6, 5, 4, 3, 2, 1])
        XCTAssertEqual(decoded.neighbors[0].deviation, 1.5)
    }

    // MARK: - the plain half of Config

    func testThePathsAndFlagsCrossTheWire() {
        var config = Config()
        config.outputPath = "/some/output"
        config.tempOutputPath = "/some/star_temp_seq"
        config.horizonDetectionEnabled = false
        config.tripodHeadWasMoving = true
        config.numberOfFramesToProcessConcurrently = 6
        config.writeOutlierGroupFiles = true
        config.writeFramePreviewFiles = false

        let proto = Mapping.protoConfig(config)

        XCTAssertEqual(proto.outputPath, "/some/output")
        XCTAssertEqual(proto.tempOutputPath, "/some/star_temp_seq")
        XCTAssertFalse(proto.horizonDetectionEnabled)
        XCTAssertTrue(proto.tripodHeadWasMoving)
        XCTAssertEqual(proto.numberOfFramesToProcessConcurrently, 6)
        XCTAssertTrue(proto.writeOutlierGroupFiles)
        XCTAssertFalse(proto.writeFramePreviewFiles)
    }

    func testTheCleanMethodAndDetectionTypeAreCarriedOnTheConfig() {
        var config = Config()
        config.cleanMethod = .selective
        config.detectionType = .excessive

        let proto = Mapping.protoConfig(config)
        XCTAssertEqual(proto.cleanMethod, .cleanSelective)
        XCTAssertEqual(proto.detectionType, .detectionExcessive)
        XCTAssertEqual(Mapping.cleanMethod(from: proto), .selective)
        XCTAssertEqual(Mapping.detectionType(from: proto.detectionType), .excessive)
    }

    func testTheStarVersionIsReportedSoTheClientCanCheckIt() {
        let proto = Mapping.protoConfig(Config())
        XCTAssertFalse(proto.starVersion.isEmpty, "the client compares this against its own")
    }

    /// `ignoreLowerPixels` is only written when non-zero, so a client cannot tell an explicit 0
    /// from an unset field — but 0 *is* the default ("ignore nothing"), so nothing is lost.
    /// Pinning it because the asymmetry looks like an oversight otherwise.
    func testIgnoreLowerPixelsIsOnlySentWhenItIsAskingForSomething() {
        var none = Config()
        none.ignoreLowerPixels = 0
        XCTAssertEqual(Mapping.protoConfig(none).ignoreLowerPixels, 0)

        var some = Config()
        some.ignoreLowerPixels = 250
        XCTAssertEqual(Mapping.protoConfig(some).ignoreLowerPixels, 250)
    }

    // MARK: - video encode settings

    /// The video settings travel as their raw string values, which is what lets the client show
    /// them in a picker.  An empty string here would leave the client's dropdown blank.
    func testTheVideoSettingsTravelAsTheirRawValues() {
        let config = Config()
        let video = Mapping.protoConfig(config).video

        XCTAssertEqual(video.frameRate, config.frameRate.rawValue)
        XCTAssertEqual(video.codec, config.codec.rawValue)
        XCTAssertEqual(video.encoder, config.encoder.rawValue)
        XCTAssertEqual(video.pixelFormat, config.pixelFormat.rawValue)
        XCTAssertEqual(video.muxer, config.muxer.rawValue)

        XCTAssertFalse(video.codec.isEmpty)
        XCTAssertFalse(video.encoder.isEmpty)
        XCTAssertFalse(video.pixelFormat.isEmpty)
        XCTAssertFalse(video.muxer.isEmpty)
    }

    func testAConfigSurvivesProtobufSerialisation() throws {
        var config = Config()
        config.outputPath = "/out"
        config.tempOutputPath = "/tmp/star_temp_x"
        config.cleanMethod = .automatic(true)
        config.detectionType = .stronger
        config.numberOfFramesToProcessConcurrently = 3

        let data = try Mapping.protoConfig(config).serializedData()
        let decoded = try Star_V1_Config(serializedBytes: data)

        XCTAssertEqual(decoded.outputPath, "/out")
        XCTAssertEqual(decoded.tempOutputPath, "/tmp/star_temp_x")
        XCTAssertEqual(decoded.cleanMethod, .cleanAutomaticTrue)
        XCTAssertEqual(decoded.detectionType, .detectionStronger)
        XCTAssertEqual(decoded.numberOfFramesToProcessConcurrently, 3)
        XCTAssertEqual(Mapping.cleanMethod(from: decoded), .automatic(true))
    }

    // MARK: - FrameProcessingState

    /// Every processing state the core can be in has to have a wire value, or a frame in that
    /// state would report as something else and the client's progress display would stall or
    /// jump.  The alignment states carry a nested step, which is where the collapsing happens:
    /// the mapping has a `default` for unknown steps.
    func testTheAlignmentStepsMapToDistinctStates() {
        let steps: [AlignmentStep] = [.start, .baseKeypointDetection,
                                      .baseKeypointDetectionComplete, .aligningNeighbor(0),
                                      .loadingNeighbor(0), .complete]
        let earth = steps.map { Mapping.frameProcessingState(.earthAlignment($0)) }
        XCTAssertEqual(Set(earth).count, steps.count,
                       "two earth alignment steps share a wire value")

        let star = steps.map { Mapping.frameProcessingState(.starAlignment($0)) }
        XCTAssertEqual(Set(star).count, steps.count,
                       "two star alignment steps share a wire value")

        XCTAssertTrue(Set(earth).isDisjoint(with: Set(star)),
                      "earth and star alignment must not report the same state")
    }

    /// The neighbour index inside `aligningNeighbor`/`loadingNeighbor` is not carried on the
    /// wire — every neighbour reports the same state.  That is deliberate (the client shows one
    /// "aligning" step, not one per neighbour) but it means the wire value is lossy.
    func testTheNeighbourIndexIsNotCarriedOnTheWire() {
        XCTAssertEqual(Mapping.frameProcessingState(.starAlignment(.aligningNeighbor(0))),
                       Mapping.frameProcessingState(.starAlignment(.aligningNeighbor(7))))
        XCTAssertEqual(Mapping.frameProcessingState(.earthAlignment(.loadingNeighbor(1))),
                       Mapping.frameProcessingState(.earthAlignment(.loadingNeighbor(9))))
    }

    /// The two steps marked obsolete in `AlignmentStep` have no wire value of their own and
    /// fall through to "aligning", which keeps the client showing progress rather than nothing.
    func testTheObsoleteAlignmentStepsFallBackToAligning() {
        XCTAssertEqual(Mapping.frameProcessingState(.earthAlignment(.neighborKeypointDetection(0))),
                       .fpsEarthAlignmentAligning)
        XCTAssertEqual(Mapping.frameProcessingState(.starAlignment(.neighborKeypointMatch(0))),
                       .fpsStarAlignmentAligning)
    }

    func testTheTerminalStatesAreDistinctFromTheStartingOne() {
        XCTAssertEqual(Mapping.frameProcessingState(.unprocessed), .fpsUnprocessed)
        XCTAssertEqual(Mapping.frameProcessingState(.complete), .fpsComplete)
        XCTAssertNotEqual(Mapping.frameProcessingState(.unprocessed),
                          Mapping.frameProcessingState(.complete))
    }

    /// The eight filter passes are shown as a progress step each, so they must not collapse.
    func testTheEightFilterPassesEachHaveTheirOwnState() {
        let filters: [FrameProcessingState] = [.filter1, .filter2, .filter3, .filter4,
                                               .filter5, .filter6, .filter7, .filter8]
        let mapped = filters.map { Mapping.frameProcessingState($0) }
        XCTAssertEqual(Set(mapped).count, 8, "two filter passes share a wire value")
    }
}
