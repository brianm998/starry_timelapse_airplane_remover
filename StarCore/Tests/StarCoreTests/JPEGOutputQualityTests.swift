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
    private func outputQuality(inputQuality: Int, sidecarQuality: Int?, override: Int? = nil, live: Int? = nil) async throws -> Int {
        let image = try XCTUnwrap(JPEGQualityTests.noisyImage())
        XCTAssertTrue(image.saveJpeg(withQuality: UInt(inputQuality), filename: "\(tempDir!)/seq/\(baseName)"))
        if let sidecarQuality {
            FrameExtractionSidecar(videoPath: "/none.mov", videoSize: 1, videoModified: 1, frameCount: 1,
                                   countIsExact: true, digits: 5,
                                   format: FrameDecodeFormat(kind: .jpeg, jpegQuality: sidecarQuality),
                                   accessKind: .seekable, complete: true)
              .write(inFolder: "\(tempDir!)/seq")
        }
        var config = Config(outputPath: tempDir, imageSequenceName: "seq", imageSequencePath: tempDir,
                            writeOutlierGroupFiles: false, writeFramePreviewFiles: false,
                            writeFrameProcessedPreviewFiles: false, writeFrameThumbnailFiles: false)
        config.outputJPEGQuality = override
        let accessor = ImageAccessor(
          config: config,
          imageSequence: try ImageSequence(dirname: "\(tempDir!)/seq", supportedImageFileTypes: [".jpg"]),
          frameIndexToBaseNameMap: [0: baseName])
        let copy = accessor      // a frame's copy shares the live override
        if let live { copy.outputQualityOverride.value = live }
        try await copy.save(image, frameIndex: 0, as: .final, atSize: .original, overwrite: true)
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

    func testOverrideWins() async throws {
        let q = try await outputQuality(inputQuality: 95, sidecarQuality: nil, override: 60)
        XCTAssertLessThanOrEqual(abs(q - 60), 2)
        // clearing it returns to the input's
        let back = try await outputQuality(inputQuality: 95, sidecarQuality: nil, override: nil)
        XCTAssertLessThanOrEqual(abs(back - 95), 2)
    }

    func testLiveOverrideReachesACopy() async throws {
        let q = try await outputQuality(inputQuality: 95, sidecarQuality: nil, live: 70)
        XCTAssertLessThanOrEqual(abs(q - 70), 2)
    }

    func testOverrideRoundTripsAndIsRecordedForTheOutputStage() throws {
        var config = Config(outputPath: tempDir, imageSequenceName: "seq", imageSequencePath: tempDir,
                            writeOutlierGroupFiles: false, writeFramePreviewFiles: false,
                            writeFrameProcessedPreviewFiles: false, writeFrameThumbnailFiles: false)
        XCTAssertNil(config.outputJPEGQuality)
        config.outputJPEGQuality = 60
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(back.outputJPEGQuality, 60)
    }
}
