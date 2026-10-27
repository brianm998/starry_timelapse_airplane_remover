import XCTest
@testable import StarCore

/// `VideoFrameSource` against the ffmpeg star ships, on small synthetic videos.  Skipped when that pair is not built.
final class VideoFrameSourceTests: XCTestCase {

    private var scratch: URL!
    private var previousOverride: String?

    private var shippedToolsDirectory: URL {
        URL(fileURLWithPath: #filePath)
          .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
          .appendingPathComponent("external_binaries").appendingPathComponent("bin")
    }

    override func setUpWithError() throws {
        let directory = shippedToolsDirectory
        let ffmpeg = directory.appendingPathComponent(ToolPaths.fileName(of: "ffmpeg")).path
        let ffprobe = directory.appendingPathComponent(ToolPaths.fileName(of: "ffprobe")).path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ffmpeg) && FileManager.default.fileExists(atPath: ffprobe),
                          "ffmpeg is not built here; run ffmpeg/build.sh --install")
        previousOverride = ProcessInfo.processInfo.environment[ToolPaths.directoryOverrideVariable]
        setenv(ToolPaths.directoryOverrideVariable, directory.path, 1)
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("VideoFrameSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let previousOverride { setenv(ToolPaths.directoryOverrideVariable, previousOverride, 1) }
        else { unsetenv(ToolPaths.directoryOverrideVariable) }
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: fixtures

    private func ffmpeg(_ arguments: [String]) throws {
        _ = try shellOut(to: ToolPaths.ffmpeg, arguments: ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"] + arguments)
    }

    /// A video in its own folder (so its frames folder is its own too).
    private func makeVideo(_ name: String, frames: Int, size: String = "640x360", filter: String? = nil,
                           container: String? = nil, codec: [String]) throws -> String {
        let folder = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = container ?? (codec.contains("libx264") || codec.contains("libx265") ? "mp4" : "mov")
        let path = folder.appendingPathComponent("clip.\(ext)").path
        var arguments = ["-f", "lavfi", "-i", "testsrc2=size=\(size):rate=24", "-frames:v", "\(frames)"]
        if let filter { arguments += ["-vf", filter] }
        try ffmpeg(arguments + codec + [path])
        return path
    }

    private func proRes(_ name: String, frames: Int, size: String = "640x360", filter: String? = nil) throws -> String {
        try makeVideo(name, frames: frames, size: size, filter: filter,
                      codec: ["-c:v", "prores_ks", "-profile:v", "0", "-pix_fmt", "yuv422p10le"])
    }

    private func h264(_ name: String, frames: Int, size: String = "640x360", gop: Int = 1000) throws -> String {
        try makeVideo(name, frames: frames, size: size, codec: ["-c:v", "libx264", "-g", "\(gop)", "-pix_fmt", "yuv420p"])
    }

    private func files(in folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasPrefix("image_") }.sorted()
    }

    private func waitUntil(_ timeout: TimeInterval = 60, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    /// A fresh full extraction of the same video content, in order, for comparing frames with.
    private func reference(of video: String, copyAs name: String, format: FrameDecodeFormat = .tiff16) async throws -> [String: Data] {
        let folder = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent((video as NSString).lastPathComponent).path
        try FileManager.default.copyItem(atPath: video, toPath: copy)
        let (directory, _) = try await decodeVideo(named: copy, format: format) { _, _, _ in }
        var result: [String: Data] = [:]
        for file in files(in: directory) { result[file] = FileManager.default.contents(atPath: "\(directory)/\(file)") }
        return result
    }

    private func processCount(containing marker: String) -> Int {
        let output = (try? shellOut(to: "/bin/ps", arguments: ["-axo", "command"])) ?? ""
        return output.split(separator: "\n").filter { $0.contains("ffmpeg") && $0.contains(marker) }.count
    }

    // MARK: classification

    func testProResAndAllIntraH264AreSeekableAndLongGOPH264IsNot() throws {
        XCTAssertEqual(VideoAccess.isIntraOnly(videoAt: try proRes("a", frames: 30)), true)
        XCTAssertEqual(VideoAccess.isIntraOnly(videoAt: try h264("b", frames: 60, gop: 1)), true,
                       "all-intra H.264 is seekable by the packet probe though its codec name says otherwise")
        XCTAssertEqual(VideoAccess.isIntraOnly(videoAt: try h264("c", frames: 60, gop: 1000)), false)
        XCTAssertEqual(VideoAccess.accessKind(videoAt: try h264("d", frames: 60), codecName: "h264"), .longGOP)
        XCTAssertEqual(VideoAccess.guess(fromCodecName: "prores"), .seekable)
        XCTAssertEqual(VideoAccess.guess(fromCodecName: "hevc"), .longGOP)
        XCTAssertEqual(VideoAccess.guess(fromCodecName: nil), .longGOP)
        let probe = try XCTUnwrap(VideoProbe.probe(videoAt: try proRes("e", frames: 24)))
        XCTAssertEqual(probe.seekable, true)
        XCTAssertTrue(probe.extractInBackgroundByDefault)
        let long = try XCTUnwrap(VideoProbe.probe(videoAt: try h264("f", frames: 24)))
        XCTAssertFalse(long.extractInBackgroundByDefault)
    }

    func testTheFrameTimesAreReadFromThePacketsAndSeekBetweenFrames() throws {
        let video = try proRes("t", frames: 24)
        let times = try XCTUnwrap(VideoFrameTimes.read(videoAt: video, expectedFrames: 24))
        XCTAssertEqual(times.count, 24)
        XCTAssertEqual(times.times[1] - times.times[0], 1.0 / 24, accuracy: 0.001)
        let seek = times.seekTime(forFrame: 10)
        XCTAssertGreaterThan(seek, times.times[9] - times.startTime)
        XCTAssertLessThan(seek, times.times[10] - times.startTime)
        XCTAssertNil(VideoFrameTimes.read(videoAt: video, expectedFrames: 99), "a table that does not match the count is not used")
    }

    // MARK: sweep

    func testTheSweepExtractsEveryFrameInOrderAndWaitingReturnsOnlyOnceTheFileIsComplete() async throws {
        let video = try h264("sweep", frames: 48)
        let source = try await VideoFrameSource.make(videoPath: video, settings: .sweepOnly)
        XCTAssertEqual(source.frameCount, 48)
        XCTAssertEqual(source.accessKind, .longGOP)

        var seen = IndexSet()
        let consumer = Task { () -> [IndexSet] in
            var batches: [IndexSet] = []
            for await event in source.events() {
                if case .framesAvailable(let set) = event { batches.append(set) }
            }
            return batches
        }
        try await source.waitUntilAvailable(47)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: source.path(forFrame: 47))[.size] as? Int)
        XCTAssertGreaterThan(size, 1000, "a frame that is available is not half written")
        XCTAssertTrue(source.isAvailable(47))
        try await source.waitUntilFinished()
        XCTAssertTrue(source.progress.isComplete)
        let batches = await consumer.value
        for batch in batches { seen.formUnion(batch) }
        XCTAssertEqual(seen, IndexSet(0..<48))
        XCTAssertEqual(files(in: source.outputFolder).count, 48)
        XCTAssertEqual(FrameExtractionSidecar.read(inFolder: source.outputFolder)?.complete, true)
        // no staging left behind
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(source.outputFolder)/.extracting"))
    }

    func testTheNonWaitingCallIsFalseBeforeAndTrueAfter() async throws {
        let video = try h264("nonwait", frames: 200, size: "1280x720")
        let source = try await VideoFrameSource.make(videoPath: video, settings: .sweepOnly)
        XCTAssertFalse(source.isAvailable(199), "the last frame cannot be there the moment extraction starts")
        XCTAssertEqual(source.availability(199), .pending)
        try await source.waitUntilFinished()
        XCTAssertTrue(source.isAvailable(199))
        XCTAssertEqual(source.availability(199), .available)
    }

    func testCancellingAWaiterLeavesTheExtractionAlone() async throws {
        let video = try h264("cancelwait", frames: 120, size: "1280x720")
        let source = try await VideoFrameSource.make(videoPath: video, settings: .sweepOnly)
        let task = Task { try await source.waitUntilAvailable(119) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { try await task.value } catch { XCTAssertTrue(error is CancellationError) }
        try await source.waitUntilFinished()
        XCTAssertTrue(source.progress.isComplete)
    }

    func testAnFFmpegFailureFailsEveryWaiterInsteadOfHangingThem() async throws {
        let folder = scratch.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let missing = folder.appendingPathComponent("nothing.mov").path
        let source = VideoFrameSource(videoPath: missing, outputFolder: folder.path, format: .tiff16, frameCount: 10,
                                      countIsExact: true, accessKind: .longGOP, times: nil, settings: .sweepOnly, digits: 4,
                                      existingFrames: IndexSet(), createdOutputFolder: false)
        source.start()
        do { try await source.waitUntilAvailable(5); XCTFail("should have failed") } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertNotNil(source.progress.error)
        do { try await source.waitUntilAvailable(7); XCTFail("should have failed") } catch {}
    }

    func testACountThatWasTooHighSettlesToTheRealOneAndFailsTheFramesBeyondIt() async throws {
        let video = try h264("short", frames: 24)
        let folder = scratch.appendingPathComponent("short").path
        let source = VideoFrameSource(videoPath: video, outputFolder: folder, format: .tiff16, frameCount: 30, countIsExact: false,
                                      accessKind: .longGOP, times: nil, settings: .sweepOnly, digits: 4,
                                      existingFrames: IndexSet(), createdOutputFolder: false)
        let beyond = Task { try await source.waitUntilAvailable(28) }
        source.start()
        do { try await beyond.value; XCTFail("a frame the video does not have cannot arrive") } catch {
            XCTAssertFalse(error is CancellationError)
        }
        try await source.waitUntilFinished()
        XCTAssertEqual(source.frameCount, 24)
        XCTAssertTrue(source.progress.isComplete)
    }

    func testACountThatWasTooLowGrowsToTheRealOne() async throws {
        let video = try h264("long", frames: 24)
        let folder = scratch.appendingPathComponent("long").path
        let source = VideoFrameSource(videoPath: video, outputFolder: folder, format: .tiff16, frameCount: 20, countIsExact: false,
                                      accessKind: .longGOP, times: nil, settings: .sweepOnly, digits: 4,
                                      existingFrames: IndexSet(), createdOutputFolder: false)
        source.start()
        try await source.waitUntilFinished()
        XCTAssertEqual(source.frameCount, 24)
        XCTAssertEqual(files(in: folder).count, 24)
    }

    // MARK: jumps

    func testASeekableJumpGetsALaterFrameLongBeforeTheSweepCouldAndItIsBitIdentical() async throws {
        let video = try proRes("jump", frames: 360, size: "1280x720")
        let source = try await VideoFrameSource.make(videoPath: video, settings: .default)
        XCTAssertEqual(source.accessKind, .seekable)
        source.prioritize([350], reason: .userViewing)
        try await source.waitUntilAvailable(350)
        let extractedWhenItLanded = source.progress.extracted
        XCTAssertLessThan(extractedWhenItLanded, 340, "the jump did not run ahead of the sweep (\(extractedWhenItLanded) frames)")
        let inode = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: source.path(forFrame: 350))[.systemFileNumber] as? Int)
        try await source.waitUntilFinished()
        XCTAssertEqual(files(in: source.outputFolder).count, 360)
        // the sweep ran into the jumped frames and left them as they were
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.path(forFrame: 350))[.systemFileNumber] as? Int, inode)

        let expected = try await reference(of: video, copyAs: "jump_reference")
        for file in files(in: source.outputFolder) {
            XCTAssertEqual(FileManager.default.contents(atPath: "\(source.outputFolder)/\(file)"), expected[file], file)
        }
        XCTAssertEqual(expected.count, 360)
    }

    func testEveryJumpedFrameMatchesAFullExtractionOnVariableFrameRateAndOffsetStartClips() async throws {
        // frames shown at uneven times, and the first one not at zero
        let filter = "setpts='(N/24+2.5+sin(N*1.7)*0.012)/TB'"
        let video = try makeVideo("vfr", frames: 120, filter: filter, container: "mkv",
                                  codec: ["-c:v", "mjpeg", "-q:v", "3", "-pix_fmt", "yuvj422p", "-fps_mode", "vfr"])
        let source = try await VideoFrameSource.make(videoPath: video, settings: .default)
        XCTAssertEqual(source.frameCount, 120)
        let wanted = [119, 100, 77, 53, 31, 9]
        for index in wanted { source.prioritize([index], reason: .pipelineSample) }
        for index in wanted { try await source.waitUntilAvailable(index) }
        try await source.waitUntilFinished()
        let expected = try await reference(of: video, copyAs: "vfr_reference")
        XCTAssertEqual(expected.count, 120)
        for file in files(in: source.outputFolder) {
            XCTAssertEqual(FileManager.default.contents(atPath: "\(source.outputFolder)/\(file)"), expected[file], file)
        }
    }

    func testALongGOPVideoJumpsOnlyForTheUsersFrameAndNotForThePipeline() async throws {
        let video = try h264("gop", frames: 480, size: "1280x720")
        let source = try await VideoFrameSource.make(videoPath: video, settings: .default)
        XCTAssertEqual(source.accessKind, .longGOP)
        source.prioritize([470], reason: .pipeline)
        source.prioritize([471], reason: .pipelineSample)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(source.isBeingJumpedTo(470))
        XCTAssertFalse(source.isBeingJumpedTo(471))
        XCTAssertLessThanOrEqual(processCount(containing: source.outputFolder), 1, "only the sweep runs for pipeline requests")

        source.prioritize([465], reason: .userViewing)
        try await source.waitUntilAvailable(465)
        XCTAssertLessThan(source.progress.extracted, 450, "the jump did not run ahead of the sweep")
        try await source.waitUntilFinished()
        let expected = try await reference(of: video, copyAs: "gop_reference")
        for file in files(in: source.outputFolder) {
            XCTAssertEqual(FileManager.default.contents(atPath: "\(source.outputFolder)/\(file)"), expected[file], file)
        }
    }

    func testAnOpenGOPHEVCJumpIsBitIdenticalToTheSweep() async throws {
        let hasX265 = ((try? shellOut(to: ToolPaths.ffmpeg, arguments: ["-hide_banner", "-encoders"])) ?? "").contains("libx265")
        try XCTSkipUnless(hasX265, "this ffmpeg has no x265")
        let video = try makeVideo("hevc", frames: 360, size: "1280x720", codec: [
          "-c:v", "libx265", "-pix_fmt", "yuv420p", "-x265-params", "open-gop=1:keyint=48:min-keyint=24:log-level=none"])
        let source = try await VideoFrameSource.make(videoPath: video, settings: .default)
        source.prioritize([300], reason: .userViewing)
        try await source.waitUntilAvailable(300)
        try await source.waitUntilFinished()
        let expected = try await reference(of: video, copyAs: "hevc_reference")
        var different: [String] = []
        for file in files(in: source.outputFolder) where FileManager.default.contents(atPath: "\(source.outputFolder)/\(file)") != expected[file] {
            different.append(file)
        }
        XCTAssertEqual(different, [], "a jumped frame must be bit-identical to the sweep's")
    }

    func testASecondViewingFrameCancelsAJumpForTheOneTheUserLeft() async throws {
        let video = try h264("replace", frames: 480, size: "1280x720")
        let source = try await VideoFrameSource.make(videoPath: video, settings: .default)
        source.prioritize([470], reason: .userViewing)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(source.isBeingJumpedTo(470))
        try await Task.sleep(nanoseconds: 200_000_000)
        source.prioritize([300], reason: .userViewing)
        let moved = await waitUntil(10) { source.isBeingJumpedTo(300) || source.isAvailable(300) }
        XCTAssertTrue(moved)
        XCTAssertFalse(source.isBeingJumpedTo(470), "the jump for the frame the user left was replaced")
        try await source.waitUntilFinished()
    }

    func testTheNumberOfFFmpegProcessesNeverExceedsTheSweepPlusTheLimit() async throws {
        let video = try proRes("limit", frames: 300, size: "1280x720")
        for limit in [0, 2] {
            let copy = scratch.appendingPathComponent("limit\(limit)")
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            let path = copy.appendingPathComponent("clip.mov").path
            try FileManager.default.copyItem(atPath: video, toPath: path)
            let source = try await VideoFrameSource.make(
              videoPath: path, settings: FrameExtractionSettings(maxJumpWorkers: limit, maxLongGOPJumpWorkers: 1))
            for index in stride(from: 290, to: 100, by: -20) { source.prioritize([index], reason: .pipelineSample) }
            var peak = 0
            while !source.progress.isComplete && peak < 100 {
                peak = max(peak, processCount(containing: source.outputFolder))
                try await Task.sleep(nanoseconds: 10_000_000)
                if source.progress.extracted >= 300 { break }
            }
            try await source.waitUntilFinished()
            XCTAssertLessThanOrEqual(peak, 1 + limit, "limit \(limit)")
            XCTAssertEqual(processCount(containing: source.outputFolder), 0, "an idle source has no ffmpeg")
        }
    }

    // MARK: resume and tiff compression

    func testAStoppedExtractionResumesFromTheFramesThatAreThere() async throws {
        let video = try h264("resume", frames: 360, size: "1280x720")
        let first = try await VideoFrameSource.make(videoPath: video, settings: .sweepOnly)
        try await first.waitUntilAvailable(40)
        first.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        let folder = first.outputFolder
        let before = files(in: folder)
        XCTAssertLessThan(before.count, 360)
        XCTAssertEqual(FrameExtractionSidecar.read(inFolder: folder)?.complete, false)
        let stamps = Dictionary(uniqueKeysWithValues: before.map { name in
            (name, (try? FileManager.default.attributesOfItem(atPath: "\(folder)/\(name)")[.systemFileNumber] as? Int) ?? -1)
        })

        let second = try await VideoFrameSource.make(videoPath: video, settings: .default)
        XCTAssertEqual(second.availableFrames.count, before.count, "what is on disk is trusted")
        try await second.waitUntilFinished()
        XCTAssertEqual(files(in: folder).count, 360)
        for (name, inode) in stamps {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: "\(folder)/\(name)")[.systemFileNumber] as? Int, inode,
                           "\(name) was rewritten")
        }
        let expected = try await reference(of: video, copyAs: "resume_reference")
        for file in files(in: folder) {
            XCTAssertEqual(FileManager.default.contents(atPath: "\(folder)/\(file)"), expected[file], file)
        }
        // and the factory sees a complete folder as an ordinary image sequence
        let opened = try await FrameSourceFactory.open(directory: folder, supportedImageFileTypes: [".tiff"])
        XCTAssertTrue(opened is DirectoryFrameSource)
    }

    func testTheFactoryResumesAnIncompleteFolderAndOpensAGoneVideoAsItIs() async throws {
        let video = try h264("factory", frames: 240, size: "1280x720")
        let first = try await VideoFrameSource.make(videoPath: video, settings: .sweepOnly)
        try await first.waitUntilAvailable(20)
        first.stop()
        try await Task.sleep(nanoseconds: 300_000_000)
        let folder = first.outputFolder
        XCTAssertFalse(FrameSourceFactory.isIncompleteAndUnresumable(directory: folder))
        let resumed = try await FrameSourceFactory.open(directory: folder, supportedImageFileTypes: [".tiff"])
        XCTAssertTrue(resumed is VideoFrameSource)
        resumed.stop()
        try await Task.sleep(nanoseconds: 300_000_000)

        try FileManager.default.removeItem(atPath: video)
        XCTAssertTrue(FrameSourceFactory.isIncompleteAndUnresumable(directory: folder))
        let asIs = try await FrameSourceFactory.open(directory: folder, supportedImageFileTypes: [".tiff"])
        XCTAssertTrue(asIs is DirectoryFrameSource)
        XCTAssertGreaterThan(asIs.frameCount, 0)
    }

    func testAFolderOfOtherImagesIsNotOverwrittenByAnImport() async throws {
        let video = try h264("clash", frames: 24)
        let folder = VideoFrameSource.outputFolder(forVideoAt: video)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(folder)/image_0001.tiff", contents: Data([1, 2, 3]))
        do { _ = try await VideoFrameSource.make(videoPath: video); XCTFail("should refuse") } catch {}
        XCTAssertEqual(FileManager.default.contents(atPath: "\(folder)/image_0001.tiff"), Data([1, 2, 3]))
    }

    /// The TIFF compression tag (259) of a file's first directory.
    private func tiffCompressionTag(of path: String) throws -> Int {
        let data = try XCTUnwrap(FileManager.default.contents(atPath: path))
        let little = data[0] == 0x49
        func u16(_ o: Int) -> Int { little ? Int(data[o]) | Int(data[o + 1]) << 8 : Int(data[o]) << 8 | Int(data[o + 1]) }
        func u32(_ o: Int) -> Int { little ? u16(o) | u16(o + 2) << 16 : u16(o) << 16 | u16(o + 2) }
        let directory = u32(4)
        for entry in 0..<u16(directory) {
            let offset = directory + 2 + entry * 12
            if u16(offset) == 259 { return u16(offset + 8) }
        }
        XCTFail("no compression tag")
        return -1
    }

    func testTIFFCompressionIsWhatTheImportAskedFor() async throws {
        let video = try h264("tiff", frames: 12)
        var sizes: [FrameDecodeFormat.TIFFCompression: Int] = [:]
        var pixels: [FrameDecodeFormat.TIFFCompression: Data] = [:]
        for compression in FrameDecodeFormat.TIFFCompression.allCases {
            let copy = scratch.appendingPathComponent("tiff_\(compression.rawValue)")
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            let path = copy.appendingPathComponent("clip.mp4").path
            try FileManager.default.copyItem(atPath: video, toPath: path)
            let (directory, _) = try await decodeVideo(
              named: path, format: FrameDecodeFormat(kind: .tiff16, tiffCompression: compression)) { _, _, _ in }
            let file = "\(directory)/image_0005.tiff"
            XCTAssertEqual(try tiffCompressionTag(of: file), compression == .none ? 1 : 32773, "\(compression)")
            sizes[compression] = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: file)[.size] as? Int)
            let image = try XCTUnwrap(PixelatedImage(filename: file))
            guard case .sixteenBit(let buffer) = image.imageData else { return XCTFail("16 bit expected") }
            pixels[compression] = Data(buffer: buffer)
        }
        XCTAssertEqual(sizes[.none], 640 * 360 * 6 + (sizes[.none]! - 640 * 360 * 6), "uncompressed is exactly the pixels plus a header")
        XCTAssertLessThan(sizes[.none]! - 640 * 360 * 6, 4096)
        XCTAssertLessThanOrEqual(sizes[.packBits]!, sizes[.none]! + sizes[.none]! / 50)
        XCTAssertEqual(pixels[.none], pixels[.packBits], "both decode to identical pixels")
    }
}
