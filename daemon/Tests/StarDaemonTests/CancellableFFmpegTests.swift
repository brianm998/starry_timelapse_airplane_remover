import XCTest
import StarCore
@testable import stard

/// A render the user gives up on has to stop ffmpeg, not just stop listening to it: the old runner blocked
/// its thread until ffmpeg exited whatever happened to the task that called it, so the video kept being
/// written, and the dialog that had started it was already gone.
final class CancellableFFmpegTests: XCTestCase {

    /// The ffmpeg this repository ships, found from this file; nil (skipped) where it has not been fetched.
    private var ffmpeg: String? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("external_binaries/bin/ffmpeg").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private func requireFFmpeg() throws -> String {
        try XCTUnwrap(ffmpeg, "external_binaries/bin/ffmpeg is not here")
    }

    func testARunThatFinishesReportsItsFramesAndReturns() async throws {
        let path = try requireFFmpeg()
        let frames = FrameCounter()
        try await runCancellableFFmpegWithProgress(
            arguments: ["-v", "info", "-stats", "-f", "lavfi", "-i", "testsrc=duration=1:size=64x64:rate=10", "-f", "null", "-"],
            totalFrames: 10, ffmpegPath: path, outputFolder: "/tmp"
        ) { current, _, _ in frames.record(current) }
        XCTAssertGreaterThan(frames.last, 0, "no progress reached the callback")
    }

    func testARunThatFailsThrowsWithFFmpegsMessage() async throws {
        let path = try requireFFmpeg()
        do {
            try await runCancellableFFmpegWithProgress(
                arguments: ["-i", "/no/such/input.mov", "-f", "null", "-"],
                totalFrames: nil, ffmpegPath: path, outputFolder: "/tmp"
            ) { _, _, _ in }
            XCTFail("an ffmpeg that could not open its input did not throw")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "ffmpeg")
        }
    }

    /// An hour of video read in real time: it only ends if it is stopped.
    func testCancellingTheTaskStopsFFmpegAtOnce() async throws {
        let path = try requireFFmpeg()
        let started = Date()
        let task = Task {
            try await runCancellableFFmpegWithProgress(
                arguments: ["-f", "lavfi", "-re", "-i", "testsrc=size=64x64:rate=30", "-t", "3600", "-f", "null", "-"],
                totalFrames: nil, ffmpegPath: path, outputFolder: "/tmp"
            ) { _, _, _ in }
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        task.cancel()
        do {
            try await task.value
            XCTFail("a cancelled render returned normally")
        } catch is CancellationError {
            // expected
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 15, "the run did not stop when it was cancelled")
    }

    func testATaskCancelledBeforeItStartsNeverStartsFFmpeg() async throws {
        let path = try requireFFmpeg()
        let task = Task {
            try await Task.sleep(nanoseconds: 200_000_000)   // cancelled while it sleeps
            try await runCancellableFFmpegWithProgress(
                arguments: ["-f", "lavfi", "-i", "testsrc=duration=60:size=64x64:rate=30", "-f", "null", "-"],
                totalFrames: nil, ffmpegPath: path, outputFolder: "/tmp"
            ) { _, _, _ in }
        }
        task.cancel()
        do { try await task.value; XCTFail("returned normally") } catch is CancellationError {}
    }

    // MARK: - the default file name

    private func config() -> Config {
        Config(outputPath: "/o", imageSequenceName: "night", imageSequencePath: "/in",
               writeOutlierGroupFiles: false, writeFramePreviewFiles: false,
               writeFrameProcessedPreviewFiles: false, writeFrameThumbnailFiles: false)
    }

    /// `matroska` and `mpegts` are ffmpeg's names for the containers, not their file extensions.
    func testTheDefaultVideoNameUsesTheContainersFileExtension() {
        let config = config()
        XCTAssertEqual(VideoExport.defaultOutputPath(config: config, muxer: .matroska), "/o/\(config.basename).mkv")
        XCTAssertEqual(VideoExport.defaultOutputPath(config: config, muxer: .mpegts), "/o/\(config.basename).ts")
        XCTAssertEqual(VideoExport.defaultOutputPath(config: config, muxer: .mp4), "/o/\(config.basename).mp4")
    }
}

/// Progress arrives on ffmpeg's stderr reader, not the test's task.
private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record(_ n: Int) { lock.lock(); value = max(value, n); lock.unlock() }
    var last: Int { lock.lock(); defer { lock.unlock() }; return value }
}
