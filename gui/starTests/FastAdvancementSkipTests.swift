import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// Q10 of the parity plan (owner decision D14): fast advancement loads a frame's outliers when their counts are not known and goes on
/// scanning, instead of stopping on the first such frame.
final class FastAdvancementSkipTests: XCTestCase {
    private func skips(_ type: FastAdvancementType, _ p: Int?, _ n: Int?, _ u: Int?, views: Int? = nil) -> Bool? {
        ImageSequenceViewModel.skipsFrame(type, positive: p, negative: n, undecided: u, viewCount: views)
    }

    func testNormalNeverSkips() {
        XCTAssertEqual(skips(.normal, 0, 0, 0), false)
        XCTAssertEqual(skips(.normal, nil, nil, nil), false)
    }

    func testUnknownCountsAreNotNothing() {
        for type in [FastAdvancementType.skipEmpties, .toNextPositive, .toNextNegative, .toNextUnknown] {
            XCTAssertNil(skips(type, nil, nil, nil), "\(type)")
        }
    }

    func testEachTypeLooksAtItsOwnCount() {
        XCTAssertEqual(skips(.toNextPositive, 0, 3, 3), true)
        XCTAssertEqual(skips(.toNextPositive, 1, 0, 0), false)
        XCTAssertEqual(skips(.toNextNegative, 3, 0, 3), true)
        XCTAssertEqual(skips(.toNextUnknown, 3, 3, 0), true)
        XCTAssertEqual(skips(.toNextUnknown, 0, 0, 2), false)
    }

    func testSkipEmptiesAddsThemUpAndFallsBackToTheViews() {
        XCTAssertEqual(skips(.skipEmpties, 0, 0, 0), true)
        XCTAssertEqual(skips(.skipEmpties, 0, 1, 0), false)
        XCTAssertEqual(skips(.skipEmpties, nil, nil, nil, views: 0), true)
        XCTAssertEqual(skips(.skipEmpties, nil, nil, nil, views: 4), false)
    }
}
