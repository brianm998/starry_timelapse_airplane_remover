import XCTest

/// The UI-test scratch must never be inside an app container: the unsandboxed app under test is handed paths under it, and touching another
/// app's container raises the macOS "access data from other apps" prompt.
final class ScratchLocationTests: XCTestCase {
    func testScratchRootIsNotInsideAnAppContainer() throws {
        let root = try ScratchLocation.root(environment: [:], uid: 501)
        XCTAssertEqual(root.path, "/private/tmp/star-gherkin-501")
        XCTAssertFalse(ScratchLocation.isInsideAppContainer(root))
        XCTAssertFalse(root.path.contains("/Library/Containers/"))

        let run = try ScratchLocation.make(environment: [:], uid: 501)
        XCTAssertEqual(run.deletingLastPathComponent().path, root.path)
        XCTAssertFalse(ScratchLocation.isInsideAppContainer(run))

        // what the sandboxed runner's own temporary directory looks like is exactly what must be avoided
        let container = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Containers/com.star-guiUITests.xctrunner/Data/tmp")
        XCTAssertTrue(ScratchLocation.isInsideAppContainer(container))
        XCTAssertTrue(ScratchLocation.isInsideAppContainer(URL(fileURLWithPath: "/Users/x/Library/Group Containers/group.y/z")))
        // and the real (possibly container) temporary directory is never what the scratch is built from
        XCTAssertFalse(run.path.hasPrefix(NSTemporaryDirectory()) && NSTemporaryDirectory().contains("/Library/Containers/"))
    }

    func testScratchEnvironmentOverrideWinsAndContainerPathIsRejected() throws {
        let key = ScratchLocation.environmentKey
        XCTAssertEqual(try ScratchLocation.root(environment: [key: "/private/tmp/custom-scratch"], uid: 501).path, "/private/tmp/custom-scratch")
        // an empty override is the same as none
        XCTAssertEqual(try ScratchLocation.root(environment: [key: ""], uid: 7).path, "/private/tmp/star-gherkin-7")

        let inContainer = NSHomeDirectory() + "/Library/Containers/com.star-guiUITests.xctrunner/Data/tmp/x"
        XCTAssertThrowsError(try ScratchLocation.root(environment: [key: inContainer], uid: 501))
        XCTAssertThrowsError(try ScratchLocation.make(environment: [key: "/Users/x/Library/Group Containers/g/s"], uid: 501))
    }
}
