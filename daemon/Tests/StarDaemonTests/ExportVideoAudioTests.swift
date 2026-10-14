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
final class ExportVideoAudioTests: ExportEndToEndTestCase {

    private let frameCount = 24

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
        let result = try await export(daemon, session: info, to: output,
                                      with: settings(codec: chosen.codec, encoder: chosen.encoder,
                                                     pixelFormat: chosen.pixelFormat, muxer: chosen.muxer))

        XCTAssertEqual(try reportedVideoPath(of: result), output, "the client is told where its video went")
        XCTAssertEqual(try codec(ofFirst: "v", in: output), "prores",
                       "the request's settings, not the source's, have to have been used")
        XCTAssertEqual(try codec(ofFirst: "a", in: output), "pcm_s16le",
                       "the sound the video came in with is gone from the export")
        let facts = try videoFacts(of: output)
        XCTAssertEqual(facts.frames, frameCount, "every frame is in the video")
        XCTAssertEqual(facts.frameRate, "24/1")
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
        XCTAssertEqual(try videoFacts(of: output).frames, frameCount)
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
        XCTAssertEqual(try videoFacts(of: output).frames, frameCount)
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
        let result = try await export(daemon, session: info, to: "",
                                      with: settings(codec: chosen.codec, encoder: chosen.encoder,
                                                     pixelFormat: chosen.pixelFormat, muxer: chosen.muxer))

        XCTAssertTrue(FileManager.default.fileExists(atPath: expected),
                      "expected the video at \(expected)")
        XCTAssertEqual(try reportedVideoPath(of: result), expected,
                       "asked for no path, the client has no other way to learn where the video went")
        XCTAssertEqual(try codec(ofFirst: "a", in: expected), "pcm_s16le")
    }
}
