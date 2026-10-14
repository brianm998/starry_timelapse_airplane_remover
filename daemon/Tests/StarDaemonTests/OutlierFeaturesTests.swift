import XCTest
import StarCore
import StarCppBridge
import StarDaemonMessages
@testable import stard

/// `Outlier.GetFeatures` is what the client's outlier window tabulates: every decision-tree feature of each group, by name,
/// and the classifier's score.
final class OutlierFeaturesTests: XCTestCase {

    private struct FixedClassifier: NamedOutlierGroupClassifier {
        init() {}
        var type: ClassifierType { .forest(DecisionForestParams(name: "fixed", treeCount: 0, treeNames: [])) }
        var name: String { "fixed" }
        func classification(of group: ClassifiableOutlierGroup) async -> Double { 0.75 }
        func classification(of features: [OutlierGroupFeature], and values: [Double]) async -> Double { 0.75 }
    }

    /// A solid 10 x 10 box with its top-left corner at ([x], [y]) on a 1000 x 500 frame.
    private func box(id: UInt16, x: Int = 100, y: Int = 50) -> OutlierGroup {
        let bounds = BoundingBox(min: Coord(x: x, y: y), max: Coord(x: x + 9, y: y + 9))
        var pixelSet: Set<SortablePixel> = []
        for dy in 0..<10 { for dx in 0..<10 { pixelSet.insert(SortablePixel(x: x + dx, y: y + dy, value: .sixteenBit(1000))) } }
        return OutlierGroup(id: id, size: 100, brightness: 1000, bounds: bounds, frameIndex: 0,
                            imageWidth: 1000, imageHeight: 500,
                            pixels: [UInt16](repeating: 1000, count: 100), pixelSet: pixelSet)
    }

    func testARowHasEveryFeatureByName() async {
        let group = box(id: 4)
        let rows = await OutlierHandlers.featureRows(for: [group], classifier: nil)
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertEqual(row.groupID, 4)
        XCTAssertEqual(Set(row.features.keys), Set(OutlierGroupFeature.allCases.map(\.rawValue)))
        for feature in OutlierGroupFeature.allCases {
            let expected = await group.decisionTreeValueAsync(for: feature)
            XCTAssertEqual(row.features[feature.rawValue], expected, "\(feature)")
        }
    }

    func testTheClassifierScoreIsReportedAndIsZeroWithoutOne() async {
        let withClassifier = await OutlierHandlers.featureRows(for: [box(id: 1)], classifier: FixedClassifier())
        XCTAssertEqual(withClassifier[0].classification, 0.75)
        let without = await OutlierHandlers.featureRows(for: [box(id: 1)], classifier: nil)
        XCTAssertEqual(without[0].classification, 0)
    }

    func testRowsComeBackInGroupIdOrder() async {
        let groups = [box(id: 30, x: 300), box(id: 7, x: 700), box(id: 12, x: 120), box(id: 2, x: 20)]
        let rows = await OutlierHandlers.featureRows(for: groups, classifier: nil)
        XCTAssertEqual(rows.map(\.groupID), [2, 7, 12, 30])
    }

    func testNoGroupsGivesNoRows() async {
        let rows = await OutlierHandlers.featureRows(for: [], classifier: nil)
        XCTAssertTrue(rows.isEmpty)
    }
}
