import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star



/// The How To tab's strip lists the six workflow steps in order.
final class WorkflowStripTests: XCTestCase {
    func testWorkflowStripOrder() {
        XCTAssertEqual(workflowStripSteps.map(\.rawValue),
                       ["art_step_import", "art_step_horizon", "art_step_align",
                        "art_step_merge", "art_step_review", "art_step_render"])
    }
}
