import XCTest
@testable import StarCore
import StarCppBridge

final class JPEGOutputQualityTests: XCTestCase {
    private var tempDir: String!
    private let baseName = "LRT_00001.jpg"

    override func setUpWithError() throws {
        tempDir = NSTemporaryDirectory() + "JPEGOutputQualityTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir + "/seq", withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: tempDir) }

    /// Writes the output of a sequence whose frame was saved at `inputQuality`, returns its estimated quality.
    private func outputQuality(inputQuality: Int, sidecarQuality: Int?) async throws -> Int {
        let image = try XCTUnwrap(JPEGQualityTests.noisyImage())
        XCTAssertTrue(image.saveJpeg(withQuality: UInt(inputQuality), filename: "\(tempDir!)/seq/\(baseName)"))
        if let sidecarQuality {
            FrameExtractionSidecar(videoPath: "/none.mov", videoSize: 1, videoModified: 1, frameCount: 1,
                                   countIsExact: true, digits: 5,
                                   format: FrameDecodeFormat(kind: .jpeg, jpegQuality: sidecarQuality),
                                   accessKind: .seekable, complete: true)
              .write(inFolder: "\(tempDir!)/seq")
        }
        let config = Config(outputPath: tempDir, imageSequenceName: "seq", imageSequencePath: tempDir,
                            writeOutlierGroupFiles: false, writeFramePreviewFiles: false,
                            writeFrameProcessedPreviewFiles: false, writeFrameThumbnailFiles: false)
        let accessor = ImageAccessor(
          config: config,
          imageSequence: try ImageSequence(dirname: "\(tempDir!)/seq", supportedImageFileTypes: [".jpg"]),
          frameIndexToBaseNameMap: [0: baseName])
        try await accessor.save(image, frameIndex: 0, as: .final, atSize: .original, overwrite: true)
        let path = try XCTUnwrap(accessor.nameForImage(frameIndex: 0, ofType: .final, atSize: .original))
        return try XCTUnwrap(JPEGQuality.estimate(atPath: path))
    }

    func testOutputsMatchSidecarQuality() async throws {
        // the frames themselves say 95; the sidecar is what wins
        let q = try await outputQuality(inputQuality: 95, sidecarQuality: 80)
        XCTAssertLessThanOrEqual(abs(q - 80), 2)
    }

    func testOutputsMatchEstimatedQuality() async throws {
        let q = try await outputQuality(inputQuality: 80, sidecarQuality: nil)
        XCTAssertLessThanOrEqual(abs(q - 80), 2)
    }
}
