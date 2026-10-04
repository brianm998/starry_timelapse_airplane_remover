import XCTest
@testable import StarCore

/// Keeping an imported video's sound, and putting it back, without ffmpeg: the decisions are what
/// is tested here (what is tried, in what order, what is left behind), against stand-ins that
/// accept or refuse whatever a test says.  VideoConvertTests runs the same code against the real
/// ffmpeg, which is what says the decisions are right about what containers accept.
final class AudioSidecarTests: XCTestCase {

    /// Not an implicitly unwrapped optional: interpolated into a path that prints as "Optional(...)".
    private var directory = ""

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
          .appendingPathComponent("AudioSidecarTests-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// A stand-in for ffmpeg and ffprobe.  `accepts` decides whether a run of ffmpeg succeeds;
    /// like the real one it writes its output file first (the last argument) and leaves it behind
    /// even when it then fails.
    private final class Stand: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        let codec: String?
        let accepts: @Sendable ([String]) -> Bool

        init(codec: String?, accepts: @escaping @Sendable ([String]) -> Bool) {
            self.codec = codec
            self.accepts = accepts
        }

        var calls: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }

        var tools: AudioSidecar.Tools {
            AudioSidecar.Tools(
              audioCodec: { [self] _ in codec },
              ffmpeg: { [self] arguments in
                  lock.lock(); recorded.append(arguments); lock.unlock()
                  let ok = accepts(arguments)
                  if let output = arguments.last {
                      FileManager.default.createFile(atPath: output, contents: ok ? Data("sound".utf8) : Data())
                  }
                  return ok
              })
        }
    }

    private func names(_ calls: [[String]]) -> [String] {
        calls.map { audioCodecOption(of: $0) ?? "?" }
    }

    private func filesLeft() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
    }

    // MARK: - importing

    func testAACIsKeptAsItIsInTheFileTheOldCodeUsed() {
        let stand = Stand(codec: "aac") { _ in true }
        XCTAssertEqual(AudioSidecar.extract(from: "in.mp4", into: directory, tools: stand.tools), "audio.aac")
        XCTAssertEqual(names(stand.calls), ["copy"], "no second attempt when the first worked")
        XCTAssertEqual(stand.calls[0].last, "\(directory)/audio.aac")
        XCTAssertEqual(filesLeft(), ["audio.aac"])
    }

    /// The reported failure: an `.aac` file holds only AAC, so anything else went to a Matroska
    /// audio file, which takes every codec.
    func testAnythingElseIsKeptUntouchedInMatroska() {
        for codec in ["pcm_s16le", "pcm_s24be", "ac3", "eac3", "flac", "opus", "alac", "mp3"] {
            let stand = Stand(codec: codec) { _ in true }
            XCTAssertEqual(AudioSidecar.extract(from: "in.mov", into: directory, tools: stand.tools), "audio.mka", codec)
            XCTAssertEqual(names(stand.calls), ["copy"], codec)
            XCTAssertEqual(stand.calls[0].last, "\(directory)/audio.mka", codec)
        }
    }

    func testTheFirstAudioStreamIsTheOneKeptAndNoVideoComesAlong() throws {
        let stand = Stand(codec: "pcm_s16le") { _ in true }
        _ = AudioSidecar.extract(from: "in.mov", into: directory, tools: stand.tools)
        let call = try XCTUnwrap(stand.calls.first)
        XCTAssertEqual(call.firstIndex(of: "-map").map { call[$0 + 1] }, "0:a:0")
        XCTAssertTrue(call.contains("-vn"))
        XCTAssertTrue(call.contains("-y"), "a sound file from an earlier import must not stop this one")
    }

    func testWhenMatroskaRefusesTheCodecItIsReEncodedToAAC() {
        let stand = Stand(codec: "adpcm_ima_qt") { call in
            !(call.last?.hasSuffix(".mka") ?? false)   // nothing but the .mka copy is refused
        }
        XCTAssertEqual(AudioSidecar.extract(from: "in.mov", into: directory, tools: stand.tools), "audio.aac")
        XCTAssertEqual(names(stand.calls), ["copy", "aac"])
        XCTAssertEqual(stand.calls[1].firstIndex(of: "-b:a").map { stand.calls[1][$0 + 1] }, "320k")
        XCTAssertEqual(filesLeft(), ["audio.aac"], "the refused attempt's empty file is cleaned up")
    }

    /// AAC that cannot be copied as ADTS is still kept, as the next best thing.
    func testAnAACStreamThatCannotBeWrittenAsADTSFallsBackToMatroska() {
        let stand = Stand(codec: "aac") { call in !(call.last?.hasSuffix(".aac") ?? false) }
        XCTAssertEqual(AudioSidecar.extract(from: "in.mp4", into: directory, tools: stand.tools), "audio.mka")
        XCTAssertEqual(names(stand.calls), ["copy", "copy"])
        XCTAssertEqual(filesLeft(), ["audio.mka"])
    }

    /// The frames are what an import is for.
    func testWhenNothingWorksTheImportGoesAheadWithoutSoundAndLeavesNothingBehind() {
        let stand = Stand(codec: "weird") { _ in false }
        XCTAssertNil(AudioSidecar.extract(from: "in.mov", into: directory, tools: stand.tools))
        XCTAssertEqual(names(stand.calls), ["copy", "aac"], "copy to Matroska, then AAC, then it gives up")
        XCTAssertEqual(filesLeft(), [], "no empty or half-written file")
        XCTAssertNil(AudioSidecar.path(in: directory))
    }

    func testAnUnidentifiableCodecIsStillTried() {
        let stand = Stand(codec: nil) { _ in true }
        XCTAssertEqual(AudioSidecar.extract(from: "in.mov", into: directory, tools: stand.tools), "audio.mka")
    }

    /// A folder that already holds the sound of something else must not lend it to this video.
    func testASoundFileFromAnEarlierImportIsRemovedFirst() throws {
        try Data("old".utf8).write(to: URL(fileURLWithPath: "\(directory)/audio.aac"))
        try Data("old".utf8).write(to: URL(fileURLWithPath: "\(directory)/audio.mka"))
        let stand = Stand(codec: "pcm_s16le") { _ in false }
        XCTAssertNil(AudioSidecar.extract(from: "in.mov", into: directory, tools: stand.tools))
        XCTAssertEqual(filesLeft(), [], "both stale files are gone, and the failed import left none of its own")
    }

    // MARK: - finding it

    func testTheSoundFileIsFoundWhicheverKindItIs() throws {
        XCTAssertNil(AudioSidecar.path(in: directory))
        try Data("x".utf8).write(to: URL(fileURLWithPath: "\(directory)/audio.aac"))
        XCTAssertEqual(AudioSidecar.path(in: directory), "\(directory)/audio.aac")
        try FileManager.default.removeItem(atPath: "\(directory)/audio.aac")
        try Data("x".utf8).write(to: URL(fileURLWithPath: "\(directory)/audio.mka"))
        XCTAssertEqual(AudioSidecar.path(in: directory), "\(directory)/audio.mka")
    }

    /// A failed ffmpeg run leaves an empty file, which is not sound.
    func testAnEmptyFileIsNotASoundFile() throws {
        FileManager.default.createFile(atPath: "\(directory)/audio.aac", contents: Data())
        FileManager.default.createFile(atPath: "\(directory)/audio.mka", contents: Data())
        XCTAssertNil(AudioSidecar.path(in: directory))
    }

    // MARK: - rendering

    private func sidecar(_ name: String = "audio.mka") throws {
        try Data("sound".utf8).write(to: URL(fileURLWithPath: "\(directory)/\(name)"))
    }

    func testWithNoSoundFileTheRenderHasNoSound() {
        let stand = Stand(codec: nil) { _ in true }
        let plan = AudioSidecar.plan(in: directory, formatArguments: ["-f", "mov"], outputExtension: "", tools: stand.tools)
        XCTAssertFalse(plan.hasAudio)
        XCTAssertEqual(plan.inputArguments, [])
        XCTAssertEqual(plan.codecArguments, [])
        XCTAssertEqual(stand.calls.count, 0, "nothing to try")
    }

    func testTheSoundIsCopiedWhereTheContainerTakesIt() throws {
        try sidecar()
        let stand = Stand(codec: "pcm_s16le") { _ in true }
        let plan = AudioSidecar.plan(in: directory, formatArguments: ["-f", "mov"], outputExtension: "", tools: stand.tools)
        XCTAssertTrue(plan.hasAudio)
        XCTAssertEqual(plan.inputArguments, ["-i", "\(directory)/audio.mka"])
        XCTAssertEqual(plan.codecArguments, ["-c:a", "copy"])
        XCTAssertEqual(names(stand.calls), ["copy"], "it stops at the first that works")
    }

    /// ffmpeg will write PCM into an MP4 and almost nothing plays it: found by running it.
    func testMP4GetsAACInsteadOfCopiedSoundItWillWriteButNothingPlays() throws {
        try sidecar()
        for codec in ["pcm_s16le", "pcm_s24le", "flac", "opus", "mp2"] {
            let stand = Stand(codec: codec) { _ in true }   // ffmpeg is happy to write all of them
            let plan = AudioSidecar.plan(in: directory, formatArguments: ["-f", "mp4"], outputExtension: "", tools: stand.tools)
            XCTAssertEqual(plan.codecArguments.prefix(2), ["-c:a", "aac"], "\(codec) in an MP4")
            XCTAssertEqual(names(stand.calls), ["aac"], "\(codec): copy is not even tried")
        }
    }

    func testMP4StillCopiesTheSoundThatPlays() throws {
        try sidecar()
        for codec in ["aac", "mp3", "ac3", "eac3", "alac"] {
            let stand = Stand(codec: codec) { _ in true }
            let plan = AudioSidecar.plan(in: directory, formatArguments: ["-f", "mp4"], outputExtension: "", tools: stand.tools)
            XCTAssertEqual(plan.codecArguments, ["-c:a", "copy"], "\(codec) in an MP4")
        }
    }

    /// The daemon does not pass `-f`: the output file's extension chooses the muxer.
    func testTheFamilyIsRecognisedFromTheExtensionWhenNoFormatIsGiven() {
        XCTAssertEqual(AudioSidecar.Container(formatArguments: [], outputExtension: "mp4"), .mp4Family)
        XCTAssertEqual(AudioSidecar.Container(formatArguments: [], outputExtension: "M4V"), .mp4Family)
        XCTAssertEqual(AudioSidecar.Container(formatArguments: [], outputExtension: "mov"), .other)
        XCTAssertEqual(AudioSidecar.Container(formatArguments: [], outputExtension: "mkv"), .other)
        XCTAssertEqual(AudioSidecar.Container(formatArguments: [], outputExtension: ""), .other)
        XCTAssertEqual(AudioSidecar.Container(formatArguments: ["-f", "ipod"], outputExtension: "mov"), .mp4Family,
                       "an explicit format beats the extension")
        XCTAssertEqual(AudioSidecar.Container(formatArguments: ["-f", "mov"], outputExtension: "mp4"), .other)
        XCTAssertEqual(AudioSidecar.Container(formatArguments: ["-f", "matroska"], outputExtension: ""), .other)
    }

    /// WebM takes Opus and Vorbis only, so AAC sound used to fail the render there.
    func testWebMGetsOpusWhenItWillTakeNothingElse() throws {
        try sidecar("audio.aac")
        let stand = Stand(codec: "aac") { call in audioCodecOption(of: call) == "opus" }
        let plan = AudioSidecar.plan(in: directory, formatArguments: ["-f", "webm"], outputExtension: "", tools: stand.tools)
        XCTAssertTrue(plan.hasAudio)
        XCTAssertEqual(plan.codecArguments.prefix(2), ["-c:a", "opus"])
        XCTAssertTrue(plan.codecArguments.contains("-strict"), "ffmpeg's own Opus encoder is still experimental")
        XCTAssertEqual(names(stand.calls), ["copy", "opus"], "AAC is not re-encoded to AAC")
        XCTAssertEqual(plan.inputArguments, ["-i", "\(directory)/audio.aac"])
    }

    func testOpusSoundIsCopiedIntoWebM() throws {
        try sidecar()
        let stand = Stand(codec: "opus") { _ in true }
        let plan = AudioSidecar.plan(in: directory, formatArguments: ["-f", "webm"], outputExtension: "", tools: stand.tools)
        XCTAssertEqual(plan.codecArguments, ["-c:a", "copy"])
    }

    /// A container that takes no sound at all gives a render without it, not a failed render.
    func testWhenNothingIsAcceptedTheRenderGoesAheadWithoutSound() throws {
        try sidecar()
        let stand = Stand(codec: "pcm_s16le") { _ in false }
        let plan = AudioSidecar.plan(in: directory, formatArguments: ["-f", "gif"], outputExtension: "", tools: stand.tools)
        XCTAssertFalse(plan.hasAudio)
        XCTAssertEqual(plan.inputArguments, [], "so no -i for a sound file the output cannot take")
        XCTAssertEqual(plan.codecArguments, [])
        XCTAssertEqual(names(stand.calls), ["copy", "aac", "opus"], "everything was tried")
        XCTAssertTrue(plan.summary.contains("no sound"), plan.summary)
    }

    func testACodecThatCouldNotBeIdentifiedIsStillCopiedFirst() throws {
        try sidecar()
        let stand = Stand(codec: nil) { _ in true }
        let plan = AudioSidecar.plan(in: directory, formatArguments: ["-f", "mp4"], outputExtension: "", tools: stand.tools)
        XCTAssertEqual(plan.codecArguments, ["-c:a", "copy"], "the trial run decides")
    }

    /// The trial writes into the output's own kind of file, from the sound file's first stream, and
    /// only a moment of it, and leaves nothing behind.
    func testTheTrialIsShortWritesTheRightKindOfFileAndCleansUp() throws {
        try sidecar()
        let stand = Stand(codec: "ac3") { _ in true }
        _ = AudioSidecar.plan(in: directory, formatArguments: [], outputExtension: "mkv", tools: stand.tools)

        let call = try XCTUnwrap(stand.calls.first)
        XCTAssertEqual(call.firstIndex(of: "-t").map { call[$0 + 1] }, "0.5")
        XCTAssertEqual(call.firstIndex(of: "-map").map { call[$0 + 1] }, "0:a:0")
        XCTAssertFalse(call.contains("-f"), "no format was asked for, so none is given")
        let output = try XCTUnwrap(call.last)
        XCTAssertTrue(output.hasSuffix(".mkv"), output)
        XCTAssertTrue(output.hasPrefix(FileManager.default.temporaryDirectory.path), output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output), "the trial file is removed")
    }

    func testTheFormatIsPassedToTheTrialAsItWillBeToTheRender() throws {
        try sidecar()
        let stand = Stand(codec: "ac3") { _ in true }
        _ = AudioSidecar.plan(in: directory, formatArguments: ["-f", "matroska"], outputExtension: "", tools: stand.tools)
        let call = try XCTUnwrap(stand.calls.first)
        XCTAssertEqual(call.firstIndex(of: "-f").map { call[$0 + 1] }, "matroska")
    }
}

/// The value of ffmpeg's `-c:a` in a call.  Free, so the stand-ins' `@Sendable` closures can use it.
private func audioCodecOption(of call: [String]) -> String? {
    call.firstIndex(of: "-c:a").map { call[$0 + 1] }
}
