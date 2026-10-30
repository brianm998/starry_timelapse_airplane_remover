import XCTest
import Foundation
@testable import StarCore

/// `FrameAirplaneRemover.set(cleanMethod:)` links the image the new method made as the frame's
/// `.final`.
///
/// It used to return before doing so unless `observer?.cleanMethod == cleanMethod`.  The gui sets
/// its `FrameObserver`'s method first, so for the gui that was always true; the daemon behind the
/// desktop client gives its frames no observer, the comparison was `nil == method`, and a change
/// of a frame's method there recorded the override and left the old final in place (parity plan L10).
final class FrameCleanMethodChangeTests: FrameHarnessTestCase {

    private func inode(_ path: String) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? UInt64)
    }

    private func finalPath(_ h: FrameHarness) throws -> String {
        try XCTUnwrap(h.imageAccessor.nameForImage(frameIndex: 0, ofType: .final, atSize: .original))
    }

    /// A frame with one image per method, so which of them `.final` is a hard link to says what was linked.
    private func frameWithAnImagePerMethod(named name: String) async throws
      -> (FrameHarness, auto: String, autoSelective: String, selective: String)
    {
        let h = try await FrameHarness.make(frameCount: 1, named: name)
        harness = h
        let image = FrameHarness.syntheticFrame(width: 16, height: 12, horizonRow: 6)
        let auto = try h.plantImage(image, ofType: .autoProcessed)
        let autoSelective = try h.plantImage(image, ofType: .autoSelectiveProcessed)
        let selective = try h.plantImage(image, ofType: .selectiveProcessed)
        return (h, auto, autoSelective, selective)
    }

    func testAFrameWithNoObserverHasTheNewMethodsImageLinked() async throws {
        let (h, auto, autoSelective, selective) = try await frameWithAnImagePerMethod(named: "method-no-observer")
        let observer = await h.frame.getObserver()
        XCTAssertNil(observer, "the daemon's frames have no observer; that is the case under test")

        await h.frame.set(cleanMethod: .automatic(false))
        XCTAssertEqual(try inode(try finalPath(h)), try inode(auto))

        await h.frame.set(cleanMethod: .selective)
        XCTAssertEqual(try inode(try finalPath(h)), try inode(selective))

        await h.frame.set(cleanMethod: .automatic(true))
        XCTAssertEqual(try inode(try finalPath(h)), try inode(autoSelective))
    }

    /// The gui's frames have an observer, and it makes no difference what it holds: attaching one starts a task that writes the frame's
    /// current method into it, so whether it already has the new method is a race, and the link must not depend on it.
    func testAFrameWithAnObserverIsLinkedWhateverItHolds() async throws {
        let (h, _, _, selective) = try await frameWithAnImagePerMethod(named: "method-observer")
        let observer = await MainActor.run { FrameObserver() }
        await h.frame.set(observer: observer)

        await h.frame.set(cleanMethod: .selective)

        XCTAssertEqual(try inode(try finalPath(h)), try inode(selective))
    }

    func testTheMethodIsAnOverrideInTheConfigWhetherOrNotAnythingIsLinked() async throws {
        let (h, _, _, _) = try await frameWithAnImagePerMethod(named: "method-override")

        await h.frame.set(cleanMethod: .selective, process: false)

        let config = await h.configManager.config()
        XCTAssertEqual(config.pixelReplacementOverrides[0], .selective)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try finalPath(h)),
                       "process: false only records the method; nothing is linked")
    }
}
