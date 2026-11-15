import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star



/// Which folder a sandboxed star has to be granted before it can write its output (`OutputLocation`).
final class OutputLocationDecisionTests: XCTestCase {

    /// "Beside the source" is a sibling of what the open panel granted: the parent has to be granted too, unless it can be written.
    func testBesideNeedsGrantOfParentWhenNotWritable() {
        XCTAssertEqual(OutputLocation.folderNeedingGrant(source: "/Users/me/Pictures/sky", outputDir: nil,
                                                         isWritable: { _ in false }),
                       "/Users/me/Pictures")
        // a video is a file: its parent is the folder, and its extracted frames go there as well
        XCTAssertEqual(OutputLocation.folderNeedingGrant(source: "/Users/me/Movies/sky.mov", outputDir: nil,
                                                         isWritable: { _ in false }),
                       "/Users/me/Movies")
    }

    /// A folder the user chose was granted by the panel that chose it.
    func testChosenFolderNeedsNoFurtherGrant() {
        XCTAssertNil(OutputLocation.folderNeedingGrant(source: "/Users/me/Pictures/sky", outputDir: "/Volumes/big/out",
                                                       isWritable: { _ in false }))
    }

    /// Unsandboxed, or a parent granted earlier: nothing to ask.
    func testWritableParentNeedsNoPrompt() {
        var asked: [String] = []
        XCTAssertNil(OutputLocation.folderNeedingGrant(source: "/Users/me/Pictures/sky", outputDir: nil,
                                                       isWritable: { asked.append($0); return true }))
        XCTAssertEqual(asked, ["/Users/me/Pictures"], "what is tested is the parent, not the sequence itself")
    }
}
