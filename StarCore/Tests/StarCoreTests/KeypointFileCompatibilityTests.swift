import XCTest
@testable import StarCore
@testable import StarCppBridge

/// Sequences whose keypoint files were written as `.yaml` by earlier versions keep working.
final class KeypointFileCompatibilityTests: FrameHarnessTestCase {

    private func config(_ dir: String) -> Config {
        var c = Config()
        c.tempOutputPath = dir
        return c
    }

    private func tempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kpcompat-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    func testNewNamesAreBinaryAndLegacyIsYaml() throws {
        let c = config(try tempDir())
        let path = try XCTUnwrap(c.keypointPath(frameIndex: 4, ofType: .starAligned))
        XCTAssertTrue(path.hasSuffix(".sky.kpb"))
        XCTAssertEqual(c.legacyKeypointPath(frameIndex: 4, ofType: .starAligned),
                       String(path.dropLast(3)) + "yaml")
    }

    /// A sequence with only `.yaml` files is seen as having its keypoints, so nothing is re-detected.
    func testYamlOnlySequenceReused() async throws {
        let c = config(try tempDir())
        let kpb = try XCTUnwrap(c.keypointPath(frameIndex: 0, ofType: .starAligned))
        StarCore.mkdir((kpb as NSString).deletingLastPathComponent)
        XCTAssertNil(c.existingKeypointPath(frameIndex: 0, ofType: .starAligned))

        let yaml = try XCTUnwrap(c.legacyKeypointPath(frameIndex: 0, ofType: .starAligned))
        try Data("planted".utf8).write(to: URL(fileURLWithPath: yaml))
        XCTAssertEqual(c.existingKeypointPath(frameIndex: 0, ofType: .starAligned), yaml)
        XCTAssertNil(c.existingKeypointPath(frameIndex: 0, ofType: .earthAligned))

        let h = try await FrameHarness.make(frameCount: 1, named: "kp-yaml-only")
        harness = h
        let hc = await h.configManager.config()
        let hy = try XCTUnwrap(hc.legacyKeypointPath(frameIndex: 0, ofType: .starAligned))
        try Data("planted".utf8).write(to: URL(fileURLWithPath: hy))
        XCTAssertTrue(h.frame.keypointsExistOnDisk(ofType: .starAligned, config: hc))
        let op = KeypointOp(forStars: true, frame: h.frame, mode: .starAligned,
                            limiter: KeypointLimiter(max: 1),
                            keypointPath: hc.keypointPath(frameIndex: 0, ofType: .starAligned)) { _ in }
        let work = await op.hasWorkToDo()
        XCTAssertFalse(work, "a legacy .yaml file means the frame is not re-detected")

        // The binary form wins when both exist.
        let kb = try XCTUnwrap(hc.keypointPath(frameIndex: 0, ofType: .starAligned))
        try Data("planted".utf8).write(to: URL(fileURLWithPath: kb))
        XCTAssertEqual(hc.existingKeypointPath(frameIndex: 0, ofType: .starAligned), kb)
    }
}
