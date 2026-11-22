import XCTest
import AppKit
import StarCore
@testable import Star

/// #837: frame pictures come from `FrameImageLoader`, never stay on a silent grey placeholder
/// (`AsyncImage` did), and the file is stat'ed and decoded off the main actor.
@MainActor
final class FrameImageLoaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
          .appendingPathComponent("FrameImageLoaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeJPEG(_ name: String, side: Int = 16) throws -> String {
        let rep = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
          samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = rep.representation(using: .jpeg, properties: [:])!
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url.path
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(done(), what)
    }

    func testFailureIsLoggedAndRecovers() async throws {
        let loader = FrameImageLoader(retryDelay: 0.2)
        var logged: [String] = []
        loader.onFailure = { logged.append($0) }
        let path = dir.appendingPathComponent("late.jpg").path

        let entry = loader.request(path: path)
        await waitUntil("fails") { entry.isFailed }
        XCTAssertTrue(logged.contains { $0.contains(path) && $0.contains("not found") }, "\(logged)")

        // the file appears; the loader's own retry finds it
        let written = try writeJPEG("late.jpg")
        XCTAssertEqual(written, path)
        await waitUntil("recovers") {
            if case .loaded = entry.phase { return true }
            return false
        }
    }

    func testRequestDoesNotTouchDiskOnMainActor() async throws {
        final class Recorder: @unchecked Sendable {
            let lock = NSLock()
            var threads: [Bool] = []
            func note() { lock.lock(); threads.append(Thread.isMainThread); lock.unlock() }
        }
        let rec = Recorder()
        let access = FrameImageLoader.FileAccess(
          modified: { p in rec.note(); return FrameImageLoader.FileAccess.live.modified(p) },
          decode: { p in rec.note(); return try FrameImageLoader.FileAccess.live.decode(p) })
        let loader = FrameImageLoader(access: access)
        let path = try writeJPEG("a.jpg")
        let entry = loader.request(path: path)
        XCTAssertTrue(rec.threads.isEmpty, "request itself must not touch the disk")
        await entry.settled()
        XCTAssertFalse(rec.threads.isEmpty)
        XCTAssertFalse(rec.threads.contains(true), "stat and decode ran on the main thread")
    }

    func testHorizonRefreshKeepsCachedImage() async throws {
        let loader = FrameImageLoader.shared
        let path = try writeJPEG("h.jpg")
        let entry = loader.request(path: path)
        await entry.settled()

        // a real frame, so refreshHorizonOverlay() gets past `guard let frame`
        let seqDir = dir.appendingPathComponent("seq")
        try FileManager.default.createDirectory(at: seqDir, withIntermediateDirectories: true)
        for i in 0..<2 {
            let rep = NSBitmapImageRep(
              bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24, bitsPerSample: 8,
              samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            try rep.representation(using: .tiff, properties: [:])!
              .write(to: seqDir.appendingPathComponent(String(format: "frame_%03d.tiff", i)))
        }
        var config = Config(
          outputPath: dir.path, imageSequenceName: "seq", imageSequencePath: dir.path,
          writeOutlierGroupFiles: false, writeFramePreviewFiles: false,
          writeFrameProcessedPreviewFiles: false, writeFrameThumbnailFiles: false)
        let imageSequence = try ImageSequence(dirname: seqDir.path, supportedImageFileTypes: [".tiff"])
        let filenames = await imageSequence.filenames
        let imageInfo = try await imageSequence.getImageInfo()
        config.set(imageInfo: imageInfo)
        let manager = ConfigManager(configFilename: dir.appendingPathComponent("c.json").path, config: config)
        var names: [Int: String] = [:]
        for (i, f) in filenames.enumerated() { names[i] = removePath(fromString: f) }
        let accessor = ImageAccessor(config: config, imageSequence: imageSequence,
                                     frameIndexToBaseNameMap: names)
        let real = try await FrameAirplaneRemover(
          with: manager, initialConfig: config,
          width: imageInfo.imageWidth, height: imageInfo.imageHeight,
          componentsPerPixel: imageInfo.componentsPerPixel, callbacks: Callbacks(),
          imageSequence: imageSequence, atIndex: 0,
          outputFilename: "\(config.outputPath)/\(config.basename)",
          baseName: names[0] ?? "frame_000", writeOutputFiles: false, imageAccessor: accessor)

        let model = FrameViewModel(manager, 0)
        model.frame = real
        // let the refresh that setting `frame` starts finish, so ours is the only one in flight
        await waitUntil("initial refresh") {
            model.horizonOverlayVersion > 0 && model.appliedHorizonOverlayVersion == model.horizonOverlayVersion
        }

        let before = loader.requestCount(forPath: path)
        let total = loader.totalRequests
        let reload = model.reloadID
        let versionBefore = model.horizonOverlayVersion
        model.refreshHorizonOverlay()
        XCTAssertEqual(model.horizonOverlayVersion, versionBefore + 1, "refresh must have run, not returned at the nil-frame guard")
        await waitUntil("refresh applied") {
            model.appliedHorizonOverlayVersion == model.horizonOverlayVersion
        }
        XCTAssertEqual(model.reloadID, reload, "a horizon refresh must not signal a picture reload")
        XCTAssertEqual(loader.requestCount(forPath: path), before)
        XCTAssertEqual(loader.totalRequests, total)
        if case .loaded = entry.phase {} else { XCTFail("picture dropped") }
    }

    func testDeduplicatesAndBoundsMemory() async throws {
        // each 64x64 picture is 16 KB decoded; room for two
        let loader = FrameImageLoader(byteBudget: 40_000)
        let paths = try (0..<5).map { try writeJPEG("p\($0).jpg", side: 64) }

        let first = loader.request(path: paths[0])
        let second = loader.request(path: paths[0])
        XCTAssertTrue(first === second)
        await first.settled()
        loader.request(path: paths[0])
        await first.settled()
        XCTAssertEqual(loader.decodeCount, 1, "same key, same modification time: one decode")

        for p in paths.dropFirst() {
            await loader.request(path: p).settled()
        }
        XCTAssertLessThanOrEqual(loader.cachedBytes, 40_000)
        XCTAssertNil(loader.peek(paths[0]), "least recently used goes first")
        XCTAssertNotNil(loader.peek(paths[4]))
    }
}
