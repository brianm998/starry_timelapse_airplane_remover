import XCTest
@testable import StarCore
import StarCppBridge

/// `ImageAccessor.save` used to raise the critical "could not write output" alert for a
/// write failure on *any* `FrameViewMode` saved at `.original` size — but `.original` size
/// is also how intermediate cache frames (`earthAligned`, `starAligned`, `autoProcessed`,
/// ...) are written, and those live under `tempOutputPath`, not the delivered output. A
/// transient failure writing one of those got reported as "star could not write its
/// output... the disk is most likely full", even though the actual output directory was
/// never touched and the run's real output was fine.
///
/// Only `.final` is the user's actual product (`Config.dirForImage` is the only case that
/// points at `outputPath` rather than `tempOutputPath`), so only a failure writing `.final`
/// should reach `OutputWriteFailures`.
final class ImageAccessorOutputWriteFailureTests: XCTestCase {

    private var tempDir: URL!
    private let baseFileName = "LRT_00084.jpg"
    private let frameIndex = 4

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ImageAccessorOutputWriteFailureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    override func setUp() async throws {
        await OutputWriteFailures.shared.reset()
    }

    override func tearDown() async throws {
        await OutputWriteFailures.shared.reset()
    }

    private func accessor() throws -> ImageAccessor {
        let sequenceDir = tempDir.appendingPathComponent("seq")
        try FileManager.default.createDirectory(at: sequenceDir,
                                                withIntermediateDirectories: true)
        let config = Config(
          outputPath: tempDir.path,
          imageSequenceName: "seq",
          imageSequencePath: tempDir.path,
          writeOutlierGroupFiles: false,
          writeFramePreviewFiles: false,
          writeFrameProcessedPreviewFiles: false,
          writeFrameThumbnailFiles: false
        )
        return ImageAccessor(
          config: config,
          imageSequence: try ImageSequence(dirname: sequenceDir.path,
                                           supportedImageFileTypes: [".jpg"]),
          frameIndexToBaseNameMap: [frameIndex: baseFileName]
        )
    }

    /// A 16-bit three-channel image, the shape a real output frame has.
    private func image(width: Int = 16, height: Int = 16) throws -> PixelatedImage {
        let count = width * height * 3
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: count)
        for index in 0..<count { data[index] = 0x4000 }
        let mat = MatWrapper(width: width, height: height,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 16,
                                                       componentsPerPixel: 3),
                             bytesPerRow: width * 3 * 2,
                             data: UnsafeMutableRawPointer(data),
                             takeOwnership: true)
        guard let image = PixelatedImage(mat: mat) else { throw "could not build a test image" }
        return image
    }

    /// Makes `save` fail for real, through the same C++ path a full disk takes: remove the
    /// directory a type would be written into, so `mat_wrapper_write_to` gets ENOENT.
    private func breakOutputDir(_ accessor: ImageAccessor, for type: FrameViewMode) throws {
        let dirname = try XCTUnwrap(accessor.nameForImage(frameIndex: frameIndex,
                                                          ofType: type,
                                                          atSize: .original))
        try FileManager.default.removeItem(
          atPath: URL(fileURLWithPath: dirname).deletingLastPathComponent().path)
    }

    /// The bug: a failed write of an intermediate cache frame must not raise the critical
    /// "could not write output, disk is likely full" alert. It's worth a log line, since
    /// it'll just be recreated, but the real output was never touched.
    func testAFailedEarthAlignedWriteIsNotRecordedAsAnOutputFailure() async throws {
        let accessor = try accessor()
        try breakOutputDir(accessor, for: .earthAligned)

        try await accessor.save(try image(), frameIndex: frameIndex, as: .earthAligned,
                                atSize: .original, overwrite: true)

        let isEmpty = await OutputWriteFailures.shared.isEmpty()
        XCTAssertTrue(isEmpty,
                      "a failure writing an intermediate cache frame is not an output failure")
    }

    /// The contrast: a failed write of `.final` — the actual delivered output — must still
    /// be recorded, or a full disk during the real render would go unnoticed again.
    func testAFailedFinalWriteIsRecordedAsAnOutputFailure() async throws {
        let accessor = try accessor()
        try breakOutputDir(accessor, for: .final)

        try await accessor.save(try image(), frameIndex: frameIndex, as: .final,
                                atSize: .original, overwrite: true)

        let isEmpty = await OutputWriteFailures.shared.isEmpty()
        XCTAssertFalse(isEmpty, "a failed write of the actual output must be recorded")
    }
}
