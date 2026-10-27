import XCTest
import Foundation
import StarCppBridge
@testable import StarCore

/// The static sequence's horizon from the median of sampled frames.
///
/// The accuracy claims in `TemporalHorizonDetector`'s documentation were measured on real
/// sequences that are far too large for a test; these pin the pieces and the plumbing on
/// synthetic frames whose horizon is known.
final class TemporalHorizonDetectorTests: XCTestCase {

    private var harness: FrameHarness?

    override func tearDown() {
        harness?.cleanUp()
        harness = nil
        super.tearDown()
    }

    // MARK: - sampling

    func testShortSequencesUseEveryFrame() {
        XCTAssertEqual(TemporalHorizonDetector.sampleIndices(frameCount: 5, count: 48), [0, 1, 2, 3, 4])
        XCTAssertEqual(TemporalHorizonDetector.sampleIndices(frameCount: 0, count: 48), [])
    }

    func testLongSequencesAreSampledFromFirstToLastFrame() {
        let indices = TemporalHorizonDetector.sampleIndices(frameCount: 1434, count: 48)
        XCTAssertEqual(indices.count, 48)
        XCTAssertEqual(indices.first, 0)
        XCTAssertEqual(indices.last, 1433)
        XCTAssertEqual(indices, indices.sorted())
        XCTAssertEqual(Set(indices).count, indices.count, "no frame twice")
    }

    // MARK: - is there a ground at all?

    /// `frames` frames of `w` x `h` luminance: a static background with a little noise, and
    /// `starsPerFrame` stars that land somewhere new each frame, but only on rows
    /// `starRows` (so the rest never changes).  Returns the frames and their per-pixel median.
    private func starFrames(width w: Int, height h: Int, frames: Int, starsPerFrame: Int,
                            starRows: Range<Int>,
                            noiseFrom noisyRow: Int = Int.max,
                            noise: Double = 0) -> (frames: [[Float]], median: [Float]) {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        let background = (0..<w * h).map { Float(0.30 + 0.20 * Double($0 / w) / Double(h)) }
        var all: [[Float]] = []
        for _ in 0..<frames {
            var f = background.map { $0 + Float((next() - 0.5) * 0.08) }   // noise enough that a star's dark ring is below four sigma
            // rows from `noisyRow` down get symmetric extra noise that changes every frame
            if noisyRow < h {
                for i in (noisyRow * w)..<(h * w) { f[i] += Float((next() - 0.5) * 2 * noise) }
            }
            if starRows.count > 0 {
                for _ in 0..<starsPerFrame {
                    // a 5 x 5 blob, as a star has a profile: a single bright pixel leaves a ring
                    // of dark ones when the slow part is taken out, which is not what a star does
                    let cx = 2 + Int(next() * Double(w - 4))
                    let cy = starRows.lowerBound + 2 + Int(next() * Double(max(1, starRows.count - 4)))
                    for dy in -2...2 { for dx in -2...2 {
                        f[(cy + dy) * w + cx + dx] += Float(0.35 * exp(-Double(dx * dx + dy * dy) / 2.5))
                    } }
                }
            }
            all.append(f)
        }
        let median = (0..<w * h).map { i -> Float in
            let v = all.map { $0[i] }.sorted()
            return v[v.count / 2]
        }
        return (all, median)
    }

    func testAGroundThatNeverChangesHasNoStarActivity() throws {
        let w = 160, h = 100, edge = 60
        let (frames, median) = starFrames(width: w, height: h, frames: 12, starsPerFrame: 60,
                                          starRows: 0..<edge)
        let activity = try XCTUnwrap(TemporalHorizonDetector.groundStarActivity(
          lumas: frames, median: median, width: w, height: h,
          line: Array(repeating: edge, count: w)))
        XCTAssertLessThan(activity, 0.1, "stars only above the line: nothing moves below it")
    }

    func testAGroundFullOfMovingStarsIsAsActiveAsTheSky() throws {
        let w = 160, h = 100
        let (frames, median) = starFrames(width: w, height: h, frames: 12, starsPerFrame: 100,
                                          starRows: 0..<h)
        let activity = try XCTUnwrap(TemporalHorizonDetector.groundStarActivity(
          lumas: frames, median: median, width: w, height: h,
          line: Array(repeating: 60, count: w)))
        XCTAssertGreaterThan(activity, TemporalHorizonDetector.maxGroundStarActivity,
                             "a line through a sky that is stars all the way down is not a horizon")
        XCTAssertEqual(activity, 1, accuracy: 0.35)
    }

    func testTheActivityNeedsGroundAndSkyAndStarsToCompare() {
        let w = 160, h = 100
        let (frames, median) = starFrames(width: w, height: h, frames: 12, starsPerFrame: 60,
                                          starRows: 0..<h)
        XCTAssertNil(TemporalHorizonDetector.groundStarActivity(
          lumas: frames, median: median, width: w, height: h,
          line: Array(repeating: 99, count: w)), "no ground to speak of")
        XCTAssertNil(TemporalHorizonDetector.groundStarActivity(
          lumas: frames, median: median, width: w, height: h,
          line: Array(repeating: 2, count: w)), "no sky to speak of")
        let (quiet, quietMedian) = starFrames(width: w, height: h, frames: 12, starsPerFrame: 0,
                                              starRows: 0..<0)
        XCTAssertNil(TemporalHorizonDetector.groundStarActivity(
          lumas: quiet, median: quietMedian, width: w, height: h,
          line: Array(repeating: 60, count: w)), "no stars in the sky: nothing to measure against")
        // a handful of stars is not a sky to compare a ground with either
        let (sparse, sparseMedian) = starFrames(width: w, height: h, frames: 12, starsPerFrame: 3,
                                                starRows: 0..<h)
        XCTAssertNil(TemporalHorizonDetector.groundStarActivity(
          lumas: sparse, median: sparseMedian, width: w, height: h,
          line: Array(repeating: 60, count: w)), "too few stars to measure against")
    }

    func testANoisyGroundIsNotAGroundFullOfStars() throws {
        // a dark treeline at high ISO: far more noise than the sky's, none of it a star,
        // because noise is as often dark as bright and stars are only ever bright
        let w = 160, h = 100, edge = 60
        let (frames, median) = starFrames(width: w, height: h, frames: 12, starsPerFrame: 60,
                                          starRows: 0..<edge, noiseFrom: edge, noise: 0.08)
        let activity = try XCTUnwrap(TemporalHorizonDetector.groundStarActivity(
          lumas: frames, median: median, width: w, height: h,
          line: Array(repeating: edge, count: w)))
        XCTAssertLessThan(activity, TemporalHorizonDetector.maxGroundStarActivity)
        XCTAssertLessThan(activity, 0.2)
    }

    func testAnErrorInTheLineWithinTheMarginDoesNotCountGroundAsSky() throws {
        // stars up to row 60, the line says 62: the two rows of sky below the real edge sit
        // inside the margin and must not be read as ground full of stars
        let w = 160, h = 100
        let (frames, median) = starFrames(width: w, height: h, frames: 12, starsPerFrame: 60,
                                          starRows: 0..<60)
        let activity = try XCTUnwrap(TemporalHorizonDetector.groundStarActivity(
          lumas: frames, median: median, width: w, height: h,
          line: Array(repeating: 62, count: w)))
        XCTAssertLessThan(activity, 0.1)
    }

    // MARK: - the median

    func testTheMedianIsTakenPerPixelAndPerChannel() throws {
        func frame(_ values: [UInt16]) -> PixelatedImage {
            // 2 x 1 pixels, 3 channels
            var data = values
            return data.withUnsafeMutableBytes { bytes in
                let mat = MatWrapper(width: 2, height: 1,
                                     cvType: MatWrapper.cvType(forBitsPerComponent: 16,
                                                               componentsPerPixel: 3),
                                     bytesPerRow: 12, data: bytes.baseAddress!,
                                     takeOwnership: false)
                return PixelatedImage(mat: mat.clone())!
            }
        }
        let a = frame([10, 200, 3000, 7, 7, 7])
        let b = frame([20, 100, 1000, 9, 9, 9])
        let c = frame([30, 300, 2000, 8, 8, 8])
        let median = try XCTUnwrap(TemporalHorizonDetector.median(of: [a, b, c]))
        guard case .sixteenBit(let buffer) = median.imageData else {
            return XCTFail("the median must stay 16-bit")
        }
        XCTAssertEqual(Array(buffer), [20, 200, 2000, 8, 8, 8])
    }

    func testFramesOfDifferentSizesHaveNoMedian() {
        let small = FrameHarness.syntheticFrame(width: 16, height: 12, horizonRow: 8)
        let large = FrameHarness.syntheticFrame(width: 32, height: 24, horizonRow: 16)
        XCTAssertNil(TemporalHorizonDetector.median(of: [small, large]))
        XCTAssertNil(TemporalHorizonDetector.median(of: []))
    }

    // MARK: - scaling the answer up

    /// A working row straddling the edge reads as ground, so the line is moved up one working
    /// row before it is scaled; a column without ground stays without ground.
    func testTheLineIsScaledToTheOutputSize() {
        let line = TemporalHorizonDetector.scaled([10, 10, 20, 20], fromWidth: 4, height: 40,
                                                  toWidth: 8, height: 160)
        XCTAssertEqual(line.count, 8)
        XCTAssertEqual(line[0], 36, "(10 - 1) x 4")
        XCTAssertEqual(line[7], 76, "(20 - 1) x 4")
        let noGround = TemporalHorizonDetector.scaled([40, 40], fromWidth: 2, height: 40,
                                                      toWidth: 4, height: 80)
        XCTAssertEqual(noGround, [80, 80, 80, 80])
    }

    // MARK: - end to end

    /// A static sequence's merge, through the processor, with no per-frame detection anywhere:
    /// the mask comes back at full size with the horizon where the frames have it, and is saved
    /// as the sequence's shared mask.
    func testAStaticMergeFindsTheHorizonInTheMedianOfTheFrames() async throws {
        let h = try await FrameHarness.make(frameCount: 5, width: 128, height: 96,
                                            horizonRow: 62, named: "temporal")
        harness = h
        await h.updateConfig {
            $0.tripodHeadWasMoving = false
            $0.useTemporalStaticHorizon = true
        }
        let horizon = await h.frames[0].horizonProcessor

        let mergedOptional = try await horizon.createMergedHorizonMask()
        let merged = try XCTUnwrap(mergedOptional)
        XCTAssertEqual(merged.image.width, 128)
        XCTAssertEqual(merged.image.height, 96)
        let rows = CombinedHorizonDetector.extractHorizonY(from: merged.image).compactMap { $0 }
        XCTAssertEqual(rows.count, 128)
        let median = rows.sorted()[rows.count / 2]
        XCTAssertEqual(median, 62, accuracy: 2, "rows: \(rows)")

        for frameIndex in 0..<5 {
            XCTAssertFalse(h.frames[frameIndex].horizonMaskExistsOnDisk(),
                           "frame \(frameIndex) must not have been detected on its own")
        }
        let (referenceDir, _) = try XCTUnwrap(h.horizonReferenceDirectory())
        XCTAssertTrue(FileManager.default.fileExists(
                        atPath: referenceDir.appendingPathComponent("reference.tiff").path),
                      "the shared mask is persisted for later runs, as the vote's was")
    }

    // MARK: - moving sequences

    /// A moving frame with no references to guide it is detected on a working-size copy and
    /// answered at full size — here a frame wider than the working width, with its ground in
    /// the bottom 4%, which the old search bands could not reach at all.
    func testAMovingFrameIsDetectedAtWorkingSizeAndAnsweredAtFullSize() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 2400, height: 1200,
                                            horizonRow: 1152, named: "workingsize")
        harness = h
        await h.updateConfig { $0.tripodHeadWasMoving = true }
        let horizon = await h.frames[0].horizonProcessor

        let mask = try await horizon.loadOrCreateHorizonMask()
        XCTAssertEqual(mask.image.width, 2400)
        XCTAssertEqual(mask.image.height, 1200)
        let rows = CombinedHorizonDetector.extractHorizonY(from: mask.image).compactMap { $0 }
        XCTAssertEqual(rows.count, 2400)
        let median = rows.sorted()[rows.count / 2]
        XCTAssertEqual(median, 1152, accuracy: 6, "a working row is 1.5 full rows here")
    }

    // MARK: - stale shared masks

    /// The previous merge's `reference.tiff` is the only file in its directory.  It goes when the
    /// merged horizon is invalidated; a painted one — marked by the frame it was painted on, or by
    /// the startup flag — never does.
    func testOnlyTheMergesOwnSharedMaskIsRemovedOnInvalidation() async throws {
        var config = Config()
        config.tempOutputPath = FileManager.default.temporaryDirectory
          .appendingPathComponent("StaticReference-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: config.tempOutputPath) }
        let directory = try XCTUnwrap(config.dirForImage(ofType: .userHorizon, atSize: .original))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let reference = "\(directory)/reference.tiff"
        let mask = FrameHarness.flatMask(width: 16, height: 16, at: 8)

        // the merge's own
        XCTAssertTrue(mask.writeTIFFEncoding(toFilename: reference))
        let removedOwn = await FrameGraphBuilder.removeAutomaticStaticReference(config: config)
        XCTAssertTrue(removedOwn)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reference))

        // painted on a frame, which leaves that frame's marker beside it
        XCTAssertTrue(mask.writeTIFFEncoding(toFilename: reference))
        XCTAssertTrue(mask.writeTIFFEncoding(toFilename: "\(directory)/LRT_00001.tif"))
        let removedPainted = await FrameGraphBuilder.removeAutomaticStaticReference(config: config)
        XCTAssertFalse(removedPainted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reference))

        // painted in the startup flow, which sets the flag
        try FileManager.default.removeItem(atPath: "\(directory)/LRT_00001.tif")
        config.hasStaticReferenceHorizon = true
        let removedFlagged = await FrameGraphBuilder.removeAutomaticStaticReference(config: config)
        XCTAssertFalse(removedFlagged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reference))
    }
}
