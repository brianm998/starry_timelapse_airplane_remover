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

/// Which way the runner scrolls the lazy grid to build a cell that is not in the tree.
final class GridScrollPlanTests: XCTestCase {
    func testScrollsTowardsTheTargetFromTheBuiltCells() {
        // a grid at the bottom (cells 16-18 built) is scrolled up for cell 2, not down for 24 steps first
        XCTAssertEqual(GridScrollPlan.direction(towards: "grid.cell.2", built: ["grid.cell.16", "grid.cell.17", "grid.cell.18"]), .up)
        // a grid at the top is scrolled down for cell 17
        XCTAssertEqual(GridScrollPlan.direction(towards: "grid.cell.17", built: ["grid.cell.0", "grid.cell.1"]), .down)
        // numbers compare as numbers, not as text ("grid.cell.9" sorts after "grid.cell.17")
        XCTAssertEqual(GridScrollPlan.direction(towards: "grid.cell.5", built: ["grid.cell.9", "grid.cell.17"]), .up)
        // nothing built yet: nothing to go by, so down
        XCTAssertEqual(GridScrollPlan.direction(towards: "grid.cell.2", built: []), .down)
    }

    func testIgnoresIdentifiersThatAreNotGridCells() {
        XCTAssertNil(GridScrollPlan.direction(towards: "mode.grid", built: ["grid.cell.3"]))
        XCTAssertNil(GridScrollPlan.direction(towards: "grid.cell.x", built: ["grid.cell.3"]))
        // built identifiers that are not cells (the badges beside them) do not count as the lowest cell
        XCTAssertEqual(GridScrollPlan.direction(towards: "grid.cell.2", built: ["grid.badge.0", "grid.cell.16", "grid.cellar", "grid.cell.18"]), .up)
        XCTAssertEqual(GridScrollPlan.cellNumber("grid.cell.17"), 17)
        XCTAssertNil(GridScrollPlan.cellNumber("grid.badge.17"))
    }
}
