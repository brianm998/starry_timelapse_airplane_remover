import XCTest
@testable import StarCore

/// A video imported as jpeg or 8 bit tiff (see `FrameDecodeFormat`) has to come out the other end in that
/// format: processing names each final frame after its source, so a `.jpg` source gives a `.jpg` final frame,
/// and the writer takes the encoding from that name.  Nothing may turn the user's jpegs into tiffs, or an
/// 8 bit tiff into a 16 bit one.
final class OutputFormatPreservationTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OutputFormatPreservationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func accessor(sourceName: String) throws -> ImageAccessor {
        // a clean place for each: the output folder is named after the sequence, so two accessors would share it
        tempDir = tempDir.deletingLastPathComponent().appendingPathComponent("OutputFormatPreservationTests-\(UUID().uuidString)")
        let sequenceDir = tempDir.appendingPathComponent("seq")
        try FileManager.default.createDirectory(at: sequenceDir, withIntermediateDirectories: true)
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
          imageSequence: try ImageSequence(dirname: sequenceDir.path, supportedImageFileTypes: [".jpg", ".tiff"]),
          frameIndexToBaseNameMap: [0: sourceName]
        )
    }

    private func firstBytes(_ path: String, _ count: Int) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        return [UInt8](try handle.read(upToCount: count) ?? Data())
    }

    func testEveryFormatTheImporterWritesGetsAFinalFrameOfTheSameFormat() async throws {
        for format in [FrameDecodeFormat.tiff16, .tiff8, .jpeg] {
            let name = "image_0001.\(format.fileExtension)"
            let accessor = try accessor(sourceName: name)
            let path = try XCTUnwrap(accessor.nameForImage(frameIndex: 0, ofType: .final, atSize: .original))
            XCTAssertEqual((path as NSString).lastPathComponent, name, "\(format)")

            try ensureParentDirectoriesExist(for: path)
            try await accessor.save(FrameHarness.flatMask(width: 64, height: 64, at: 20),
                                    frameIndex: 0, as: .final, atSize: .original, overwrite: true)

            let bytes = try firstBytes(path, 4)
            switch format.kind {
            case .jpeg:
                XCTAssertEqual(Array(bytes.prefix(2)), [0xFF, 0xD8], "the jpeg's final frame is not a jpeg")
            case .tiff8, .tiff16:
                XCTAssertTrue(bytes == [0x49, 0x49, 0x2A, 0x00] || bytes == [0x4D, 0x4D, 0x00, 0x2A],
                              "\(format)'s final frame is not a tiff")
            }
            // and no tiff was written beside a jpeg
            let siblings = try FileManager.default.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent)
            XCTAssertEqual(siblings, [name], "\(format) left other files in the output folder")
        }
    }

    func testAnEightBitTiffIsWrittenBackEightBit() async throws {
        let name = "image_0001.tiff"
        let accessor = try accessor(sourceName: name)
        let path = try XCTUnwrap(accessor.nameForImage(frameIndex: 0, ofType: .final, atSize: .original))
        try ensureParentDirectoriesExist(for: path)
        try await accessor.save(FrameHarness.flatMask(width: 64, height: 64, at: 20),
                                frameIndex: 0, as: .final, atSize: .original, overwrite: true)
        let written = try XCTUnwrap(PixelatedImage(filename: path))
        XCTAssertEqual(written.bitsPerComponent, 8)
    }
}
