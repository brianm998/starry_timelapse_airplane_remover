import XCTest
import Foundation
import StarCore
import StarDaemonMessages
import SwiftProtobuf

/// A video exported through the daemon, and what it sounds like.
///
/// The desktop client's Render Video dialog always sends its own encode settings, and the daemon
/// used to read any request that carried settings as "this video has no sound", so a video that
/// came in with sound went out silent.  Nothing was wrong at either end: the sound was kept
/// beside the frames on import, and the render knows how to put it back.  The loss was in the
/// middle, in the handler that joins them, which is why this runs the real `stard`, the ffmpeg
/// star ships, and a source with sound that is not AAC (the kind `AudioSidecar` exists for).
///
/// The frames an export encodes are the ones a render leaves in the config's
/// `outputSequenceDirname`; here they are copied there from the decoded source, which saves
/// running the whole detection pipeline over a synthetic video to get files that are exactly as
/// good for this.
///
/// Skipped when `stard` or ffmpeg has not been built, which is a fresh checkout's normal state.
final class ExportVideoAudioTests: XCTestCase {

    private var scratch = ""
    private var tools: URL!
    private var daemons: [DaemonProcess] = []

    private let frameCount = 24

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: DaemonIntegrationTests.stardPath),
                          "stard is not built; run `swift build` in daemon/")

        // <repo>/external_binaries/bin, found from this file's own location
        tools = URL(fileURLWithPath: #filePath)
          .deletingLastPathComponent()   // StarDaemonTests
          .deletingLastPathComponent()   // Tests
          .deletingLastPathComponent()   // daemon
          .deletingLastPathComponent()   // <repo>
          .appendingPathComponent("external_binaries")
          .appendingPathComponent("bin")
        for tool in ["ffmpeg", "ffprobe"] {
            try XCTSkipUnless(FileManager.default.fileExists(atPath: tools.appendingPathComponent(tool).path),
                              "ffmpeg is not built here; run ffmpeg/build.sh --install")
        }
        let encoders = try run("ffmpeg", ["-hide_banner", "-encoders"])
        for encoder in ["libx264", "prores_ks", "mpeg4"] {
            try XCTSkipUnless(encoders.contains(" \(encoder) "), "this ffmpeg has no \(encoder)")
        }

        scratch = FileManager.default.temporaryDirectory
          .appendingPathComponent("stard-export-audio-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for daemon in daemons { daemon.terminate() }
        daemons = []
        if !scratch.isEmpty { try? FileManager.default.removeItem(atPath: scratch) }
    }

    // MARK: - the tools

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = tools.appendingPathComponent(tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            var message = "\(tool) \(arguments.joined(separator: " ")) failed: "
            message += String(decoding: errors, as: UTF8.self)
            throw NSError(domain: "ExportVideoAudioTests", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// One second of video, and of PCM sound if `withSound`: what an editor or a camera writes,
    /// and not AAC.
    private func makeVideo(_ name: String, withSound: Bool = true) throws -> String {
        let path = "\(scratch)/\(name)"
        var arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y",
                         "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24"]
        if withSound {
            arguments += ["-f", "lavfi", "-i", "sine=frequency=440:duration=1"]
        }
        arguments += ["-frames:v", "\(frameCount)", "-c:v", "mpeg4", "-pix_fmt", "yuv420p"]
        if withSound {
            arguments += ["-c:a", "pcm_s16le", "-shortest"]
        }
        arguments.append(path)
        try run("ffmpeg", arguments)
        return path
    }

    /// The codec of the first stream of `kind` (`a` or `v`) in a file, or nil if it has none.
    private func codec(ofFirst kind: String, in path: String) throws -> String? {
        let output = try run("ffprobe", [
            "-v", "error", "-select_streams", "\(kind):0",
            "-show_entries", "stream=codec_name", "-of", "default=noprint_wrappers=1:nokey=1", path])
        let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    // MARK: - the daemon

    private func launchDaemon() throws -> DaemonProcess {
        var environment = ProcessInfo.processInfo.environment
        environment[ToolPaths.directoryOverrideVariable] = tools.path
        let daemon = try DaemonProcess(binaryPath: DaemonIntegrationTests.stardPath,
                                       scratchDir: "\(scratch)/daemon",
                                       environment: environment)
        daemons.append(daemon)
        return daemon
    }

    private func openVideo(_ daemon: DaemonProcess, _ path: String) async throws -> Star_V1_SessionInfo {
        var request = Star_V1_OpenVideoRequest()
        request.videoPath = path
        let result = try await daemon.stream(method: "Session.OpenVideo", request: request)
        if let failure = result.failure {
            XCTFail("Session.OpenVideo failed: \(failure.message)")
        }
        for item in result.items.reversed() {
            if case .done(let info)? = try Star_V1_OpenProgress(serializedBytes: item).kind {
                return info
            }
        }
        throw XCTSkip("Session.OpenVideo never reported the opened session")
    }

    private func config(of info: Star_V1_SessionInfo) throws -> Config {
        try JSONDecoder().decode(Config.self,
                                 from: Data(contentsOf: URL(fileURLWithPath: info.configJsonPath)))
    }

    /// What a finished render leaves for the export to encode: the frames, in the folder the
    /// config says the final sequence goes to.
    private func renderFrames(of info: Star_V1_SessionInfo, from video: String) throws {
        let config = try config(of: info)
        let decoded = URL(fileURLWithPath: video).deletingPathExtension().path
        let rendered = config.outputSequenceDirname
        try FileManager.default.createDirectory(atPath: rendered, withIntermediateDirectories: true)
        for number in 1...frameCount {
            let name = String(format: "image_%04d.tiff", number)
            try? FileManager.default.removeItem(atPath: "\(rendered)/\(name)")
            try FileManager.default.copyItem(atPath: "\(decoded)/\(name)", toPath: "\(rendered)/\(name)")
        }
    }

    private func settings(codec: String, encoder: String, pixelFormat: String,
                          muxer: String) -> Star_V1_VideoEncodeSettings
    {
        var settings = Star_V1_VideoEncodeSettings()
        settings.frameRate = 24
        settings.codec = codec
        settings.encoder = encoder
        settings.pixelFormat = pixelFormat
        settings.muxer = muxer
        return settings
    }

    /// Runs `Export.Video` and returns how it ended; fails the test if it failed.
    @discardableResult
    private func export(_ daemon: DaemonProcess,
                        session: Star_V1_SessionInfo,
                        to path: String,
                        with settings: Star_V1_VideoEncodeSettings?) async throws -> DaemonProcess.StreamResult
    {
        var request = Star_V1_ExportVideoRequest()
        request.sessionID = session.sessionID
        request.outputVideoPath = path
        if let settings { request.settings = settings }
        let result = try await daemon.stream(method: "Export.Video", request: request)
        if let failure = result.failure {
            XCTFail("Export.Video failed: \(failure.message)")
        }
        return result
    }

    private let proresInMov = (codec: "prores", encoder: "prores_ks", pixelFormat: "yuv422p10le", muxer: "mov")
    private let h264InMp4 = (codec: "h264", encoder: "libx264", pixelFormat: "yuv420p", muxer: "mp4")

    // MARK: - the reported failure

    /// What the desktop client does: send the settings the dialog's pickers show.  The sound has
    /// to come along, as the PCM it was; QuickTime plays that.
    func testAnExportWithTheClientsOwnSettingsHasTheSourcesSound() async throws {
        let video = try makeVideo("source.mov")
        let daemon = try launchDaemon()
        let info = try await openVideo(daemon, video)
        XCTAssertTrue(info.sourceVideoInfo.hasAudio_p,
                      "the fixture has to have come in with sound, or the rest of this is vacuous")
        try renderFrames(of: info, from: video)

        let output = "\(scratch)/out.mov"
        let chosen = proresInMov
        try await export(daemon, session: info, to: output,
                         with: settings(codec: chosen.codec, encoder: chosen.encoder,
                                        pixelFormat: chosen.pixelFormat, muxer: chosen.muxer))

        XCTAssertEqual(try codec(ofFirst: "v", in: output), "prores",
                       "the request's settings, not the source's, have to have been used")
        XCTAssertEqual(try codec(ofFirst: "a", in: output), "pcm_s16le",
                       "the sound the video came in with is gone from the export")
    }

    /// MP4 is where ffmpeg will write PCM that almost nothing plays, so there it is AAC.
    func testAnMp4ExportOfPcmSoundIsAac() async throws {
        let video = try makeVideo("source.mov")
        let daemon = try launchDaemon()
        let info = try await openVideo(daemon, video)
        try renderFrames(of: info, from: video)

        let output = "\(scratch)/out.mp4"
        let chosen = h264InMp4
        try await export(daemon, session: info, to: output,
                         with: settings(codec: chosen.codec, encoder: chosen.encoder,
                                        pixelFormat: chosen.pixelFormat, muxer: chosen.muxer))

        XCTAssertEqual(try codec(ofFirst: "v", in: output), "h264")
        XCTAssertEqual(try codec(ofFirst: "a", in: output), "aac")
    }

    /// No settings in the request means the ones the video came in with, which always worked.
    func testAnExportWithNoSettingsHasTheSourcesSound() async throws {
        let video = try makeVideo("source.mov")
        let daemon = try launchDaemon()
        let info = try await openVideo(daemon, video)
        try renderFrames(of: info, from: video)

        let output = "\(scratch)/out.mov"
        try await export(daemon, session: info, to: output, with: nil)

        XCTAssertEqual(try codec(ofFirst: "v", in: output), "mpeg4", "the source's own settings")
        XCTAssertEqual(try codec(ofFirst: "a", in: output), "pcm_s16le")
    }

    /// A session resumed from its config has no record of the video it was opened from, only the
    /// config on disk, which has to be enough to know there was sound.
    func testAResumedSessionStillHasTheSourcesSound() async throws {
        let video = try makeVideo("source.mov")
        let daemon = try launchDaemon()
        let opened = try await openVideo(daemon, video)
        try renderFrames(of: opened, from: video)

        var reopen = Star_V1_OpenConfigRequest()
        reopen.configJsonPath = opened.configJsonPath
        let resumed: Star_V1_SessionInfo = try await daemon.call(method: "Session.OpenConfig", request: reopen)
        XCTAssertFalse(resumed.hasSourceVideoInfo,
                       "a resumed session knows nothing of its source video, which is the point")

        let output = "\(scratch)/out.mov"
        let chosen = proresInMov
        try await export(daemon, session: resumed, to: output,
                         with: settings(codec: chosen.codec, encoder: chosen.encoder,
                                        pixelFormat: chosen.pixelFormat, muxer: chosen.muxer))

        XCTAssertEqual(try codec(ofFirst: "a", in: output), "pcm_s16le")
    }

    /// Making sound up would be as wrong as losing it.
    func testAVideoWithNoSoundExportsWithNoSound() async throws {
        let video = try makeVideo("silent.mov", withSound: false)
        let daemon = try launchDaemon()
        let info = try await openVideo(daemon, video)
        XCTAssertFalse(info.sourceVideoInfo.hasAudio_p)
        try renderFrames(of: info, from: video)

        let output = "\(scratch)/out.mov"
        let chosen = proresInMov
        try await export(daemon, session: info, to: output,
                         with: settings(codec: chosen.codec, encoder: chosen.encoder,
                                        pixelFormat: chosen.pixelFormat, muxer: chosen.muxer))

        XCTAssertEqual(try codec(ofFirst: "v", in: output), "prores")
        XCTAssertNil(try codec(ofFirst: "a", in: output))
    }

    // MARK: - the way the desktop asks

    /// The Render Video dialog sends no output path (`""`), and the protocol says the daemon then
    /// names the file `<basename>.<muxer>`, beside the frames, as the Mac app's dialog does.
    func testAnExportWithNoOutputPathIsNamedAfterTheSequenceBesideItsFrames() async throws {
        let video = try makeVideo("source.mov")
        let daemon = try launchDaemon()
        let info = try await openVideo(daemon, video)
        try renderFrames(of: info, from: video)

        let config = try config(of: info)
        let expected = "\(config.outputPath)/\(config.basename).mov"
        let chosen = proresInMov
        try await export(daemon, session: info, to: "",
                         with: settings(codec: chosen.codec, encoder: chosen.encoder,
                                        pixelFormat: chosen.pixelFormat, muxer: chosen.muxer))

        XCTAssertTrue(FileManager.default.fileExists(atPath: expected),
                      "expected the video at \(expected)")
        XCTAssertEqual(try codec(ofFirst: "a", in: expected), "pcm_s16le")
    }
}
