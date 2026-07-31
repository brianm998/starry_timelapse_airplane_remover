import XCTest
import Foundation
@testable import StarCore

/// The harness is test infrastructure, so it needs its own tests: every later test that uses it
/// assumes a `FrameAirplaneRemover` that is genuinely wired up, and a harness that quietly built a
/// frame with no neighbours, or a config with zero image dimensions, would make those tests pass
/// against a configuration the real pipeline never produces.
final class FrameHarnessTests: FrameHarnessTestCase {

    // MARK: - the frame is really constructed

    func testAHarnessBuildsTheRequestedNumberOfFrames() async throws {
        let h = try await FrameHarness.make(frameCount: 4, named: "count")
        harness = h
        XCTAssertEqual(h.frames.count, 4)
        for (index, frame) in h.frames.enumerated() {
            XCTAssertEqual(frame.frameIndex, index,
                           "frame index must match position — ImageSequence sorts by filename, so " +
                           "unpadded names would scramble this")
        }
    }

    func testTheFrameCarriesTheImageDimensions() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 96, height: 64, named: "dims")
        harness = h
        XCTAssertEqual(h.frame.width, 96)
        XCTAssertEqual(h.frame.height, 64)
        XCTAssertEqual(h.frame.componentsPerPixel, 3)
    }

    /// The whole reason `Processor.readImageInfo` exists: with these left at zero every op's
    /// `estimatedMemoryBytes` is zero, `reserve()` is skipped and the keypoint limiter falls back.
    /// A harness that skipped this step would exercise a configuration that never occurs in a run.
    func testTheConfigHasImageInfoApplied() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 96, height: 64, named: "info")
        harness = h
        let config = await h.configManager.config()
        XCTAssertEqual(config.imageWidth, 96)
        XCTAssertEqual(config.imageHeight, 64)
        XCTAssertGreaterThan(config.imageBytesPerPixel, 0)
        XCTAssertEqual(config.imageBitsPerComponent, 16,
                       "frames are written 16 bit — the C++ depth conversions are depth sensitive")
    }

    /// Neighbour walking is how the horizon and alignment code finds other frames.  An unlinked
    /// chain takes the no-neighbour path everywhere, silently.
    func testTheFramesAreDoublyLinked() async throws {
        let h = try await FrameHarness.make(frameCount: 3, named: "linked")
        harness = h

        let firstPrev = await h.frames[0].getPreviousFrame()
        XCTAssertNil(firstPrev, "the first frame has no previous")
        let lastNext = await h.frames[2].getNextFrame()
        XCTAssertNil(lastNext, "the last frame has no next")

        let middleNext = await h.frames[1].getNextFrame()
        let middlePrev = await h.frames[1].getPreviousFrame()
        XCTAssertEqual(middleNext?.frameIndex, 2)
        XCTAssertEqual(middlePrev?.frameIndex, 0)
    }

    /// `allFrames` walks to the head of the chain and back down, which only works if the links are
    /// consistent in both directions.
    func testAllFramesWalksTheWholeChainFromAnyFrame() async throws {
        let h = try await FrameHarness.make(frameCount: 4, named: "walk")
        harness = h
        let fromMiddle = await h.frames[2].allFrames
        XCTAssertEqual(fromMiddle.count, 4)
        var indices: [Int] = []
        for frame in fromMiddle { indices.append(frame.frameIndex) }
        XCTAssertEqual(indices, [0, 1, 2, 3])
    }

    /// A fresh scratch tree has no final image and no outlier file, so the frame must start
    /// unprocessed — the two filesystem probes in `init` are what decide this, and a stale temp dir
    /// leaking between runs would show up here as `.complete`.
    func testAFreshFrameStartsUnprocessed() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "state")
        harness = h
        let state = await h.frame.processingState()
        XCTAssertEqual(state, .unprocessed)
        let hasChanges = await h.frame.hasChanges()
        XCTAssertFalse(hasChanges)
    }

    func testEachFrameHasItsOwnBaseName() async throws {
        let h = try await FrameHarness.make(frameCount: 3, named: "basenames")
        harness = h
        var names: [String] = []
        for frame in h.frames { names.append(await frame.baseName) }
        XCTAssertEqual(names, ["frame_000.tiff", "frame_001.tiff", "frame_002.tiff"])
        XCTAssertEqual(Set(names).count, 3)
    }

    /// The three sub-processors are what the later tests actually drive, and each holds a *weak*
    /// back-reference to the frame set in `init`.  If that reference were nil every method on them
    /// would take its guard-and-return path.
    func testTheSubProcessorsSeeTheirFrame() async throws {
        let h = try await FrameHarness.make(frameCount: 2, named: "subprocessors")
        harness = h

        let horizonProcessor = await h.frame.horizonProcessor
        let horizonFrame = await horizonProcessor.frame
        XCTAssertNotNil(horizonFrame, "the horizon processor lost its weak frame reference")
        XCTAssertEqual(horizonFrame?.frameIndex, 0)

        let outlierProcessor = await h.frame.outlierProcessor
        let alignmentProcessor = await h.frame.alignmentProcessor
        XCTAssertEqual(horizonProcessor.frameIndex, 0)
        XCTAssertEqual(outlierProcessor.frameIndex, 0)
        XCTAssertEqual(alignmentProcessor.frameIndex, 0)
    }

    // MARK: - the frames on disk

    /// The frames must be loadable back through the normal path, at the depth they were written —
    /// this is the assumption every test that reads a frame image rests on.
    func testTheWrittenFramesLoadBackAtTheRightDepth() async throws {
        let h = try await FrameHarness.make(frameCount: 2, width: 64, height: 48, named: "disk")
        harness = h
        let filenames = await h.imageSequence.filenames
        let image = try await h.imageSequence.getImage(withName: filenames[0]).image()
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
        XCTAssertEqual(image.componentsPerPixel, 3)
        XCTAssertEqual(image.bitsPerComponent, 16)
    }

    /// Consecutive frames must differ.  The alignment code diffs neighbours; byte-identical frames
    /// would make every diff zero and hide whatever the diff is meant to find.
    func testConsecutiveFramesAreNotIdentical() async throws {
        let h = try await FrameHarness.make(frameCount: 2, width: 64, height: 48, named: "differ")
        harness = h
        let filenames = await h.imageSequence.filenames
        let first = try await h.imageSequence.getImage(withName: filenames[0]).image()
        let second = try await h.imageSequence.getImage(withName: filenames[1]).image()

        var differences = 0
        for y in stride(from: 0, to: 48, by: 4) {
            for x in stride(from: 0, to: 64, by: 4) {
                if first.intensity(atX: x, andY: y) != second.intensity(atX: x, andY: y) {
                    differences += 1
                }
            }
        }
        XCTAssertGreaterThan(differences, 0, "neighbouring frames must not be byte identical")
    }

    /// The same seed must give the same image, or a failure in a detector test would not reproduce.
    func testTheSyntheticFrameIsDeterministic() {
        let a = FrameHarness.syntheticFrame(width: 32, height: 32, horizonRow: 16, seed: 7)
        let b = FrameHarness.syntheticFrame(width: 32, height: 32, horizonRow: 16, seed: 7)
        for y in 0..<32 {
            for x in 0..<32 {
                XCTAssertEqual(a.intensity(atX: x, andY: y), b.intensity(atX: x, andY: y),
                               "seeded generation must be reproducible at (\(x),\(y))")
            }
        }
    }

    /// Sky brighter than ground is the premise every intensity-based detector relies on.
    func testTheSyntheticFrameHasABrightSkyOverDarkGround() {
        let image = FrameHarness.syntheticFrame(width: 64, height: 64, horizonRow: 32, seed: 0)

        var skyTotal = 0, groundTotal = 0
        for y in 4..<28 {          // clear of the horizon and of the star rows
            for x in 0..<64 { skyTotal += Int(image.intensity(atX: x, andY: y)) }
        }
        for y in 36..<60 {
            for x in 0..<64 { groundTotal += Int(image.intensity(atX: x, andY: y)) }
        }
        XCTAssertGreaterThan(skyTotal, groundTotal * 2,
                            "the sky must be clearly brighter than the ground")
    }

    /// The gradient is deliberate: a uniform sky over uniform ground gives the gradient and texture
    /// detectors nothing to disagree about, so the confidence weighting never gets exercised.
    func testTheSkyHasAVerticalGradient() {
        let image = FrameHarness.syntheticFrame(width: 64, height: 96, horizonRow: 64, seed: 0)
        func rowMean(_ y: Int) -> Double {
            var total = 0
            for x in 0..<64 { total += Int(image.intensity(atX: x, andY: y)) }
            return Double(total) / 64
        }
        // rows chosen away from the star rows near the top
        XCTAssertGreaterThan(rowMean(20), rowMean(55),
                            "the sky brightens towards the top")
    }

    /// A moving-camera sequence is what the homography paths are for, so the harness has to be able
    /// to produce one — the horizon has to actually be in a different place per frame.
    func testAShiftedSequenceMovesTheHorizonPerFrame() async throws {
        let h = try await FrameHarness.make(frameCount: 3, width: 64, height: 96,
                                           horizonRow: 40, shiftPerFrame: 6, named: "shift")
        harness = h
        let filenames = await h.imageSequence.filenames

        var boundaries: [Int] = []
        for filename in filenames {
            let image = try await h.imageSequence.getImage(withName: filename).image()
            // First row whose mean drops into ground territory.  `intensity` sums all three
            // channels, so the scale is 3x per-channel: the darkest sky row is ~44000 and the
            // brightest ground row ~24000, which puts the boundary comfortably either side of 30000.
            var found = -1
            for y in 0..<96 {
                var total = 0
                for x in 0..<64 { total += Int(image.intensity(atX: x, andY: y)) }
                if total / 64 < 30000 { found = y; break }
            }
            boundaries.append(found)
        }
        XCTAssertEqual(boundaries, [40, 46, 52],
                       "each frame's horizon must sit shiftPerFrame rows lower than the last")
    }

    // MARK: - masks

    /// White above, black below — the convention the whole horizon stack assumes.
    func testTheSyntheticMaskFollowsTheWhiteIsSkyConvention() {
        let mask = FrameHarness.flatMask(width: 16, height: 16, at: 8)
        XCTAssertEqual(mask.componentsPerPixel, 1)
        XCTAssertEqual(mask.bitsPerComponent, 8)
        XCTAssertEqual(mask.intensity(atX: 8, andY: 0), 255, "the top is sky, so white")
        XCTAssertEqual(mask.intensity(atX: 8, andY: 7), 255, "the last sky row")
        XCTAssertEqual(mask.intensity(atX: 8, andY: 8), 0, "the first ground row")
        XCTAssertEqual(mask.intensity(atX: 8, andY: 15), 0)
    }

    func testASlopedMaskFollowsItsPerColumnBoundary() {
        let mask = FrameHarness.syntheticMask(width: 32, height: 32) { x in 4 + x / 4 }
        for x in stride(from: 0, to: 32, by: 4) {
            let boundary = 4 + x / 4
            XCTAssertEqual(mask.intensity(atX: x, andY: boundary - 1), 255)
            XCTAssertEqual(mask.intensity(atX: x, andY: boundary), 0)
        }
    }

    /// The mask has to survive being wrapped as a `HorizonMask`, which is how it reaches every
    /// consumer — and the bounds it computes have to match the row it was built with.
    func testASyntheticMaskWrapsAsAHorizonMask() throws {
        let mask = FrameHarness.flatMask(width: 64, height: 64, at: 30)
        let horizon = try XCTUnwrap(HorizonMask(mask))
        // topY is the larger number — the first ground row — despite the name
        XCTAssertEqual(horizon.horizonTopY, 30)
        XCTAssertEqual(horizon.horizonBottomY, 29)
    }

    // MARK: - the scratch tree

    /// `ImageAccessor.init` makes every directory the config names; the harness depends on that, and
    /// on the tree being inside `root` so `cleanUp` really removes it.
    func testTheOutputTreeIsCreatedUnderRoot() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "tree")
        harness = h
        let dir = try XCTUnwrap(h.imageAccessor.dirForImage(ofType: .original, atSize: .original))
        XCTAssertTrue(dir.hasPrefix(h.root.path),
                      "every output directory must live under the harness root so cleanUp removes it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.config.tempOutputPath))
    }

    func testCleanUpRemovesEverything() async throws {
        let h = try await FrameHarness.make(frameCount: 2, named: "cleanup")
        let path = h.root.path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        h.cleanUp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "a leaked tree makes the next run's frame look already processed")
    }

    /// Two harnesses must not share a tree — the output paths derive from the sequence dir name, and
    /// collisions would have one test's output satisfy another's "does this exist" probe.
    func testTwoHarnessesDoNotShareATree() async throws {
        let first = try await FrameHarness.make(frameCount: 1, named: "iso")
        defer { first.cleanUp() }
        let second = try await FrameHarness.make(frameCount: 1, named: "iso")
        defer { second.cleanUp() }
        XCTAssertNotEqual(first.root.path, second.root.path)
        XCTAssertNotEqual(first.config.tempOutputPath, second.config.tempOutputPath)
    }

    func testWriteScratchProducesALoadableFile() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "scratch")
        harness = h
        let path = h.writeScratch(FrameHarness.flatMask(width: 32, height: 32, at: 16),
                                  named: "mask.tiff")
        let loaded = try XCTUnwrap(PixelatedImage(filename: path))
        XCTAssertEqual(loaded.width, 32)
        XCTAssertEqual(loaded.height, 32)
        XCTAssertTrue(path.hasPrefix(h.root.path))
    }
}
