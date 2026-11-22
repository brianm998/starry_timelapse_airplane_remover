import XCTest
import AppKit
import StarCore
import StarCppBridge
@testable import Star

/// Which frames hold full outlier groups: the current one plus or minus a radius, and the grid selection.
@MainActor
final class OutlierWindowTests: XCTestCase {
    private func sequence(frames count: Int) -> ImageSequenceViewModel {
        var config = Config()
        config.useGPUForMerge = false
        let manager = ConfigManager(configFilename: NSTemporaryDirectory() + "c851-\(UUID().uuidString).json",
                                    config: config)
        let model = ImageSequenceViewModel(viewModel: nil, configManager: manager, trashLevel: 0.5, smallTrashMax: 0)
        model.set(numberOfFrames: count)
        return model
    }

    func testWindowIsCurrentPlusOrMinusRadius() {
        let model = sequence(frames: 100)
        let r = ImageSequenceViewModel.outlierWindowRadius
        XCTAssertGreaterThanOrEqual(r, 2, "neighbours of a loaded frame must stay loaded")
        model.currentIndex = 50
        XCTAssertEqual(model.outlierWindowIndices, Set((50 - r)...(50 + r)))
        XCTAssertLessThan(model.outlierWindowIndices.count, 100)
    }

    func testWindowClampsAtTheEndsAndIncludesSelection() {
        let model = sequence(frames: 100)
        let r = ImageSequenceViewModel.outlierWindowRadius
        model.currentIndex = 0
        XCTAssertEqual(model.outlierWindowIndices, Set(0...r))
        model.selectedFrameIndices = [0, 90, 91]
        XCTAssertEqual(model.outlierWindowIndices, Set(0...r).union([90, 91]))
    }

    // MARK: - a processed fixture

    private struct Fixture {
        let model: ImageSequenceViewModel
        let frames: [FrameAirplaneRemover]
        let dir: URL
    }

    private func group(id: UInt16, at origin: Int, frameIndex: Int) -> OutlierGroup {
        let bounds = BoundingBox(min: Coord(x: origin, y: origin), max: Coord(x: origin + 3, y: origin + 3))
        var pixelSet: Set<SortablePixel> = []
        for y in origin..<(origin + 4) { for x in origin..<(origin + 4) {
            pixelSet.insert(SortablePixel(x: x, y: y, value: .sixteenBit(1000)))
        } }
        return OutlierGroup(id: id, size: 16, brightness: 1000, bounds: bounds, frameIndex: frameIndex,
                            imageWidth: 32, imageHeight: 24,
                            pixels: [UInt16](repeating: 1000, count: 16), pixelSet: pixelSet)
    }

    /// `count` real frames, each with three stored outlier groups (keep, remove, undecided), attached
    /// to a view model that has not loaded any groups yet.
    private func fixture(count: Int) async throws -> Fixture {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ow851-\(UUID().uuidString)")
        let seqDir = dir.appendingPathComponent("seq")
        try FileManager.default.createDirectory(at: seqDir, withIntermediateDirectories: true)
        for i in 0..<count {
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
        config.useGPUForMerge = false
        let imageSequence = try ImageSequence(dirname: seqDir.path, supportedImageFileTypes: [".tiff"])
        let filenames = await imageSequence.filenames
        let imageInfo = try await imageSequence.getImageInfo()
        config.set(imageInfo: imageInfo)
        let manager = ConfigManager(configFilename: dir.appendingPathComponent("c.json").path, config: config)
        var names: [Int: String] = [:]
        for (i, f) in filenames.enumerated() { names[i] = removePath(fromString: f) }
        let accessor = ImageAccessor(config: config, imageSequence: imageSequence, frameIndexToBaseNameMap: names)

        var frames: [FrameAirplaneRemover] = []
        for i in 0..<count {
            let frame = try await FrameAirplaneRemover(
              with: manager, initialConfig: config,
              width: imageInfo.imageWidth, height: imageInfo.imageHeight,
              componentsPerPixel: imageInfo.componentsPerPixel, callbacks: Callbacks(),
              imageSequence: imageSequence, atIndex: i,
              outputFilename: "\(config.outputPath)/\(config.basename)",
              baseName: names[i] ?? "frame_\(i)", writeOutputFiles: false, imageAccessor: accessor)
            frames.append(frame)
        }
        for (i, frame) in frames.enumerated() {
            if i > 0 { await frame.setPreviousFrame(frames[i - 1]) }
            if i < frames.count - 1 { await frame.setNextFrame(frames[i + 1]) }
        }

        // the stored results of a processed sequence
        for (i, frame) in frames.enumerated() {
            let saved = OutlierGroups(frameIndex: i, config: config)
            let a = group(id: 1, at: 2, frameIndex: i)
            let b = group(id: 2, at: 10, frameIndex: i)
            let c = group(id: 3, at: 18, frameIndex: i)
            _ = await a.shouldRemove(.userSelected(true))
            _ = await b.shouldRemove(.userSelected(false))
            await saved.add(a); await saved.add(b); await saved.add(c)
            try await saved.writeOutliersBinary(to: await frame.outliersDirname)
            try await saved.write(to: config.outlierOutputDirname)
        }

        let model = ImageSequenceViewModel(viewModel: nil, configManager: manager, trashLevel: 0.5, smallTrashMax: 0)
        model.set(numberOfFrames: count)
        for (i, frame) in frames.enumerated() { model.frames[i].frame = frame }
        return Fixture(model: model, frames: frames, dir: dir)
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func settle(_ model: ImageSequenceViewModel) async {
        model.updateOutlierWindow()
        await model.outlierWindowTask?.value
    }

    private func snapshot(_ frame: FrameAirplaneRemover) async -> [String]? {
        guard let groups = await frame.getOutlierGroups() else { return nil }
        var rows: [String] = []
        for (id, g) in await groups.members {
            rows.append("\(id) \(await g.bounds) \(String(describing: await g.shouldRemove()))")
        }
        return rows.sorted()
    }

    private func loadedFrames(_ f: Fixture) async -> Set<Int> {
        var loaded: Set<Int> = []
        for (i, frame) in f.frames.enumerated() where await frame.getOutlierGroups() != nil { loaded.insert(i) }
        return loaded
    }

    // A1 and A2
    func testOpenLoadsGroupsOnlyInTheWindowButCountsForEveryFrame() async throws {
        let f = try await fixture(count: 12)
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let r = ImageSequenceViewModel.outlierWindowRadius
        await settle(f.model)

        let loaded = await loadedFrames(f)
        XCTAssertEqual(loaded, Set(0...r), "only the window holds full groups")

        try await waitUntil("counts on every frame") {
            f.model.frames.allSatisfy { $0.frameObserver.numberOfUndecidedOutliers != nil }
        }
        for view in f.model.frames {
            XCTAssertEqual(view.frameObserver.numberOfPositiveOutliers, 1, "frame \(view.frameIndex)")
            XCTAssertEqual(view.frameObserver.numberOfNegativeOutliers, 1, "frame \(view.frameIndex)")
            XCTAssertEqual(view.frameObserver.numberOfUndecidedOutliers, 1, "frame \(view.frameIndex)")
        }
    }

    // A3
    func testMovingAwayReleasesAndReturnReloadsIdenticalGroups() async throws {
        let f = try await fixture(count: 12)
        defer { try? FileManager.default.removeItem(at: f.dir) }
        await settle(f.model)
        guard let before = await snapshot(f.frames[1]) else { return XCTFail("frame 1 should be loaded") }
        XCTAssertEqual(before.count, 3)

        f.model.currentIndex = 11
        await f.model.outlierWindowTask?.value
        let away = await snapshot(f.frames[1])
        XCTAssertNil(away, "frame 1 is outside the window and unedited")
        XCTAssertNotNil(f.model.frames[1].frameObserver.numberOfPositiveOutliers, "counts stay")

        f.model.currentIndex = 1
        await f.model.outlierWindowTask?.value
        let after = await snapshot(f.frames[1])
        XCTAssertEqual(after, before)
    }

    // A4
    func testAnEditedFrameIsNotReleased() async throws {
        let f = try await fixture(count: 12)
        defer { try? FileManager.default.removeItem(at: f.dir) }
        await settle(f.model)
        guard let groups = await f.frames[0].getOutlierGroups(),
              let g = await groups.members[1] else { return XCTFail("frame 0 should be loaded") }
        _ = await g.shouldRemove(.userSelected(false))
        await f.frames[0].markAsChanged()
        guard let edited = await snapshot(f.frames[0]) else { return XCTFail("frame 0 should be loaded") }

        f.model.currentIndex = 11
        await f.model.outlierWindowTask?.value
        let kept = await snapshot(f.frames[0])
        XCTAssertEqual(kept, edited, "an unsaved edit survives moving away")

        f.model.currentIndex = 0
        await f.model.outlierWindowTask?.value
        let back = await snapshot(f.frames[0])
        XCTAssertEqual(back, edited)
    }

    // the selection is part of the window: selecting a far frame loads it, deselecting releases it
    func testSelectingAFarFrameLoadsItsGroups() async throws {
        let f = try await fixture(count: 12)
        defer { try? FileManager.default.removeItem(at: f.dir) }
        await settle(f.model)
        let r = ImageSequenceViewModel.outlierWindowRadius
        let notYet = await snapshot(f.frames[10])
        XCTAssertNil(notYet)

        f.model.selectedFrameIndices = [0, 10]
        await f.model.outlierWindowTask?.value
        let selected = await snapshot(f.frames[10])
        XCTAssertEqual(selected?.count, 3, "a selected frame outside the window loads its groups")
        let loaded = await loadedFrames(f)
        XCTAssertEqual(loaded, Set(0...r).union([10]))

        f.model.selectedFrameIndices = [0]
        await f.model.outlierWindowTask?.value
        let dropped = await snapshot(f.frames[10])
        XCTAssertNil(dropped, "a frame dropped from the selection is released")
    }

    // Decision Tree, All Frames: loads each frame with its neighbours, releases the unedited ones behind
    // it, never releases an edited frame, and leaves every frame with its counts and its stored groups.
    func testApplyTreeToAllFramesReleasesBehindAndKeepsEdits() async throws {
        let f = try await fixture(count: 12)
        defer { try? FileManager.default.removeItem(at: f.dir) }
        await settle(f.model)
        let r = ImageSequenceViewModel.outlierWindowRadius
        let stored = await snapshot(f.frames[0])

        // an unsaved user edit on a frame outside the window
        try await f.frames[8].loadOutliers(loadOnly: true)
        guard let groups = await f.frames[8].getOutlierGroups(),
              let g = await groups.members[3] else { return XCTFail("frame 8 should load") }
        _ = await g.shouldRemove(.userSelected(true))
        await f.frames[8].markAsChanged()
        guard let edited = await snapshot(f.frames[8]) else { return XCTFail("frame 8 should be loaded") }

        // the fixture's groups are below minimumClassificationSize, so the tree changes no decision
        XCTAssertGreaterThan(f.model.minimumClassificationSize, 16)
        await f.model.applyDecisionTreeToAllFrames().value
        await f.model.outlierWindowTask?.value

        let loaded = await loadedFrames(f)
        // releases happen only outside radius + 1, so the sweep's frame r + 1 stays
        XCTAssertEqual(loaded, Set(0...(r + 1)).union([8]), "frames behind the sweep are released, the edited one is not")
        let kept = await snapshot(f.frames[8])
        XCTAssertEqual(kept, edited, "the edit survives the sweep")
        for i in 0..<f.frames.count where i != 8 {
            let changed = await f.frames[i].hasChanges()
            XCTAssertFalse(changed, "frame \(i): an unchanged frame is not marked")
        }
        for view in f.model.frames {
            XCTAssertNotNil(view.frameObserver.numberOfPositiveOutliers, "frame \(view.frameIndex) keeps its counts")
        }

        // a released frame comes back with its stored groups
        f.model.currentIndex = 11
        await f.model.outlierWindowTask?.value
        let back = await snapshot(f.frames[11])
        XCTAssertEqual(back, stored,"frame 11 reloads the same stored groups")
    }
}
