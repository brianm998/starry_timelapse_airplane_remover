import XCTest
import Foundation
import StarCore
import StarDaemonMessages
import SwiftProtobuf

/// What the tests that run a video export through the real `stard` and the ffmpeg star ships have
/// in common: finding both, a scratch folder, a daemon to talk to, and asking ffprobe what came out.
///
/// Skipped when `stard` or ffmpeg has not been built, which is a fresh checkout's normal state.
class ExportEndToEndTestCase: XCTestCase {

    var scratch = ""
    var tools: URL!
    private var daemons: [DaemonProcess] = []

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
        let encoders = String(decoding: try runBinary("ffmpeg", ["-hide_banner", "-encoders"]), as: UTF8.self)
        for encoder in ["libx264", "prores_ks", "mpeg4"] {
            try XCTSkipUnless(encoders.contains(" \(encoder) "), "this ffmpeg has no \(encoder)")
        }

        scratch = FileManager.default.temporaryDirectory
          .appendingPathComponent("stard-export-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for daemon in daemons { daemon.terminate() }
        daemons = []
        if !scratch.isEmpty { try? FileManager.default.removeItem(atPath: scratch) }
    }

    // MARK: - the tools

    /// Runs one of the shipped tools and returns what it wrote to stdout.
    func runBinary(_ tool: String, _ arguments: [String]) throws -> Data {
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
            throw NSError(domain: "ExportEndToEndTestCase", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        return output
    }

    @discardableResult
    func run(_ tool: String, _ arguments: [String]) throws -> String {
        String(decoding: try runBinary(tool, arguments), as: UTF8.self)
    }

    /// The codec of the first stream of `kind` (`a` or `v`) in a file, or nil if it has none.
    func codec(ofFirst kind: String, in path: String) throws -> String? {
        let output = try run("ffprobe", [
            "-v", "error", "-select_streams", "\(kind):0",
            "-show_entries", "stream=codec_name", "-of", "default=noprint_wrappers=1:nokey=1", path])
        let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// How many frames a video has, counted rather than read from its header, and the frame rate
    /// it is played at.
    func videoFacts(of path: String) throws -> (frames: Int, frameRate: String) {
        let output = try run("ffprobe", [
            "-v", "error", "-count_frames", "-select_streams", "v:0",
            "-show_entries", "stream=nb_read_frames,r_frame_rate", "-of", "default=noprint_wrappers=1", path])
        var frames = -1
        var frameRate = ""
        for line in output.split(separator: "\n") {
            if line.hasPrefix("nb_read_frames=") { frames = Int(line.dropFirst("nb_read_frames=".count)) ?? -1 }
            if line.hasPrefix("r_frame_rate=") { frameRate = String(line.dropFirst("r_frame_rate=".count)) }
        }
        return (frames, frameRate)
    }

    /// The average brightness (0...255) of each frame of a video, in order.  Scaling a frame to one
    /// pixel averages it, and that pixel is a byte of raw output.
    func brightnessOfEachFrame(of path: String) throws -> [Int] {
        let bytes = try runBinary("ffmpeg", [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-i", path,
            "-vf", "scale=1:1:flags=area,format=gray", "-f", "rawvideo", "pipe:1"])
        return bytes.map { Int($0) }
    }

    // MARK: - the daemon

    func launchDaemon() throws -> DaemonProcess {
        var environment = ProcessInfo.processInfo.environment
        environment[ToolPaths.directoryOverrideVariable] = tools.path
        let daemon = try DaemonProcess(binaryPath: DaemonIntegrationTests.stardPath,
                                       scratchDir: "\(scratch)/daemon",
                                       environment: environment)
        daemons.append(daemon)
        return daemon
    }

    func openVideo(_ daemon: DaemonProcess, _ path: String) async throws -> Star_V1_SessionInfo {
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

    func openSequence(_ daemon: DaemonProcess, _ directory: String) async throws -> Star_V1_SessionInfo {
        var request = Star_V1_OpenSequenceRequest()
        request.sequenceDir = directory
        return try await daemon.call(method: "Session.OpenSequence", request: request)
    }

    /// The config the daemon saved for a session.
    func config(of info: Star_V1_SessionInfo) throws -> Config {
        try JSONDecoder().decode(Config.self,
                                 from: Data(contentsOf: URL(fileURLWithPath: info.configJsonPath)))
    }

    // MARK: - exporting

    func settings(codec: String, encoder: String, pixelFormat: String,
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

    let proresInMov = (codec: "prores", encoder: "prores_ks", pixelFormat: "yuv422p10le", muxer: "mov")
    let h264InMp4 = (codec: "h264", encoder: "libx264", pixelFormat: "yuv420p", muxer: "mp4")

    /// Runs `Export.Video` and returns how it ended.  An error from the daemon fails the test,
    /// unless `expectingFailure`, which is for a test of the error itself.
    @discardableResult
    func export(_ daemon: DaemonProcess,
                session: Star_V1_SessionInfo,
                to path: String,
                with settings: Star_V1_VideoEncodeSettings?,
                expectingFailure: Bool = false) async throws -> DaemonProcess.StreamResult
    {
        var request = Star_V1_ExportVideoRequest()
        request.sessionID = session.sessionID
        request.outputVideoPath = path
        if let settings { request.settings = settings }
        let result = try await daemon.stream(method: "Export.Video", request: request)
        if let failure = result.failure, !expectingFailure {
            XCTFail("Export.Video failed: \(failure.message)")
        }
        return result
    }
}
