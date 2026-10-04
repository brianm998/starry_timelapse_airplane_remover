import XCTest
@testable import StarCore

/// star's video path run against the ffmpeg and ffprobe it actually ships: the pair
/// `ffmpeg/build.sh --install` leaves in the repository's external_binaries/bin.
///
/// Skipped when that pair has not been built, which is a fresh checkout's normal state; a
/// machine that has built it (or CI that has fetched it) gets the real thing, so a build of
/// ffmpeg that cannot run here, or that lost an encoder star offers, fails these.
final class VideoConvertTests: XCTestCase {

    /// <repo>/external_binaries/bin, found from this file's own location.
    private var shippedToolsDirectory: URL {
        URL(fileURLWithPath: #filePath)
          .deletingLastPathComponent()   // StarCoreTests
          .deletingLastPathComponent()   // Tests
          .deletingLastPathComponent()   // StarCore
          .deletingLastPathComponent()   // <repo>
          .appendingPathComponent("external_binaries")
          .appendingPathComponent("bin")
    }

    private var scratch: URL!
    private var previousOverride: String?

    override func setUpWithError() throws {
        let directory = shippedToolsDirectory
        let ffmpeg = directory.appendingPathComponent(ToolPaths.fileName(of: "ffmpeg")).path
        let ffprobe = directory.appendingPathComponent(ToolPaths.fileName(of: "ffprobe")).path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ffmpeg) && FileManager.default.fileExists(atPath: ffprobe),
                          "ffmpeg is not built here; run ffmpeg/build.sh --install")

        previousOverride = ProcessInfo.processInfo.environment[ToolPaths.directoryOverrideVariable]
        setenv(ToolPaths.directoryOverrideVariable, directory.path, 1)

        scratch = FileManager.default.temporaryDirectory
          .appendingPathComponent("VideoConvertTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let previousOverride {
            setenv(ToolPaths.directoryOverrideVariable, previousOverride, 1)
        } else {
            unsetenv(ToolPaths.directoryOverrideVariable)
        }
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func ffmpeg(_ arguments: [String]) throws {
        var all = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"]
        all += arguments
        _ = try shellOut(to: ToolPaths.ffmpeg, arguments: all)
    }

    /// 24 frames with a sine-wave audio track, the way a camera file has both.
    private func makeSourceVideo() throws -> String {
        let path = scratch.appendingPathComponent("source.mp4").path
        try ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24",
                    "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                    "-frames:v", "24", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-shortest", path])
        return path
    }

    // MARK: -

    /// The regression this whole directory exists for: the shipped tools can be started on
    /// this machine.  An x86_64-only ffmpeg on an Apple silicon Mac without Rosetta fails here
    /// with a message that says so.
    func testTheShippedToolsCanBeRunOnThisMachine() throws {
        XCTAssertTrue(ToolPaths.isAvailable, "tools not found at \(ToolPaths.ffmpeg)")
        for tool in [ToolPaths.ffmpeg, ToolPaths.ffprobe] {
            XCTAssertNil(ToolPaths.problem(with: tool))
            let version = try shellOut(to: tool, arguments: ["-hide_banner", "-version"])
            XCTAssertTrue(version.contains("-star"), "\(tool) is not star's own build: \(version.prefix(80))")
        }
    }

    func testDecodingAVideoProducesTheFramesTheAudioAndTheDescription() async throws {
        let video = try makeSourceVideo()

        let progressed = ProgressCounter()
        let (directory, info) = try await decodeVideo(named: video) { frame, _, _ in
            progressed.note(frame)
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: directory)
        XCTAssertEqual(files.filter { $0.hasPrefix("image_") && $0.hasSuffix(".tiff") }.count, 24)
        XCTAssertTrue(files.contains("audio.aac"))

        XCTAssertEqual(info.codec, .h264)
        XCTAssertEqual(info.pixelFormat, .yuv420p)
        XCTAssertEqual(info.frameRate.rawValue, 24)
        XCTAssertTrue(info.hasAudio)
        XCTAssertEqual(info.muxer, .mp4)
        XCTAssertGreaterThan(progressed.highest, 0, "no progress was reported")
    }

    /// The export direction: the decoded frames back into a video, as the daemon's export does.
    func testEncodingTheFramesBackIntoAVideo() async throws {
        let video = try makeSourceVideo()
        let (directory, _) = try await decodeVideo(named: video) { _, _, _ in }

        let output = scratch.appendingPathComponent("out.mov").path
        let progressed = ProgressCounter()
        try runFFmpegWithProgress(
          arguments: ["-framerate", "24", "-start_number", "1",
                      "-i", "\(directory)/image_%04d.tiff",
                      "-c:v", "prores_ks", "-pix_fmt", "yuv422p10le", "-y", output],
          totalFrames: 24,
          outputFolder: directory
        ) { frame, _, _ in progressed.note(frame) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: output))
        XCTAssertEqual(progressed.highest, 24)

        let counted = try shellOut(to: ToolPaths.ffprobe, arguments: [
            "-v", "error", "-count_frames", "-select_streams", "v:0",
            "-show_entries", "stream=nb_read_frames,codec_name", "-of", "default=noprint_wrappers=1",
            output])
        XCTAssertTrue(counted.contains("nb_read_frames=24"), counted)
        XCTAssertTrue(counted.contains("codec_name=prores"), counted)
    }

    func testAnEncoderThatDoesNotExistFailsWithFFmpegsOwnMessageAndNoBanner() throws {
        let video = try makeSourceVideo()
        do {
            try runFFmpegWithProgress(
              arguments: ["-i", video, "-c:v", "no_such_encoder", "-y", scratch.appendingPathComponent("x.mp4").path],
              totalFrames: 24,
              outputFolder: scratch.path
            ) { _, _, _ in }
            XCTFail("an unknown encoder should fail")
        } catch let error as NSError {
            let stderr = error.userInfo["stderr"] as? String ?? ""
            XCTAssertTrue(stderr.contains("no_such_encoder"), stderr)
            XCTAssertFalse(stderr.contains("configuration:"), "the build banner should be hidden: \(stderr.prefix(200))")
        }
    }

    /// ffmpeg polls stdin for keypresses, `q` among them, so a child that inherits a terminal or
    /// a pipe would take input meant for whoever else reads it and end its own encode on a stray
    /// `q`.  This feeds this process a stdin full of them and checks the encode still completes.
    func testFFmpegDoesNotReadThisProcessesStdin() async throws {
        let video = try makeSourceVideo()
        let (directory, _) = try await decodeVideo(named: video) { _, _, _ in }

        var pipeFds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&pipeFds), 0)
        let originalStdin = dup(STDIN_FILENO)
        defer {
            dup2(originalStdin, STDIN_FILENO)
            close(originalStdin)
            close(pipeFds[0])
            close(pipeFds[1])
        }
        dup2(pipeFds[0], STDIN_FILENO)
        let quits = [UInt8](repeating: UInt8(ascii: "q"), count: 64)
        _ = quits.withUnsafeBytes { write(pipeFds[1], $0.baseAddress, $0.count) }

        let output = scratch.appendingPathComponent("stdin.mp4").path
        try runFFmpegWithProgress(
          arguments: ["-framerate", "24", "-start_number", "1", "-i", "\(directory)/image_%04d.tiff",
                      "-c:v", "libx264", "-pix_fmt", "yuv420p", "-y", output],
          totalFrames: 24,
          outputFolder: directory
        ) { _, _, _ in }

        let counted = try shellOut(to: ToolPaths.ffprobe, arguments: [
            "-v", "error", "-count_frames", "-select_streams", "v:0",
            "-show_entries", "stream=nb_read_frames", "-of", "default=noprint_wrappers=1:nokey=1", output])
        XCTAssertEqual(counted.trimmingCharacters(in: .whitespacesAndNewlines), "24")
    }

    /// Every codec star offers first, and the encoders behind them, has to be in this build:
    /// the Render Video dialog lists them, so one that is missing is a button that fails.
    func testTheEncodersTheDialogLeadsWithAreBuiltIn() throws {
        let listing = try shellOut(to: ToolPaths.ffmpeg, arguments: ["-hide_banner", "-encoders"])
        for encoder in ["libx264", "libx265", "prores_ks", "dnxhd"] {
            XCTAssertTrue(listing.contains(" \(encoder) "), "\(encoder) is not in this ffmpeg")
        }
    }
}

/// Progress callbacks arrive on ffmpeg's pipe-reading thread.
private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var maximum = 0

    func note(_ frame: Int) {
        lock.lock()
        maximum = max(maximum, frame)
        lock.unlock()
    }

    var highest: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximum
    }
}
