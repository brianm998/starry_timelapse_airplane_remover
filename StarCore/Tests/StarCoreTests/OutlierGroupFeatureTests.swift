import XCTest
import StarCppBridge
@testable import StarCore

/// `OutlierGroupFeature` is the decision tree's input vocabulary.  Every feature is a hand-written
/// case appearing in five separate switches in one file, plus a `sortOrder` that doubles as the
/// type's *identity* — `==` compares `sortOrder`, not the case.  The file's own comment warns that
/// adding a case means regenerating every stored outlier value file, so the shape of this enum is
/// a compatibility surface, not an implementation detail.
///
/// The failures these guard against are all silent:
///   - two cases sharing a `sortOrder` become `==` while hashing differently, which breaks every
///     `Set` and `Dictionary` keyed on a feature,
///   - a case missing from `isAsync` gets routed to `decisionTreeValueSync`, which `fatalError`s,
///   - the `.isolated` exclusion list drifting changes which features that tree is trained on.
final class OutlierGroupFeatureTests: XCTestCase {

    /// `decisionTreeValueSync` force-unwraps these globals, so anything touching a feature value
    /// has to set them first.  They are process-wide, so they are restored afterwards.
    private var savedWidth: Double?
    private var savedHeight: Double?

    override func setUp() {
        savedWidth = IMAGE_WIDTH
        savedHeight = IMAGE_HEIGHT
        IMAGE_WIDTH = 1000
        IMAGE_HEIGHT = 500
    }

    override func tearDown() {
        IMAGE_WIDTH = savedWidth
        IMAGE_HEIGHT = savedHeight
    }

    // MARK: - sortOrder is the identity

    /// The one that matters most.  `==` is `lhs.sortOrder == rhs.sortOrder`, so a duplicated
    /// number silently makes two different features the same feature.
    func testEveryFeatureHasItsOwnSortOrder() {
        var byOrder: [Int: [OutlierGroupFeature]] = [:]
        for feature in OutlierGroupFeature.allCases {
            byOrder[feature.sortOrder, default: []].append(feature)
        }
        for (order, sharing) in byOrder where sharing.count > 1 {
            XCTFail("sortOrder \(order) is claimed by \(sharing.map(\.rawValue).sorted()) — "
                    + "those features compare equal to each other")
        }
        XCTAssertEqual(byOrder.count, OutlierGroupFeature.allCases.count)
    }

    /// Contiguous from zero.  A gap would not break anything by itself, but it is the signature of
    /// a case having been removed without renumbering, which is worth noticing.
    func testTheSortOrdersAreContiguousFromZero() {
        let orders = OutlierGroupFeature.allCases.map(\.sortOrder).sorted()
        XCTAssertEqual(orders, Array(0..<OutlierGroupFeature.allCases.count),
                       "sortOrder should cover 0..<\(OutlierGroupFeature.allCases.count) exactly")
    }

    /// `==` is defined on `sortOrder` while `Hashable` is synthesised from the raw value, so the
    /// two only agree as long as sortOrder is unique.  This checks the property that actually
    /// matters: equal features hash together, and a Set holds every distinct feature.
    func testEqualityAndHashingAgree() {
        for feature in OutlierGroupFeature.allCases {
            XCTAssertEqual(feature, feature)
            XCTAssertEqual(feature.hashValue, feature.hashValue)
        }
        XCTAssertEqual(Set(OutlierGroupFeature.allCases).count,
                       OutlierGroupFeature.allCases.count,
                       "two features collapsed in a Set")
    }

    func testDifferentFeaturesAreNotEqual() {
        let all = OutlierGroupFeature.allCases
        for (i, a) in all.enumerated() {
            for b in all[(i + 1)...] {
                XCTAssertNotEqual(a, b, "\(a.rawValue) and \(b.rawValue) compare equal")
            }
        }
    }

    /// `<` is also on sortOrder, so sorting is a total order and agrees with equality.
    func testSortingIsATotalOrderAgreeingWithSortOrder() {
        let sorted = OutlierGroupFeature.allCases.sorted()
        XCTAssertEqual(sorted.map(\.sortOrder), sorted.map(\.sortOrder).sorted())

        for (i, a) in sorted.enumerated() {
            for b in sorted[(i + 1)...] {
                XCTAssertTrue(a < b, "\(a.rawValue) should sort before \(b.rawValue)")
                XCTAssertFalse(b < a)
            }
        }
    }

    func testSortingIsStableAcrossRuns() {
        let once = OutlierGroupFeature.allCases.sorted().map(\.rawValue)
        for _ in 0..<10 {
            XCTAssertEqual(OutlierGroupFeature.allCases.sorted().map(\.rawValue), once)
        }
    }

    // MARK: - the case list is a compatibility surface

    /// Stored outlier value files are written in feature order, so the count and the order are
    /// part of the on-disk format.  Adding a feature has to be a deliberate edit here too.
    func testTheFeatureSetIsWhatTheStoredFilesExpect() {
        XCTAssertEqual(OutlierGroupFeature.allCases.count, 35,
                       "the number of features changed — every stored outlier value file needs "
                       + "regenerating, and this count needs updating with that in mind")
    }

    func testEveryFeatureHasADistinctRawValue() {
        let raws = OutlierGroupFeature.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
        for raw in raws { XCTAssertFalse(raw.isEmpty) }
    }

    /// The raw value is the on-disk name, so decoding an old file has to still work.
    func testEveryFeatureRoundTripsThroughItsRawValue() {
        for feature in OutlierGroupFeature.allCases {
            XCTAssertEqual(OutlierGroupFeature(rawValue: feature.rawValue), feature)
        }
    }

    func testAnUnknownRawValueDoesNotDecode() {
        XCTAssertNil(OutlierGroupFeature(rawValue: "notAFeature"))
        XCTAssertNil(OutlierGroupFeature(rawValue: ""))
        XCTAssertNil(OutlierGroupFeature(rawValue: "Size"), "decoding is case sensitive")
    }

    func testEveryFeatureSurvivesAJsonRoundTrip() throws {
        for feature in OutlierGroupFeature.allCases {
            let data = try JSONEncoder().encode(feature)
            XCTAssertEqual(try JSONDecoder().decode(OutlierGroupFeature.self, from: data), feature)
        }
    }

    func testTheCasesStringListsEveryFeatureOnItsOwnLine() {
        let lines = OutlierGroupFeature.allCasesString
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(Set(lines), Set(OutlierGroupFeature.allCases.map(\.rawValue)))
        XCTAssertEqual(lines.count, OutlierGroupFeature.allCases.count)
    }

    // MARK: - tree types

    func testBothTreeTypesAreListedAndRoundTrip() {
        XCTAssertEqual(TreeType.allCases.count, 2)
        for type in TreeType.allCases {
            XCTAssertEqual(TreeType(rawValue: type.rawValue), type)
        }
        let lines = TreeType.allCasesString
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(Set(lines), Set(TreeType.allCases.map(\.rawValue)))
    }

    /// An `.all` tree uses every feature — that is what makes it the superset.
    func testTheAllTreeUsesEveryFeature() {
        for feature in OutlierGroupFeature.allCases {
            XCTAssertTrue(feature.isUsed(for: .all), "\(feature.rawValue) is excluded from .all")
        }
    }

    /// The `.isolated` tree exists to classify a group without looking at its neighbours, so it
    /// must exclude exactly the features that need another frame or another group.  Pinned as a
    /// list because a feature quietly joining or leaving it changes what that tree can be trained
    /// on, and nothing else would report it.
    func testTheIsolatedTreeExcludesExactlyTheNeighbourDependentFeatures() {
        let expectedExclusions: Set<OutlierGroupFeature> = [
          .numberOfNearbyOutliersInSameFrame,
          .nearbyDirectOverlapScore,
          .boundingBoxOverlapScore,
          .borderBrightness,
          .neighborLineThetaScore,
          .neighborLineRhoScore,
          .neighborLineSizeScore,
          .neighborLineBrightnessScore,
          .neighborLineDistanceScore,
        ]
        let actualExclusions = Set(OutlierGroupFeature.allCases.filter { !$0.isUsed(for: .isolated) })

        XCTAssertEqual(actualExclusions, expectedExclusions,
                       "newly excluded: \(actualExclusions.subtracting(expectedExclusions).map(\.rawValue).sorted()); "
                       + "no longer excluded: \(expectedExclusions.subtracting(actualExclusions).map(\.rawValue).sorted())")
    }

    func testTheIsolatedTreeStillUsesMostFeatures() {
        let used = OutlierGroupFeature.allCases.filter { $0.isUsed(for: .isolated) }
        XCTAssertEqual(used.count, OutlierGroupFeature.allCases.count - 9)
        XCTAssertTrue(used.contains(.size))
        XCTAssertTrue(used.contains(.bunchCount), "bunching is a property of the group alone")
        XCTAssertTrue(used.contains(.averageLineVariance))
    }

    // MARK: - isAsync has to match which accessor works

    /// `decisionTreeValueSync` `fatalError`s for every feature that needs async work, so `isAsync`
    /// and that switch have to agree exactly — a mismatch is a crash at classification time, not a
    /// wrong number.  Checked by reading the source, since the mismatching half cannot be called
    /// without taking the test process down with it.
    private func syncFatalErrorCases() throws -> Set<String> {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // StarCoreTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // StarCore
            .appendingPathComponent("Sources/StarCore/OutlierGroupFeature.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        // isolate `public func decisionTreeValueSync(of group: OutlierGroup) -> Double { ... }`
        guard let start = text.range(of: "public func decisionTreeValueSync") else {
            XCTFail("could not find decisionTreeValueSync in the source")
            return []
        }
        let body = text[start.lowerBound...]

        // walk `case .name:` markers and note which of them reach a fatalError before the next case
        var fatal: Set<String> = []
        let caseRegex = try NSRegularExpression(pattern: #"case \.(\w+):"#)
        let ns = String(body) as NSString
        let matches = caseRegex.matches(in: String(body),
                                        range: NSRange(location: 0, length: ns.length))
        for (i, match) in matches.enumerated() {
            let name = ns.substring(with: match.range(at: 1))
            let sliceEnd = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let slice = ns.substring(with: NSRange(location: match.range.location,
                                                  length: sliceEnd - match.range.location))
            if slice.contains("fatalError") { fatal.insert(name) }
        }
        return fatal
    }

    func testTheSourceScanFindsTheSyncSwitch() throws {
        let fatal = try syncFatalErrorCases()
        XCTAssertGreaterThan(fatal.count, 10,
                             "only found \(fatal.count) fatalError cases; the parse has probably "
                             + "stopped matching the source")
    }

    /// The pairing: a feature `fatalError`s in the sync accessor if and only if it is async.
    func testEveryAsyncFeatureIsTheOneThatRefusesTheSyncAccessor() throws {
        let fatal = try syncFatalErrorCases()
        for feature in OutlierGroupFeature.allCases {
            let refusesSync = fatal.contains(feature.rawValue)
            XCTAssertEqual(feature.isAsync, refusesSync,
                           "\(feature.rawValue): isAsync is \(feature.isAsync) but "
                           + "decisionTreeValueSync \(refusesSync ? "does" : "does not") fatalError "
                           + "— one of the two is wrong, and the mismatch is a crash")
        }
    }

    /// Both kinds have to exist, or the test above would pass vacuously.
    func testThereAreBothSyncAndAsyncFeatures() {
        let async = OutlierGroupFeature.allCases.filter(\.isAsync)
        let sync = OutlierGroupFeature.allCases.filter { !$0.isAsync }
        XCTAssertGreaterThan(async.count, 5)
        XCTAssertGreaterThan(sync.count, 5)
        XCTAssertEqual(async.count + sync.count, OutlierGroupFeature.allCases.count)
    }

    /// The geometric features are cheap and must stay synchronous — they are computed for every
    /// group in a frame.
    func testTheGeometricFeaturesAreSynchronous() {
        for feature in [OutlierGroupFeature.size, .width, .height, .centerX, .centerY,
                        .minX, .minY, .maxX, .maxY, .hypotenuse, .aspectRatio, .fillAmount] {
            XCTAssertFalse(feature.isAsync, "\(feature.rawValue) should not need async work")
        }
    }

    // MARK: - the synchronous feature values

    /// Builds a group whose `pixels` and `pixelSet` agree with each other and with `bounds`.
    ///
    /// This matters: `pixels` is a bounds-relative row-major `[UInt16]` of brightnesses, and
    /// `surfaceAreaRatio` and `pixelBorderAmount` index straight into it from the bounds. Handing
    /// the initializer an empty array alongside a 10x10 box traps with "Index out of range" rather
    /// than reporting anything — the two arguments are a single invariant that nothing checks.
    private func group(brightness: UInt,
                       bounds: BoundingBox,
                       filled: (Int, Int) -> Bool) -> OutlierGroup
    {
        var pixelSet: Set<SortablePixel> = []
        var pixels = [UInt16](repeating: 0, count: bounds.width * bounds.height)
        var size: UInt = 0

        for localY in 0..<bounds.height {
            for localX in 0..<bounds.width {
                let x = bounds.min.x + localX, y = bounds.min.y + localY
                guard filled(x, y) else { continue }
                pixels[localY * bounds.width + localX] = UInt16(brightness)
                pixelSet.insert(SortablePixel(x: x, y: y, value: .sixteenBit(UInt16(brightness))))
                size += 1
            }
        }
        return OutlierGroup(id: 1, size: size, brightness: brightness, bounds: bounds,
                            frameIndex: 0, pixels: pixels, pixelSet: pixelSet)
    }

    private func solidGroup(bounds: BoundingBox, brightness: UInt = 1000) -> OutlierGroup {
        group(brightness: brightness, bounds: bounds) { _, _ in true }
    }

    /// A solid 10x10 box at [100, 50] on a 1000x500 frame, so every normalised value is a round
    /// number.
    private func squareGroup() -> OutlierGroup {
        solidGroup(bounds: BoundingBox(min: Coord(x: 100, y: 50), max: Coord(x: 109, y: 59)))
    }

    /// Every feature is normalised against the frame size, which is what lets one trained tree
    /// work across resolutions.  These pin the divisor each one uses, since getting width and
    /// height the wrong way round would still produce plausible-looking numbers.
    func testTheGeometricFeaturesAreNormalisedAgainstTheFrame() {
        let outlier = squareGroup()

        XCTAssertEqual(OutlierGroupFeature.width.decisionTreeValueSync(of: outlier),
                       10.0 / 1000, accuracy: 1e-12, "width is divided by the frame width")
        XCTAssertEqual(OutlierGroupFeature.height.decisionTreeValueSync(of: outlier),
                       10.0 / 500, accuracy: 1e-12, "height is divided by the frame height")
        XCTAssertEqual(OutlierGroupFeature.minX.decisionTreeValueSync(of: outlier),
                       100.0 / 1000, accuracy: 1e-12)
        XCTAssertEqual(OutlierGroupFeature.maxX.decisionTreeValueSync(of: outlier),
                       109.0 / 1000, accuracy: 1e-12)
        XCTAssertEqual(OutlierGroupFeature.minY.decisionTreeValueSync(of: outlier),
                       50.0 / 500, accuracy: 1e-12)
        XCTAssertEqual(OutlierGroupFeature.maxY.decisionTreeValueSync(of: outlier),
                       59.0 / 500, accuracy: 1e-12)
        XCTAssertEqual(OutlierGroupFeature.size.decisionTreeValueSync(of: outlier),
                       100.0 / (1000 * 500), accuracy: 1e-15, "size is divided by the frame area")
    }

    func testAspectRatioAndFillAmountAreScaleFree() {
        let outlier = squareGroup()
        XCTAssertEqual(OutlierGroupFeature.aspectRatio.decisionTreeValueSync(of: outlier),
                       1, accuracy: 1e-12, "a square group has aspect ratio 1")
        XCTAssertEqual(OutlierGroupFeature.fillAmount.decisionTreeValueSync(of: outlier),
                       1, accuracy: 1e-12, "a solid 10x10 group fills its box")
    }

    func testAWideGroupHasAnAspectRatioAboveOne() {
        let wide = solidGroup(bounds: BoundingBox(min: Coord(x: 0, y: 0), max: Coord(x: 19, y: 1)))
        XCTAssertGreaterThan(OutlierGroupFeature.aspectRatio.decisionTreeValueSync(of: wide), 1)

        let tall = solidGroup(bounds: BoundingBox(min: Coord(x: 0, y: 0), max: Coord(x: 1, y: 19)))
        XCTAssertLessThan(OutlierGroupFeature.aspectRatio.decisionTreeValueSync(of: tall), 1)
    }

    /// A sparse group fills less of its box than a solid one — this is the feature that separates
    /// a trail from a blob of noise spread over the same area.
    func testASparseGroupFillsLessOfItsBox() {
        let diagonal = group(brightness: 1000,
                             bounds: BoundingBox(min: Coord(x: 0, y: 0), max: Coord(x: 9, y: 9))) {
            x, y in x == y
        }

        let fill = OutlierGroupFeature.fillAmount.decisionTreeValueSync(of: diagonal)
        XCTAssertEqual(fill, 10.0 / 100, accuracy: 1e-12)
        XCTAssertLessThan(fill, OutlierGroupFeature.fillAmount.decisionTreeValueSync(of: squareGroup()))
    }

    func testAverageBrightnessIsCarriedThroughUnscaled() {
        let outlier = solidGroup(bounds: BoundingBox(min: Coord(x: 0, y: 0), max: Coord(x: 3, y: 3)),
                                 brightness: 4242)
        XCTAssertEqual(OutlierGroupFeature.averagebrightness.decisionTreeValueSync(of: outlier), 4242)
    }

    /// Every synchronous feature has to produce a real number for an ordinary group — a NaN or an
    /// infinity would poison whichever branch of the tree consumed it.
    func testEverySynchronousFeatureIsFiniteForAnOrdinaryGroup() {
        let outlier = squareGroup()
        for feature in OutlierGroupFeature.allCases where !feature.isAsync {
            let value = feature.decisionTreeValueSync(of: outlier)
            XCTAssertFalse(value.isNaN, "\(feature.rawValue) produced NaN")
            XCTAssertTrue(value.isFinite, "\(feature.rawValue) produced \(value)")
        }
    }

    /// The same, for a single-pixel group — the degenerate case the blobber produces most of.
    func testEverySynchronousFeatureIsFiniteForASinglePixelGroup() {
        let single = solidGroup(bounds: BoundingBox(min: Coord(x: 7, y: 7), max: Coord(x: 7, y: 7)),
                                brightness: 500)
        for feature in OutlierGroupFeature.allCases where !feature.isAsync {
            let value = feature.decisionTreeValueSync(of: single)
            XCTAssertFalse(value.isNaN, "\(feature.rawValue) produced NaN on a single pixel")
            XCTAssertTrue(value.isFinite, "\(feature.rawValue) produced \(value) on a single pixel")
        }
    }

    /// Normalising against the frame is only worth anything if the same group at two resolutions
    /// gives the same numbers.  This is the property a tree trained at one size relies on.
    func testTheNormalisedValuesAreResolutionIndependent() {
        let smallBounds = BoundingBox(min: Coord(x: 100, y: 50), max: Coord(x: 109, y: 59))
        let bigBounds = BoundingBox(min: Coord(x: 200, y: 100), max: Coord(x: 219, y: 119))

        IMAGE_WIDTH = 1000; IMAGE_HEIGHT = 500
        let small = solidGroup(bounds: smallBounds)
        let smallValues = OutlierGroupFeature.allCases.filter { !$0.isAsync }
            .map { ($0, $0.decisionTreeValueSync(of: small)) }

        IMAGE_WIDTH = 2000; IMAGE_HEIGHT = 1000
        let big = solidGroup(bounds: bigBounds)

        for (feature, smallValue) in smallValues {
            // size scales with area, the rest with a single axis; both are covered by the
            // doubled geometry above
            let bigValue = feature.decisionTreeValueSync(of: big)
            switch feature {
            case .averagebrightness, .medianBrightness, .maxBrightness,
                 .surfaceAreaRatio, .pixelBorderAmount:
                continue        // not normalised against the frame
            case .hypotenuse:
                continue        // divided by width*height while scaling with a single axis
            case .maxX, .maxY:
                // the bounds are inclusive, so max == min + width - 1 and a box cannot be
                // scaled exactly: doubling 100...109 gives 200...219, whose max is 219 rather
                // than 218.  The half pixel is the fixture's, not the feature's.
                continue
            default:
                XCTAssertEqual(bigValue, smallValue, accuracy: 1e-9,
                               "\(feature.rawValue) is not resolution independent: "
                               + "\(smallValue) at 1000x500 vs \(bigValue) at 2000x1000")
            }
        }
    }

    /// `hypotenuse` divides a length by the frame *area*, so unlike its neighbours it is not
    /// resolution independent — doubling both axes quarters it rather than leaving it alone.
    /// Pinned because it reads like the others and a tree trained at one resolution cannot
    /// transfer on this feature.
    func testHypotenuseIsDividedByAreaAndSoDoesNotTransferAcrossResolutions() {
        let bounds = BoundingBox(min: Coord(x: 0, y: 0), max: Coord(x: 9, y: 9))
        let outlier = solidGroup(bounds: bounds)

        IMAGE_WIDTH = 1000; IMAGE_HEIGHT = 500
        let atSmall = OutlierGroupFeature.hypotenuse.decisionTreeValueSync(of: outlier)
        IMAGE_WIDTH = 2000; IMAGE_HEIGHT = 1000
        let atBig = OutlierGroupFeature.hypotenuse.decisionTreeValueSync(of: outlier)

        XCTAssertEqual(atSmall / atBig, 4, accuracy: 1e-9,
                       "quadrupling the frame area should quarter this feature")
    }
}
