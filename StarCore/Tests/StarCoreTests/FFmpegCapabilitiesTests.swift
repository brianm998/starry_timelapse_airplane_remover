import XCTest
@testable import StarCore

/// Narrowing the encoder tables to what this ffmpeg has and this machine can start.
///
/// Driven by a fake ffmpeg, so these say what happens on a machine with an NVIDIA GPU and no
/// Apple media engine, and the reverse, without either.
final class FFmpegCapabilitiesTests: XCTestCase {

    /// The shape of `ffmpeg -encoders`: a legend, a separator, then six flag characters and a name.
    private let listing = """
      Encoders:
       V..... = Video
       A..... = Audio
       S..... = Subtitle
       .F.... = Frame-level multithreading
       ..S... = Slice-level multithreading
       ...X.. = Codec is experimental
       ....B. = Supports draw_horiz_band
       .....D = Supports direct rendering method 1
       ------
       V....D libx264              libx264 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10 (codec h264)
       V....D h264_videotoolbox    VideoToolbox H.264 Encoder (codec h264)
       V....D h264_nvenc           NVIDIA NVENC H.264 encoder (codec h264)
       V....D hevc_nvenc           NVIDIA NVENC hevc encoder (codec hevc)
       VFS... prores_ks            Apple ProRes (iCodec Pro) (codec prores)
       A....D aac                  AAC (Advanced Audio Coding)
       S..... srt                  SubRip subtitle (codec subrip)
      """

    /// A fake ffmpeg that answers `-encoders` with `listing` and starts only the encoders named
    /// in `working`, remembering every call.
    private final class FakeFFmpeg: @unchecked Sendable {
        let listing: String
        let working: Set<String>
        private let lock = NSLock()
        private var recorded: [[String]] = []

        init(listing: String, working: Set<String>) {
            self.listing = listing
            self.working = working
        }

        var calls: [[String]] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }

        /// The encoders that were tried, by their `-c:v`.
        var probed: [String] {
            calls.compactMap { arguments in
                arguments.firstIndex(of: "-c:v").map { arguments[$0 + 1] }
            }.sorted()
        }

        func run(_ arguments: [String]) -> (status: Int32, output: String)? {
            lock.lock()
            recorded.append(arguments)
            lock.unlock()

            if arguments.contains("-encoders") { return (0, listing) }
            if let index = arguments.firstIndex(of: "-c:v"), working.contains(arguments[index + 1]) {
                return (0, "")
            }
            return (1, "Cannot load libcuda.so.1")
        }

        var runner: FFmpegCapabilities.Runner {
            { [self] arguments in run(arguments) }
        }
    }

    // MARK: - reading the listing

    func testEncoderNamesAreReadFromTheTableOnly() {
        let names = FFmpegCapabilities.encoderNames(inListing: listing)
        XCTAssertEqual(names, ["libx264", "h264_videotoolbox", "h264_nvenc", "hevc_nvenc", "prores_ks", "aac", "srt"])
        XCTAssertFalse(names.contains("Video"), "the legend is not an encoder")
        XCTAssertFalse(names.contains("="), "the legend is not an encoder")
    }

    func testAnEmptyOrUnrecognisedListingHasNoNames() {
        XCTAssertTrue(FFmpegCapabilities.encoderNames(inListing: "").isEmpty)
        XCTAssertTrue(FFmpegCapabilities.encoderNames(inListing: "ffmpeg: command not found").isEmpty)
    }

    // MARK: - what is usable

    func testASoftwareEncoderIsUsableIfAndOnlyIfFFmpegHasIt() {
        let capabilities = FFmpegCapabilities(runner: FakeFFmpeg(listing: listing, working: []).runner)
        XCTAssertTrue(capabilities.isUsable(.libx264))
        XCTAssertTrue(capabilities.isUsable(.prores_ks))
        XCTAssertFalse(capabilities.isUsable(.libx265), "listed nowhere, so this ffmpeg has no libx265")
        XCTAssertFalse(capabilities.isUsable(.libsvtav1))
    }

    /// The case this exists for: NVENC is in the Windows ffmpeg whether or not the PC has an
    /// NVIDIA GPU, and VideoToolbox is in the Mac one.
    func testAHardwareEncoderNeedsTheHardware() {
        let capabilities = FFmpegCapabilities(
          runner: FakeFFmpeg(listing: listing, working: ["h264_videotoolbox"]).runner)
        XCTAssertTrue(capabilities.isUsable(.h264_videotoolbox), "listed, and it started")
        XCTAssertFalse(capabilities.isUsable(.h264_nvenc), "listed, but there is no NVIDIA GPU to start it on")
        XCTAssertFalse(capabilities.isUsable(.hevc_nvenc))
        XCTAssertFalse(capabilities.isUsable(.h264_amf), "not in this ffmpeg at all")
    }

    func testAWorkingGPUMakesItsEncodersUsable() {
        let capabilities = FFmpegCapabilities(
          runner: FakeFFmpeg(listing: listing, working: ["h264_nvenc", "hevc_nvenc"]).runner)
        XCTAssertTrue(capabilities.isUsable(.h264_nvenc))
        XCTAssertTrue(capabilities.isUsable(.hevc_nvenc))
        XCTAssertFalse(capabilities.isUsable(.h264_videotoolbox))
    }

    // MARK: - when ffmpeg cannot be asked

    /// Nothing is filtered: the tables are the best information there is, and the export that
    /// follows will say what is really wrong.
    func testWithNoRunnableFFmpegEverythingIsUsable() {
        let capabilities = FFmpegCapabilities(runner: { _ in nil })
        XCTAssertTrue(capabilities.isUsable(.libx264))
        XCTAssertTrue(capabilities.isUsable(.h264_nvenc))
        XCTAssertTrue(capabilities.isUsable(.libx265))
    }

    func testWithAFailingListingEverythingIsUsable() {
        let capabilities = FFmpegCapabilities(runner: { _ in (1, "Bad CPU type in executable") })
        XCTAssertTrue(capabilities.isUsable(.libx265))
        XCTAssertTrue(capabilities.isUsable(.h264_nvenc))
    }

    // MARK: - how it probes

    /// Started once each, however often it is asked and from however many threads.
    func testEachEncoderIsProbedOnceNoMatterHowOftenOrWhoAsks() {
        let fake = FakeFFmpeg(listing: listing, working: ["h264_videotoolbox"])
        let capabilities = FFmpegCapabilities(runner: fake.runner)

        DispatchQueue.concurrentPerform(iterations: 40) { _ in
            _ = capabilities.isUsable(.libx264)
            _ = capabilities.isUsable(.h264_nvenc)
            _ = capabilities.isUsable(.h264_videotoolbox)
        }

        XCTAssertEqual(fake.calls.filter { $0.contains("-encoders") }.count, 1)
        XCTAssertEqual(fake.probed, ["h264_nvenc", "h264_videotoolbox", "hevc_nvenc"],
                       "each hardware encoder in the listing, once, and no software ones")
    }

    func testAProbeEncodesAFewBlackFramesToNowhereWithASoftwarePixelFormat() throws {
        let fake = FakeFFmpeg(listing: listing, working: [])
        _ = FFmpegCapabilities(runner: fake.runner).isUsable(.libx264)

        let probe = try XCTUnwrap(fake.calls.first { $0.contains("h264_videotoolbox") })
        XCTAssertTrue(probe.contains("-nostdin"))
        XCTAssertTrue(probe.contains("lavfi"))
        XCTAssertEqual(Array(probe.suffix(3)), ["-f", "null", "-"], "the output goes nowhere")

        let format = probe[probe.firstIndex(of: "-pix_fmt")! + 1]
        let pixelFormat = try XCTUnwrap(FFmpegPixelFormat(rawValue: format))
        XCTAssertFalse(pixelFormat.isHardwareAccelrated, "probed with \(format)")
        XCTAssertTrue(FFmpegEncoder.h264_videotoolbox.usablePixelFormats.contains(pixelFormat))
    }
}
