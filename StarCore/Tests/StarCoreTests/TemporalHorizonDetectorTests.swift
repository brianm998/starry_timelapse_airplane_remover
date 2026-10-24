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
