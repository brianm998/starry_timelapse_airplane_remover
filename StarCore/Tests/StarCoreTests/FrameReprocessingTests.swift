import XCTest
import Foundation
@testable import StarCore

/// What `FrameAirplaneRemover.resetForReprocessing` throws away for each `FrameReprocessingType`.
///
/// The macOS gui and the daemon behind the Kotlin client both call it, so these pin the contract
/// the two used to disagree on: `.none` deletes nothing (the daemon deleted every output),
/// `.horizons` deletes only the horizon images (the daemon deleted the outputs), and
/// `.everything` deletes the aligned and subtraction images too (the daemon kept them).
final class FrameReprocessingTests: FrameHarnessTestCase {

    private let outputs: [FrameViewMode] = [.final, .validation]
    private let alignmentWork: [FrameViewMode] = [.starAligned, .subtraction]
    private let horizonImages: [FrameViewMode] = [.horizon, .mergedHorizon]

    private func plantEverything(_ h: FrameHarness) async throws {
        let image = FrameHarness.syntheticFrame(width: 16, height: 12, horizonRow: 6)
        for type in outputs + alignmentWork + horizonImages {
            try h.plantImage(image, ofType: type)
        }
        let dir = await h.frame.outliersDirname
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for name in [BlobBinarySaver.outlierBinaryFilename, BlobBinarySaver.trashBinaryFilename] {
            FileManager.default.createFile(atPath: "\(dir)/\(name)", contents: Data([0]))
        }
        await h.frame.set(state: .complete)
    }

    private func exists(_ h: FrameHarness, _ type: FrameViewMode) -> Bool {
        h.imageAccessor.imageExists(frameIndex: 0, ofType: type, atSize: .original)
    }

    private func outliersExist(_ h: FrameHarness) async -> Bool {
        let dir = await h.frame.outliersDirname
        return FileManager.default.fileExists(atPath: "\(dir)/\(BlobBinarySaver.outlierBinaryFilename)")
            || FileManager.default.fileExists(atPath: "\(dir)/\(BlobBinarySaver.trashBinaryFilename)")
    }

    func testNoneDeletesNothingAndKeepsTheFrameDone() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "reproc-none")
        harness = h
        try await plantEverything(h)

        await h.frame.resetForReprocessing(.none)

        for type in outputs + alignmentWork + horizonImages {
            XCTAssertTrue(exists(h, type), "\(type) was deleted by a reprocess that redoes nothing")
        }
        let outliers = await outliersExist(h)
        XCTAssertTrue(outliers)
        let state = await h.frame.processingState()
        XCTAssertEqual(state, .complete)
    }

    func testHorizonsDeletesOnlyTheHorizonImages() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "reproc-horizons")
        harness = h
        try await plantEverything(h)

        await h.frame.resetForReprocessing(.horizons)

        for type in horizonImages { XCTAssertFalse(exists(h, type), "\(type) survived") }
        for type in outputs + alignmentWork { XCTAssertTrue(exists(h, type), "\(type) was deleted") }
        let outliers = await outliersExist(h)
        XCTAssertTrue(outliers)
        let state = await h.frame.processingState()
        XCTAssertEqual(state, .complete)
    }

    func testAllHorizonsLeavesTheFrameAlone() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "reproc-allhorizons")
        harness = h
        try await plantEverything(h)

        await h.frame.resetForReprocessing(.allHorizons)

        for type in outputs + alignmentWork + horizonImages { XCTAssertTrue(exists(h, type)) }
        let state = await h.frame.processingState()
        XCTAssertEqual(state, .complete)
    }

    func testOutliersKeepsAlignmentButClearsOutputsAndOutliers() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "reproc-outliers")
        harness = h
        try await plantEverything(h)

        await h.frame.resetForReprocessing(.outliers)

        for type in outputs { XCTAssertFalse(exists(h, type), "\(type) survived") }
        for type in alignmentWork { XCTAssertTrue(exists(h, type), "\(type) was deleted") }
        let outliers = await outliersExist(h)
        XCTAssertFalse(outliers)
        let state = await h.frame.processingState()
        XCTAssertEqual(state, .unprocessed)
    }

    func testAlignmentAlsoClearsTheAlignedAndSubtractionImages() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "reproc-alignment")
        harness = h
        try await plantEverything(h)

        await h.frame.resetForReprocessing(.alignment)

        for type in outputs + alignmentWork { XCTAssertFalse(exists(h, type), "\(type) survived") }
        let outliers = await outliersExist(h)
        XCTAssertFalse(outliers)
        let state = await h.frame.processingState()
        XCTAssertEqual(state, .unprocessed)
    }

    func testEverythingClearsAllWorkButNotTheOriginal() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "reproc-everything")
        harness = h
        try await plantEverything(h)

        await h.frame.resetForReprocessing(.everything)

        for type in outputs + alignmentWork + horizonImages {
            XCTAssertFalse(exists(h, type), "\(type) survived")
        }
        XCTAssertTrue(exists(h, .original), "the original frame must never be deleted")
        let outliers = await outliersExist(h)
        XCTAssertFalse(outliers)
        let state = await h.frame.processingState()
        XCTAssertEqual(state, .unprocessed)
    }
}
