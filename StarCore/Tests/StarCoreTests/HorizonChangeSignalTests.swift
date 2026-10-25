import XCTest
@testable import StarCore

/// `ImageAccessor.horizonChangedClosure` is how both apps know to draw a frame's horizon
/// lines again: the horizon consensus, for one, is written for a whole sequence long before
/// most of its frames finish merging, and nothing else about those frames changes when it is.
final class HorizonChangeSignalTests: XCTestCase {

    private var tempDir: URL!
    private let frameIndex = 3

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
          .appendingPathComponent("HorizonChangeSignal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [Int] = []
        func record(_ frame: Int) { lock.withLock { frames.append(frame) } }
        var all: [Int] { lock.withLock { frames } }
    }

    private func accessor(_ changes: Changes) throws -> ImageAccessor {
        let sequenceDir = tempDir.appendingPathComponent("seq")
        try FileManager.default.createDirectory(at: sequenceDir, withIntermediateDirectories: true)
        let config = Config(
          outputPath: tempDir.path,
          imageSequenceName: "seq",
          imageSequencePath: tempDir.path,
          writeOutlierGroupFiles: false,
          writeFramePreviewFiles: true,
          writeFrameProcessedPreviewFiles: false,
          writeFrameThumbnailFiles: false
        )
        var accessor = ImageAccessor(
          config: config,
          imageSequence: try ImageSequence(dirname: sequenceDir.path,
                                           supportedImageFileTypes: [".jpg"]),
          frameIndexToBaseNameMap: [frameIndex: "frame_0003.tif"]
        )
        accessor.horizonChangedClosure = { changes.record($0) }
        return accessor
    }

    /// Every kind of horizon mask, written at full size, says so once; its preview, written
    /// beside it, does not say it again.
    func testWritingAnyHorizonMaskSaysTheFrameChanged() async throws {
        let changes = Changes()
        let accessor = try accessor(changes)
        let mask = FrameHarness.flatMask(width: 32, height: 32, at: 20)
        for type in [FrameViewMode.horizon, .mergedHorizon, .consensusHorizon] {
            try await accessor.save(mask, frameIndex: frameIndex, as: type,
                                    atSizes: [.original, .preview], overwrite: true)
        }
        XCTAssertEqual(changes.all, [frameIndex, frameIndex, frameIndex])
    }

    /// An image that is not a horizon says nothing.
    func testWritingAnotherImageSaysNothing() async throws {
        let changes = Changes()
        let accessor = try accessor(changes)
        try await accessor.save(FrameHarness.flatMask(width: 32, height: 32, at: 20),
                                frameIndex: frameIndex, as: .subtraction,
                                atSizes: [.original], overwrite: true)
        XCTAssertTrue(changes.all.isEmpty)
    }

    /// Deleting a horizon mask changes the lines too — the consensus line and its image are
    /// discarded together when a reference is repainted — but only a file that was there.
    func testDeletingAHorizonMaskSaysTheFrameChanged() async throws {
        let changes = Changes()
        let accessor = try accessor(changes)
        try await accessor.save(FrameHarness.flatMask(width: 32, height: 32, at: 20),
                                frameIndex: frameIndex, as: .consensusHorizon,
                                atSizes: [.original], overwrite: true)
        try accessor.deleteImage(frameIndex: frameIndex, ofType: .consensusHorizon,
                                 atSize: .original)
        XCTAssertEqual(changes.all, [frameIndex, frameIndex])
        XCTAssertThrowsError(try accessor.deleteImage(frameIndex: frameIndex,
                                                      ofType: .consensusHorizon,
                                                      atSize: .original),
                             "nothing left to delete")
        XCTAssertEqual(changes.all.count, 2)
    }
}
