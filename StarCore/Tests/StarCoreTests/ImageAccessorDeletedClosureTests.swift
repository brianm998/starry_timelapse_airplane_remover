import XCTest
@testable import StarCore

/// `ImageAccessor.imageDeletedClosure` fires once per image file `deleteImage` really removes.
final class ImageAccessorDeletedClosureTests: XCTestCase {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func testFiresOnlyForRemovedFiles() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ImageAccessorDeletedClosureTests-\(UUID().uuidString)")
        let sequenceDir = tempDir.appendingPathComponent("seq")
        try FileManager.default.createDirectory(at: sequenceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = Config(
          outputPath: tempDir.path,
          imageSequenceName: "seq",
          imageSequencePath: tempDir.path,
          writeOutlierGroupFiles: false,
          writeFramePreviewFiles: false,
          writeFrameProcessedPreviewFiles: false,
          writeFrameThumbnailFiles: false
        )
        var accessor = ImageAccessor(
          config: config,
          imageSequence: try ImageSequence(dirname: sequenceDir.path,
                                           supportedImageFileTypes: [".jpg"]),
          frameIndexToBaseNameMap: [4: "LRT_00084.jpg"]
        )
        let log = Recorder()
        accessor.imageDeletedClosure = { index, type, size in
            log.add("\(index) \(type) \(size)")
        }

        let path = try XCTUnwrap(accessor.nameForImage(frameIndex: 4, ofType: .final, atSize: .original))
        try FileManager.default.createDirectory(
          atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
          withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data([1, 2, 3]))

        try accessor.deleteImage(frameIndex: 4, ofType: .final, atSize: .original)
        XCTAssertEqual(log.all, ["4 final original"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))

        // nothing there now: the delete throws, and the closure does not fire again
        XCTAssertThrowsError(try accessor.deleteImage(frameIndex: 4, ofType: .final, atSize: .original))
        XCTAssertEqual(log.all.count, 1)
    }
}
