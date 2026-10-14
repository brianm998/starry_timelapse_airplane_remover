import XCTest
import Foundation
import StarCppBridge
@testable import StarCore

/// Stands in for the decision tree the clients install: calls every group a keeper.
private struct StubClassifier: NamedOutlierGroupClassifier {
    init() {}
    var type: ClassifierType { .tree(DecisionTreeParams(name: "stub", inputSequences: [], positiveTrainingSize: 0, negativeTrainingSize: 0, decisionTypes: [], decisionSplitTypes: [], maxDepth: nil)) }
    var name: String { "stub" }
    func classification(of group: ClassifiableOutlierGroup) async -> Double { -1 }
    func classification(of features: [OutlierGroupFeature], and values: [Double]) async -> Double { -1 }
}

/// Issue #7: edits made with the selective tools did not show in the rendered output.
///
/// `MergeOp` runs `applyDecisionTreeToAllOutliers()` on every selective frame that is not yet
/// `.complete`, and that call overwrites by default.  A frame the user has just edited is
/// `.userModified`, not `.complete`, so a Process all before the edit has been rendered reaches
/// that call with the user's decisions already on the groups.
final class UserDecisionSurvivesMergeTests: FrameHarnessTestCase {

    private func group(id: UInt16, x: Int, y: Int) -> OutlierGroup {
        let size = 4
        let bounds = BoundingBox(min: Coord(x: x, y: y), max: Coord(x: x + size - 1, y: y + size - 1))
        var pixelSet: Set<SortablePixel> = []
        var pixels = [UInt16](repeating: 0, count: size * size)
        for ly in 0..<size { for lx in 0..<size {
            pixels[ly * size + lx] = 1000
            pixelSet.insert(SortablePixel(x: x + lx, y: y + ly, value: .sixteenBit(1000)))
        } }
        return OutlierGroup(id: id, size: UInt(size * size), brightness: 1000, bounds: bounds,
                            frameIndex: 0, imageWidth: 1000, imageHeight: 500,
                            pixels: pixels, pixelSet: pixelSet)
    }

    /// What `MergeOp` does for a selective frame: the call with its default `overwrite`.
    func testMergeTimeClassificationKeepsTheUsersDecisions() async throws {
        await currentClassifier.set(for: .all) { StubClassifier() }
        let h = try await FrameHarness.make(frameCount: 1, named: "userdecision")
        harness = h
        let frame = h.frames[0]
        let outlier = await frame.outlierProcessor
        await outlier.initializeEmptyOutlierGroups()
        let groupsOptional = await outlier.getOutlierGroups()
        let groups = try XCTUnwrap(groupsOptional)

        let keep = group(id: 1, x: 10, y: 10)
        let remove = group(id: 2, x: 100, y: 100)
        await groups.add(keep)
        await groups.add(remove)
        let undecided = group(id: 3, x: 200, y: 200)
        await groups.add(undecided)
        _ = await keep.shouldRemove(.userSelected(false))
        _ = await remove.shouldRemove(.userSelected(true))

        await frame.applyDecisionTreeToAllOutliers(keepingUserDecisions: true)   // MergeOp's call

        // control: the classifier must really be running, or the asserts below prove nothing
        let u = await undecided.shouldRemove()
        XCTAssertNotNil(u, "classifier did not run; this test would be vacuous")

        let k = await keep.shouldRemove()
        let r = await remove.shouldRemove()
        XCTAssertEqual(k, .userSelected(false), "the user's Keep was replaced by \(String(describing: k))")
        XCTAssertEqual(r, .userSelected(true), "the user's Remove was replaced by \(String(describing: r))")
    }
}
