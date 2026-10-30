import ArgumentParser
import XCTest
import StarCore
@testable import star

/// The cli's video input and output options: `--frame-format` for a video input, `--render-video` and `--video-path` for
/// the output video.  The encode and decode themselves are covered by the Gherkin video features.
final class VideoOptionsTests: XCTestCase {

    func testFrameFormatSpellings() {
        XCTAssertEqual(FrameDecodeFormat(argument: "tiff16"), .tiff16)
        XCTAssertEqual(FrameDecodeFormat(argument: "TIFF8"), .tiff8)
        XCTAssertEqual(FrameDecodeFormat(argument: "jpeg"), .jpeg)
        XCTAssertEqual(FrameDecodeFormat(argument: "jpeg:95"), FrameDecodeFormat(kind: .jpeg, jpegQuality: 95))
    }

    func testFrameFormatRejectsWhatItCannotMean() {
        for bad in ["", "png", "jpeg:", "jpeg:0", "jpeg:101", "jpeg:high", "tiff16:80", "jpeg:80:1"] {
            XCTAssertNil(FrameDecodeFormat(argument: bad), "`\(bad)` must not parse")
        }
    }

    func testParsesTheVideoOptions() throws {
        let cli = try StarCli.parse(["--frame-format", "jpeg:90", "--render-video", "--video-path", "/tmp/x.mov", "in.mp4"])
        XCTAssertEqual(cli.frameFormat, FrameDecodeFormat(kind: .jpeg, jpegQuality: 90))
        XCTAssertTrue(cli.renderVideo)
        XCTAssertEqual(cli.videoPath, "/tmp/x.mov")
    }

    func testDefaultsAreOff() throws {
        let cli = try StarCli.parse(["seq"])
        XCTAssertNil(cli.frameFormat)
        XCTAssertFalse(cli.renderVideo)
        XCTAssertNil(cli.videoPath)
    }

    func testVideoPathNeedsRenderVideo() {
        XCTAssertThrowsError(try StarCli.parse(["--video-path", "/tmp/x.mov", "seq"]))
    }

    func testFrameFormatNeedsAVideoInput() {
        // a directory is not a video
        XCTAssertThrowsError(try StarCli.parse(["--frame-format", "tiff8", NSTemporaryDirectory()]))
    }

    func testVideoFileDetection() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("VideoOptionsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp4 = dir.appendingPathComponent("a.MP4"), jpg = dir.appendingPathComponent("a.jpg")
        FileManager.default.createFile(atPath: mp4.path, contents: Data())
        FileManager.default.createFile(atPath: jpg.path, contents: Data())
        XCTAssertTrue(isVideoFile(path: mp4.path))
        XCTAssertFalse(isVideoFile(path: jpg.path))
        XCTAssertFalse(isVideoFile(path: dir.path), "a directory named like a video is a sequence")
        XCTAssertFalse(isVideoFile(path: dir.appendingPathComponent("missing.mp4").path))
    }
}
