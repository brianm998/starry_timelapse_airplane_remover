import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// Layer 0 of the parity plan (§6.2.4), E1 and E2: what a click on an outlier group does is `gherkin/ui/vectors/clickRules.json`, which the
/// desktop's `ClickRules` and `OutlierDecisions` are held to as well (`ClickRulesVectorTest`).
final class ClickRuleTests: XCTestCase {
    private func doc() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("gherkin/ui/vectors/clickRules.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func reason(_ name: String) throws -> RemoveReason? {
        switch name {
        case "undecided": return nil
        case "classifierRemove": return .fromClassifier(1.0)
        case "classifierKeep": return .fromClassifier(-1.0)
        case "userRemove": return .userSelected(true)
        case "userKeep": return .userSelected(false)
        default: throw XCTSkip("unknown decision \(name)")
        }
    }

    func testAClickLeavesTheDecisionTheVectorSays() throws {
        let cases = try XCTUnwrap(try doc()["toggle"] as? [[String: String]])
        XCTAssertEqual(cases.count, 7 * 5, "seven tools, five starting decisions")
        for c in cases {
            let after = try XCTUnwrap(try reason(try XCTUnwrap(c["after"])))
            let tool = try XCTUnwrap(ToolType(rawValue: try XCTUnwrap(c["tool"])))
            XCTAssertEqual(OutlierGroupView.decisionAfterClick(try reason(try XCTUnwrap(c["decision"])), tool: tool), after, "\(c)")
        }
    }

    func testAClickOnAGroupDoesWhatTheVectorSays() throws {
        let cases = try XCTUnwrap(try doc()["groupClick"] as? [[String: Any]])
        // `allCases` leaves out `.none`, which the vector has with the others: every tool, the switch on and off, a decided and an undecided group
        XCTAssertEqual(Set(cases.compactMap { $0["tool"] as? String }), Set(ToolType.allCases.map(\.rawValue) + [ToolType.none.rawValue]))
        XCTAssertEqual(cases.count, (ToolType.allCases.count + 1) * 4)
        for c in cases {
            let tool = try XCTUnwrap(ToolType(rawValue: try XCTUnwrap(c["tool"] as? String)))
            let expected: OutlierGroupView.GroupClick = (c["expected"] as? String) == "multiChoiceSheet" ? .openMultiChoice : .applyTool
            XCTAssertEqual(OutlierGroupView.groupClick(tool: tool,
                                                      multiChoice: try XCTUnwrap(c["multiChoice"] as? Bool),
                                                      decided: try XCTUnwrap(c["decided"] as? Bool)),
                           expected, "\(c)")
        }
    }

    /// The probe (`outlier.first`) is a group a click can hit. On the CI VM's default window the frame is 180 pt wide for a 6000 px frame
    /// (0.03 pt a pixel), and the old choice, the smallest group, was 0.9 x 0.3 pt: the element existed and was never hittable.
    func testTheProbeGroupIsOneAClickCanHit() {
        typealias C = OutlierGroupView.ProbeCandidate
        func box(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> BoundingBox {
            BoundingBox(between: CGPoint(x: x, y: y), and: CGPoint(x: x + w - 1, y: y + h - 1))
        }
        let pointsPerPixel: CGFloat = 0.03
        // ids: big 1, tiny 2, thin 3, few 4, middle 5, cover 6
        let big = C(id: 1, bounds: box(1000, 1000, 400, 300), size: 5000)        // 12 x 9 pt
        let tiny = C(id: 2, bounds: box(3000, 500, 30, 10), size: 200)           // 0.9 x 0.3 pt, the old choice
        let thin = C(id: 3, bounds: box(2000, 2000, 600, 100), size: 900)        // 18 x 3 pt: too thin
        let few = C(id: 4, bounds: box(4000, 4000, 300, 300), size: 40)           // not over 40 pixels

        // drawn biggest first, so the last is on top; the old rule took the last one with more than 40 pixels
        let drawn = [big, thin, tiny, few]
        XCTAssertEqual(drawn.last(where: { $0.size > 40 })?.id, 2, "the old rule picks the sub-point group")
        XCTAssertEqual(OutlierGroupView.probeGroupId(groups: drawn, pointsPerPixel: pointsPerPixel), 1)

        // a group drawn later on top of the centre of `big` takes the click: the next smallest is chosen
        let middle = C(id: 5, bounds: box(5000, 1000, 250, 250), size: 3000)   // 7.5 x 7.5 pt
        let cover = C(id: 6, bounds: box(1100, 1050, 200, 200), size: 2000)     // 6 x 6 pt, on `big`'s centre
        XCTAssertEqual(OutlierGroupView.probeGroupId(groups: [big, middle, cover, tiny], pointsPerPixel: pointsPerPixel), 6,
                       "the smallest group a click can hit is `cover`; `big` is under it")
        XCTAssertEqual(OutlierGroupView.probeGroupId(groups: [big, cover, middle, tiny], pointsPerPixel: pointsPerPixel), 6)
        XCTAssertEqual(OutlierGroupView.probeGroupId(groups: [cover, big, middle, tiny], pointsPerPixel: pointsPerPixel), 5,
                       "`big` is drawn over `cover`'s centre, and it is not the smaller one")

        // zoomed in, the small one is big enough
        XCTAssertEqual(OutlierGroupView.probeGroupId(groups: drawn, pointsPerPixel: 1), 2)

        // nothing is big enough: the smallest group over 40 pixels, as before; nothing over 40 pixels: none
        XCTAssertEqual(OutlierGroupView.probeGroupId(groups: [thin, tiny, few], pointsPerPixel: pointsPerPixel), 2)
        XCTAssertNil(OutlierGroupView.probeGroupId(groups: [few], pointsPerPixel: pointsPerPixel))
        XCTAssertNil(OutlierGroupView.probeGroupId(groups: [], pointsPerPixel: pointsPerPixel))
    }
}
