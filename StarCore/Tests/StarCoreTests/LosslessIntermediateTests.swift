import XCTest
import Foundation
import StarCppBridge
@testable import StarCore

/// Every full-size intermediate star writes is lossless whatever the source format.  The
/// writers choose their encoder from the file extension, and the extension used to be the
/// source frame's, so a JPEG sequence cached lossy JPEGs of its aligned merges, subtraction
/// and horizon masks.  These run over a small JPEG sequence.
final class LosslessIntermediateTests: FrameHarnessTestCase {

    private func makeJpegHarness(frameCount: Int = 2) async throws -> FrameHarness {
        let harness = try await FrameHarness.make(
          frameCount: frameCount, width: 64, height: 64,
          frameWriter: { index in Self.eightBitNoise(width: 64, height: 64, channels: 3, seed: index) },
          sourceExtension: "jpg",
          named: "lossless")
        self.harness = harness
        return harness
    }

    /// Deterministic 8-bit noise: the worst case for JPEG, which cannot reproduce it.
    static func eightBitNoise(width: Int, height: Int, channels: Int, seed: Int) -> PixelatedImage {
        let count = width * height * channels
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        var state = UInt32(truncatingIfNeeded: seed &* 2654435761 &+ 12345)
        for i in 0..<count {
            state = state &* 1664525 &+ 1013904223
            data[i] = UInt8(truncatingIfNeeded: state >> 24)
        }
        let mat = MatWrapper(width: width, height: height,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 8,
                                                       componentsPerPixel: Int32(channels)),
                             bytesPerRow: width * channels,
                             data: UnsafeMutableRawPointer(data),
                             takeOwnership: true)
        return PixelatedImage(mat: mat)!
    }

    static func sixteenBitNoise(width: Int, height: Int, seed: Int) -> PixelatedImage {
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: width * height)
        var state = UInt32(truncatingIfNeeded: seed &* 2654435761 &+ 777)
        for i in 0..<(width * height) {
            state = state &* 1664525 &+ 1013904223
            data[i] = UInt16(truncatingIfNeeded: state >> 12)
        }
        let mat = MatWrapper(width: width, height: height,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 16,
                                                       componentsPerPixel: 1),
                             bytesPerRow: width * 2,
                             data: UnsafeMutableRawPointer(data),
                             takeOwnership: true)
        return PixelatedImage(mat: mat)!
    }

    private func pixels(_ image: PixelatedImage) -> [UInt16] {
        switch image.imageData {
        case .eightBit(let buffer): return buffer.map { UInt16($0) }
        case .sixteenBit(let buffer): return Array(buffer)
        case .thirtyTwoBit(let buffer): return buffer.map { UInt16(truncatingIfNeeded: $0) }
        }
    }

    private func isTiff(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = [UInt8](handle.readData(ofLength: 4))
        return head == [0x49, 0x49, 0x2A, 0x00] || head == [0x4D, 0x4D, 0x00, 0x2A]
    }

    // MARK: - A1

    func testJpegSequenceWritesTiffCaches() async throws {
        let h = try await makeJpegHarness()
        let types: [FrameViewMode] = [.horizon, .mergedHorizon, .consensusHorizon,
                                      .starAligned, .failedStarAligned, .earthAligned,
                                      .failedEarthAligned, .subtraction, .validation, .removeMask]
        for type in types {
            XCTAssertTrue(type.isLosslessIntermediate, "\(type)")
            let isMask = type.isHorizonMask
            let image = isMask
              ? Self.eightBitNoise(width: 64, height: 64, channels: 1, seed: 3)
              : (type == .subtraction
                   ? Self.sixteenBitNoise(width: 64, height: 64, seed: 5)
                   : Self.eightBitNoise(width: 64, height: 64, channels: 3, seed: 4))
            try await h.imageAccessor.save(image, frameIndex: 0, as: type,
                                           atSize: .original, overwrite: true)
            let path = try XCTUnwrap(h.imageAccessor.nameForImage(frameIndex: 0, ofType: type,
                                                                  atSize: .original))
            XCTAssertTrue(path.hasSuffix("/frame_000.tif"), "\(type) is named \(path)")
            XCTAssertTrue(isTiff(path), "\(type) at \(path) is not a TIFF")
            let back = try await h.imageAccessor.load(frameIndex: 0, type: type, atSize: .original)
            XCTAssertEqual(pixels(try XCTUnwrap(back)), pixels(image),
                           "\(type) did not read back bit-identical")
        }
        // outputs and originals keep the source's name
        for type in [FrameViewMode.original, .final, .autoProcessed, .dirtyProcessed] {
            XCTAssertFalse(type.isLosslessIntermediate)
            let path = h.imageAccessor.nameForImage(frameIndex: 0, ofType: type, atSize: .original)
            XCTAssertEqual(path.map { ($0 as NSString).pathExtension }, "jpg", "\(type)")
        }
        // previews stay JPEG
        let preview = h.imageAccessor.nameForImage(frameIndex: 0, ofType: .starAligned, atSize: .preview)
        XCTAssertTrue(preview?.hasSuffix(".jpg") ?? false)
    }

    func testTiffSequenceNamesAreUnchanged() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "tiffnames")
        harness = h
        let path = h.imageAccessor.nameForImage(frameIndex: 0, ofType: .starAligned, atSize: .original)
        XCTAssertTrue(path?.hasSuffix("/frame_000.tiff") ?? false, "\(String(describing: path))")
    }

    /// A TIFF replaces the old JPEG-named cache, which would otherwise pile up.
    func testWritingATiffCacheRemovesTheOldJpegCache() async throws {
        let h = try await makeJpegHarness()
        let dir = try XCTUnwrap(h.config.dirForImage(ofType: .starAligned, atSize: .original))
        let legacy = "\(dir)/frame_000.jpg"
        Self.eightBitNoise(width: 64, height: 64, channels: 3, seed: 1).saveJpeg(withQuality: 95, filename: legacy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy))
        // a cache with only a legacy file is not reused: it is rebuilt
        XCTAssertFalse(h.imageAccessor.imageExists(frameIndex: 0, ofType: .starAligned, atSize: .original))

        try await h.imageAccessor.save(Self.eightBitNoise(width: 64, height: 64, channels: 3, seed: 2),
                                       frameIndex: 0, as: .starAligned, atSize: .original, overwrite: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy))
        XCTAssertTrue(h.imageAccessor.imageExists(frameIndex: 0, ofType: .starAligned, atSize: .original))
    }

    // MARK: - A2

    /// Outlier detection reloads the subtraction image first.  Planted at 16 bits, it came back
    /// from a `.jpg` as 8 bits and the stage threw it away; now it is read exactly, and two
    /// passes over it give the same groups.
    func testOutlierReprocessIsDeterministic() async throws {
        let h = try await makeJpegHarness(frameCount: 1)
        let width = 64, height = 64
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: width * height)
        for i in 0..<(width * height) { data[i] = 0 }
        for x in 8..<56 { for dy in 0..<3 { data[(30 + dy) * width + x] = UInt16(20000 + 400 * ((x * 7 + dy) % 5)) } }
        let mat = MatWrapper(width: width, height: height,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 16, componentsPerPixel: 1),
                             bytesPerRow: width * 2,
                             data: UnsafeMutableRawPointer(data), takeOwnership: true)
        let subtraction = try XCTUnwrap(PixelatedImage(mat: mat))
        try await h.imageAccessor.save(subtraction, frameIndex: 0, as: .subtraction,
                                       atSize: .original, overwrite: true)

        let loaded = try await h.imageAccessor.load(frameIndex: 0, type: .subtraction, atSize: .original)
        XCTAssertEqual(pixels(try XCTUnwrap(loaded)), pixels(subtraction))

        func groups() async throws -> [[Int32]] {
            let frame = h.frames[0]
            let config = await h.configManager.config()
            let processor = config.detectionType.blobProcessor
            let blobs = try await processor.process(frame: frame)
            var result: [[Int32]] = []
            for blob in blobs.values {
                var ids: [Int32] = []
                for pixel in await blob.pixels { ids.append(Int32(pixel.y * width + pixel.x)) }
                ids.sort()
                result.append(ids)
            }
            result.sort { ($0.first ?? 0) < ($1.first ?? 0) }
            return result
        }
        let first = try await groups()
        let second = try await groups()
        XCTAssertFalse(first.isEmpty, "the planted streak produced no blob at all")
        XCTAssertEqual(first, second)
    }

    // MARK: - A3

    /// A reference painted before this change is named after the source frame, `.jpg` and all.
    func testLegacyPaintedReferenceStillLoads() async throws {
        let h = try await makeJpegHarness()
        let (directory, _) = try XCTUnwrap(h.horizonReferenceDirectory())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mask = FrameHarness.flatMask(width: 64, height: 64, at: 20)
        let legacy = directory.appendingPathComponent("frame_000.jpg").path
        XCTAssertTrue(mask.saveJpeg(withQuality: 95, filename: legacy))

        XCTAssertEqual(h.imageAccessor.referenceFileName(frameIndex: 0), "frame_000.tif")
        XCTAssertEqual(h.imageAccessor.referenceFileNames(frameIndex: 0), ["frame_000.tif", "frame_000.jpg"])
        XCTAssertTrue(h.frames[0].horizonReferenceExistsOnDisk())
        let hasReference = await h.frames[0].horizonProcessor.hasHorizonReference
        XCTAssertTrue(hasReference)
        XCTAssertTrue(h.imageAccessor.imageExists(frameIndex: 0, ofType: .userHorizon, atSize: .original))
        XCTAssertEqual(h.imageAccessor.nameForImage(frameIndex: 0, ofType: .userHorizon, atSize: .original), legacy)
        let columns = await h.frames[0].horizonProcessor.paintedReferenceColumns()
        let row = try XCTUnwrap(columns?.compactMap { $0 }.first)
        XCTAssertEqual(row, 20, accuracy: 2)
        XCTAssertFalse(h.frames[1].horizonReferenceExistsOnDisk())
    }

    /// The painted-type masks written by an older star are read when no TIFF exists.
    func testLegacyMergedHorizonMaskIsStillRead() async throws {
        let h = try await makeJpegHarness()
        let dir = try XCTUnwrap(h.config.dirForImage(ofType: .mergedHorizon, atSize: .original))
        let legacy = "\(dir)/frame_000.jpg"
        XCTAssertTrue(FrameHarness.flatMask(width: 64, height: 64, at: 30).saveJpeg(withQuality: 95, filename: legacy))
        XCTAssertEqual(h.imageAccessor.nameForImage(frameIndex: 0, ofType: .mergedHorizon, atSize: .original), legacy)
        XCTAssertTrue(h.frames[0].mergedHorizonMaskExistsOnDisk())
        // deleting removes it, so a stale stage really is rebuilt
        try h.imageAccessor.deleteImage(frameIndex: 0, ofType: .mergedHorizon, atSize: .original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy))
    }
}
