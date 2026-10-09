import XCTest
import StarCore
@testable import stard

/// `Export.Video` used to point ffmpeg at `<outputPath>/image_%04d.tiff`.  Nothing writes a file
/// there: processing puts each final frame in `<outputPath>/<sequence>-star-v-<version>/` under
/// the source frame's own name (`LRT_00080.tif`), so every export failed with ffmpeg's "Could
/// find no file with path" — found when the desktop self-test first exported a processed
/// sequence.  These pin where the frames are looked for and what ffmpeg is told about them.
final class VideoExportTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VideoExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    private func config(sequence: String = "seq", outputPath: String? = nil) -> Config {
        Config(
          outputPath: outputPath ?? tempDir.appendingPathComponent("out").path,
          imageSequenceName: sequence,
          imageSequencePath: tempDir.path,
          writeOutlierGroupFiles: false,
          writeFramePreviewFiles: false,
          writeFrameProcessedPreviewFiles: false,
          writeFrameThumbnailFiles: false
        )
    }

    private func videoInfo(
        frameRate: FrameRate = .fps_24,
        encoder: FFmpegEncoder? = .prores,
        muxer: FFmpegMuxer = .mov,
        hasAudio: Bool = false
    ) -> VideoInfo {
        VideoInfo(frameRate: frameRate, codec: .prores, encoder: encoder,
                  pixelFormat: .yuv444p10le, muxer: muxer, hasAudio: hasAudio)
    }

    // MARK: - where the frames are

    /// The files have to be looked for exactly where StarCore's own naming says processing put
    /// them, so this asks the real `ImageAccessor` for the final frame's name, writes a file
    /// there, and checks the export finds it.
    func testFindsTheFramesWhereProcessingWritesThem() throws {
        let sourceDir = tempDir.appendingPathComponent("seq")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let names = ["LRT_00080.tif", "LRT_00081.tif", "LRT_00082.tif"]
        let config = config()

        let accessor = ImageAccessor(
          config: config,
          imageSequence: try ImageSequence(dirname: sourceDir.path, supportedImageFileTypes: [".tif"]),
          frameIndexToBaseNameMap: Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0, $1) })
        )
        var written: [String] = []
        for index in names.indices {
            let path = try XCTUnwrap(accessor.nameForImage(frameIndex: index, ofType: .final, atSize: .original))
            try FileManager.default.createDirectory(
              atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data("frame".utf8).write(to: URL(fileURLWithPath: path))
            written.append(path)
        }

        let found = VideoExport.finalFrames(
          outputDir: config.outputSequenceDirname,
          sourceFilenames: names.map { "\(sourceDir.path)/\($0)" }
        )

        XCTAssertEqual(found.files, written)
        XCTAssertTrue(found.missing.isEmpty)
        XCTAssertTrue(found.files[0].contains("/seq-star-v-"), "the frames sit in a directory named after the sequence")
    }

    /// A video import's decoded frames are `image_0001.tiff` upward, in a directory named after
    /// the video, and its output frames keep those names.
    func testAVideoImportsFramesAreFoundByTheirDecodedNames() throws {
        let outputDir = tempDir.appendingPathComponent("out/clip-star-v-1").path
        let names = (1...3).map { String(format: "image_%04d.tiff", $0) }
        let found = VideoExport.finalFrames(
          outputDir: outputDir,
          sourceFilenames: names.map { "/videos/clip/\($0)" },
          fileExists: { _ in true }
        )
        XCTAssertEqual(found.files, names.map { "\(outputDir)/\($0)" })
    }

    func testFramesStayInFrameOrderWhateverTheirNumbering() {
        // the numbers need not start at 1 or be contiguous
        let sources = ["/s/IMG_0007.tif", "/s/IMG_0010.tif", "/s/IMG_0200.tif"]
        let found = VideoExport.finalFrames(outputDir: "/o", sourceFilenames: sources, fileExists: { _ in true })
        XCTAssertEqual(found.files, ["/o/IMG_0007.tif", "/o/IMG_0010.tif", "/o/IMG_0200.tif"])
    }

    func testFramesNotYetWrittenAreReportedAndLeftOut() {
        let sources = ["/s/a.tif", "/s/b.tif", "/s/c.tif"]
        let found = VideoExport.finalFrames(outputDir: "/o", sourceFilenames: sources,
                                            fileExists: { $0 != "/o/b.tif" })
        XCTAssertEqual(found.files, ["/o/a.tif", "/o/c.tif"])
        XCTAssertEqual(found.missing, ["b.tif"])
    }

    func testAnEmptyOutputDirectoryHasNoFrames() {
        let found = VideoExport.finalFrames(outputDir: tempDir.path, sourceFilenames: ["/s/a.tif"])
        XCTAssertTrue(found.files.isEmpty)
        XCTAssertEqual(found.missing, ["a.tif"])
    }

    // MARK: - the concat list

    func testTheConcatListHoldsEveryFrameWithItsDuration() {
        let list = VideoExport.concatList(files: ["/o/a.tif", "/o/b.tif"], frameRate: .fps_25)
        XCTAssertEqual(list, """
            ffconcat version 1.0
            file '/o/a.tif'
            option framerate 25
            duration 0.040000000
            file '/o/b.tif'
            option framerate 25
            duration 0.040000000

            """)
    }

    /// Without `option framerate` the image demuxer gives each frame a 25 fps length, and from
    /// 29.97 fps up ffmpeg's constant-frame-rate output then duplicates frames: a 40-frame list
    /// encoded to 41 frames at 30 fps and 42 at 60.  It is the same rate in both lines, so the
    /// frame's own length and the spacing of the frames agree.
    func testEveryEntryStatesTheFrameRateToTheImageDemuxerAsWellAsTheSpacing() {
        let list = VideoExport.concatList(files: ["/o/a.tif"], frameRate: .fps_59_94)
        XCTAssertTrue(list.contains("\noption framerate 59.94\n"), list)
        XCTAssertTrue(list.contains("\nduration 0.016683350\n"), list)
    }

    func testTheDurationIsTheReciprocalOfTheFrameRate() {
        // fps_23_976 is the literal 23.976, as the gui's render passes it to ffmpeg, not 24000/1001
        let list = VideoExport.concatList(files: ["/o/a.tif"], frameRate: .fps_23_976)
        XCTAssertTrue(list.contains("duration 0.041708375"), list)
    }

    func testQuotingKeepsSpacesAndBackslashesAndEscapesQuotes() {
        XCTAssertEqual(VideoExport.quoted("/my frames/a.tif"), "'/my frames/a.tif'")
        // inside quotes a backslash is literal to ffmpeg, so a Windows path needs no escaping
        XCTAssertEqual(VideoExport.quoted(#"C:\Users\me\a.tif"#), #"'C:\Users\me\a.tif'"#)
        XCTAssertEqual(VideoExport.quoted("/it's/a.tif"), #"'/it'\''s/a.tif'"#)
    }

    // MARK: - the ffmpeg command line

    func testTheCommandLineReadsTheListAndEncodesToTheOutputPath() {
        let args = VideoExport.arguments(
          listPath: "/scratch/list.ffconcat", audioPath: nil,
          videoInfo: videoInfo(frameRate: .fps_30, encoder: .prores, muxer: .mov),
          outputVideoPath: "/o/out.mov")

        XCTAssertEqual(args, [
            "-f", "concat", "-safe", "0", "-i", "/scratch/list.ffconcat",
            "-r", "30",
            "-c:v", "prores",
            "-pix_fmt", "yuv444p10le",
            "-f", "mov", "-y", "/o/out.mov",
        ])
    }

    func testTheFrameRateIsAnOutputOptionAfterEveryInput() throws {
        let args = VideoExport.arguments(
          listPath: "/l", audioPath: "/a/audio.aac", videoInfo: videoInfo(), outputVideoPath: "/o/out.mov")
        let lastInput = try XCTUnwrap(args.lastIndex(of: "-i"))
        let rate = try XCTUnwrap(args.firstIndex(of: "-r"))
        XCTAssertGreaterThan(rate, lastInput, "before an -i, -r would be read as an input option")
    }

    func testAudioIsAddedAsASecondInputAndCopied() {
        let args = VideoExport.arguments(
          listPath: "/l", audioPath: "/a/audio.aac", videoInfo: videoInfo(hasAudio: true), outputVideoPath: "/o/out.mov")
        XCTAssertEqual(args.filter { $0 == "-i" }.count, 2)
        XCTAssertTrue(zip(args, args.dropFirst()).contains { $0 == "-i" && $1 == "/a/audio.aac" })
        XCTAssertTrue(zip(args, args.dropFirst()).contains { $0 == "-c:a" && $1 == "copy" })
    }

    func testWithoutAudioThereIsNoAudioInputOrCodec() {
        let args = VideoExport.arguments(
          listPath: "/l", audioPath: nil, videoInfo: videoInfo(), outputVideoPath: "/o/out.mov")
        XCTAssertEqual(args.filter { $0 == "-i" }.count, 1)
        XCTAssertFalse(args.contains("-c:a"))
    }

    func testWithoutAnEncoderTheCodecNamesIt() {
        let args = VideoExport.arguments(
          listPath: "/l", audioPath: nil, videoInfo: videoInfo(encoder: nil), outputVideoPath: "/o/out.mov")
        XCTAssertTrue(zip(args, args.dropFirst()).contains { $0 == "-c:v" && $1 == FFmpegCodec.prores.rawValue })
    }

    func testTheOutputPathDefaultsToTheSequenceNameInTheChosenContainer() {
        let config = config(sequence: "night", outputPath: "/o")
        XCTAssertEqual(VideoExport.defaultOutputPath(config: config, muxer: .mp4), "/o/\(config.basename).mp4")
        XCTAssertTrue(config.basename.hasPrefix("night-star-v-"))
    }
}
