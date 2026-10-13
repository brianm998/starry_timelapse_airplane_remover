import XCTest
import StarCore
import StarDaemonMessages
@testable import stard

/// The two decisions `Export.Video` makes before it runs ffmpeg: which encode settings to use and
/// whether the video's own sound goes back in, and where the file goes.
///
/// `ExportVideoAudioTests` runs the whole export through the real daemon and ffmpeg, and skips on a
/// machine that has built neither.  These are the same decisions with nothing to build.
final class ExportVideoSettingsTests: XCTestCase {

    // MARK: - fixtures

    /// What the Render Video dialog sends: all five settings, chosen from its pickers.
    private func request(codec: String = "prores", encoder: String = "prores_ks",
                         pixelFormat: String = "yuv422p10le", muxer: String = "mov")
      -> Star_V1_VideoEncodeSettings
    {
        var settings = Star_V1_VideoEncodeSettings()
        settings.frameRate = 24
        settings.codec = codec
        settings.encoder = encoder
        settings.pixelFormat = pixelFormat
        settings.muxer = muxer
        return settings
    }

    /// The settings a video was opened with: nothing like the request's, so that which of the two a
    /// result came from can be told.
    private func opened(hasAudio: Bool) -> VideoInfo {
        VideoInfo(frameRate: .fps_30, codec: .mpeg4, encoder: .mpeg4,
                  pixelFormat: .yuv420p, muxer: .mp4, hasAudio: hasAudio)
    }

    private func config(hasAudio: Bool) -> Config {
        var config = Config()
        config.frameRate = .fps_30
        config.codec = .mpeg4
        config.encoder = .mpeg4
        config.pixelFormat = .yuv420p
        config.muxer = .mp4
        config.hasAudio = hasAudio
        return config
    }

    // MARK: - the sound

    /// The reported failure.  The request carried settings, the settings were read as "no sound",
    /// and the export of a video that had some came out silent.
    func testARequestWithSettingsKeepsTheSoundTheVideoCameInWith() {
        let info = ExportHandlers.videoInfo(for: request(), opened: opened(hasAudio: true),
                                            config: config(hasAudio: true))

        XCTAssertTrue(info.hasAudio)
        // and the settings are still the request's, not the video's own
        XCTAssertEqual(info.codec, .prores)
        XCTAssertEqual(info.encoder, .prores_ks)
        XCTAssertEqual(info.pixelFormat, .yuv422p10le)
        XCTAssertEqual(info.muxer, .mov)
        XCTAssertEqual(info.frameRate, .fps_24)
    }

    func testARequestWithSettingsDoesNotGiveSoundToAVideoThatHadNone() {
        let info = ExportHandlers.videoInfo(for: request(), opened: opened(hasAudio: false),
                                            config: config(hasAudio: false))

        XCTAssertFalse(info.hasAudio)
        XCTAssertEqual(info.codec, .prores)
    }

    /// A session resumed from its config.json was not opened from a video, so there is no VideoInfo,
    /// but the config recorded the sound when the video was first opened.
    func testASessionResumedFromItsConfigKnowsAboutTheSoundFromTheConfig() {
        let info = ExportHandlers.videoInfo(for: request(), opened: nil, config: config(hasAudio: true))

        XCTAssertTrue(info.hasAudio)
        XCTAssertEqual(info.codec, .prores, "the request's settings")
    }

    func testASessionResumedFromItsConfigDoesNotInventSound() {
        let info = ExportHandlers.videoInfo(for: request(), opened: nil, config: config(hasAudio: false))

        XCTAssertFalse(info.hasAudio)
    }

    // MARK: - the settings

    /// An empty request (no codec) is the client saying "as the video was", which is what the
    /// session was opened with.
    func testARequestWithNoSettingsUsesTheOnesTheVideoWasOpenedWith() {
        let info = ExportHandlers.videoInfo(for: Star_V1_VideoEncodeSettings(),
                                            opened: opened(hasAudio: true), config: config(hasAudio: true))

        XCTAssertEqual(info.codec, .mpeg4)
        XCTAssertEqual(info.muxer, .mp4)
        XCTAssertEqual(info.frameRate, .fps_30)
        XCTAssertTrue(info.hasAudio)
    }

    func testARequestWithNoSettingsOnASessionWithNoVideoUsesTheConfigs() {
        let info = ExportHandlers.videoInfo(for: Star_V1_VideoEncodeSettings(),
                                            opened: nil, config: config(hasAudio: true))

        XCTAssertEqual(info.codec, .mpeg4)
        XCTAssertEqual(info.pixelFormat, .yuv420p)
        XCTAssertTrue(info.hasAudio)
    }

    /// Settings the daemon cannot read (a client built against other tables) are no settings, and
    /// the video still has the sound it had.
    func testARequestThatCannotBeReadFallsBackToTheVideosOwnSettingsAndKeepsItsSound() {
        let info = ExportHandlers.videoInfo(for: request(codec: "no-such-codec"),
                                            opened: opened(hasAudio: true), config: config(hasAudio: true))

        XCTAssertEqual(info.codec, .mpeg4)
        XCTAssertTrue(info.hasAudio)
    }

    // MARK: - the file

    /// A client that says where to write is believed, even if the extension and the muxer disagree:
    /// the file is where it said, in the container it chose (the arguments name it with `-f`, and the
    /// sound is planned for the same one).
    func testAPathTheClientGivesIsUsedAsItIs() {
        let path = ExportHandlers.outputVideoPath(requested: "/Users/someone/Movies/timelapse.mkv",
                                                  config: config(hasAudio: false), muxer: .mov)

        XCTAssertEqual(path, "/Users/someone/Movies/timelapse.mkv")
    }

    /// The Render Video dialog sends none.  The protocol says the daemon names the file after the
    /// sequence and the muxer, and the Mac app's dialog does the same, beside the rendered frames.
    func testWithNoPathTheFileIsNamedAfterTheSequenceBesideItsFrames() {
        var config = config(hasAudio: false)
        config.outputPath = "/scratch/session/output"
        config.imageSequenceDirname = "night-sky"

        let path = ExportHandlers.outputVideoPath(requested: "", config: config, muxer: .mov)

        XCTAssertEqual(path, "/scratch/session/output/\(config.basename).mov")
        XCTAssertTrue(config.basename.hasPrefix("night-sky-star-v-"),
                      "the name is the sequence's, as in the Mac app: \(config.basename)")
        // beside the folder of frames a render makes, not inside it
        XCTAssertEqual(URL(fileURLWithPath: path).deletingLastPathComponent().path,
                       "/scratch/session/output")
    }

    /// Matroska's muxer is called `matroska` and its files are `.mkv`; a file named `.matroska`
    /// opens in nothing.
    func testTheDefaultNameEndsInTheMuxersFileExtensionNotItsName() {
        var config = config(hasAudio: false)
        config.outputPath = "/out"

        let path = ExportHandlers.outputVideoPath(requested: "", config: config, muxer: .matroska)

        XCTAssertTrue(path.hasSuffix(".mkv"), path)
    }

    // MARK: - telling the client where the video went

    /// The desktop's dialog asks for no path, so what it shows afterwards is what the daemon says.
    func testTheVideoExportedEventCarriesTheVideosPath() throws {
        let event = ExportHandlers.videoExportedEvent(path: "/Users/someone/night sky-star-v-0_11_5.mov")

        guard case .videoExported(let exported)? = event.kind else {
            return XCTFail("expected a video_exported event, got \(String(describing: event.kind))")
        }
        XCTAssertEqual(exported.outputVideoPath, "/Users/someone/night sky-star-v-0_11_5.mov")
        // and it survives the wire
        let decoded = try Star_V1_ProgressEvent(serializedBytes: try event.serializedData())
        XCTAssertEqual(decoded, event)
    }

    /// A relative path means somewhere under the daemon's working directory, which a client cannot
    /// know, so it is said as the place it really is.
    func testARelativePathIsReportedAsTheAbsolutePathItIs() {
        let event = ExportHandlers.videoExportedEvent(path: "renders/clip.mov")

        XCTAssertEqual(event.videoExported.outputVideoPath,
                       "\(FileManager.default.currentDirectoryPath)/renders/clip.mov")
    }

    /// The bytes the daemon sends, written out: the same bytes are parsed by the desktop client's
    /// test, so a change to the field numbers breaks both sides' tests and not just one of them.
    /// `3A 08` is field 7 (`video_exported`) holding 8 bytes; `0A 06` is field 1 (the path) of 6.
    func testTheVideoExportedEventHasTheBytesTheDesktopClientParses() throws {
        let event = ExportHandlers.videoExportedEvent(path: "/x.mov")

        XCTAssertEqual(Array(try event.serializedData()),
                       [0x3A, 0x08, 0x0A, 0x06, 0x2F, 0x78, 0x2E, 0x6D, 0x6F, 0x76])
    }
}
