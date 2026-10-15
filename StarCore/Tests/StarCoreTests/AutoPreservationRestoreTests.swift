import XCTest
import Foundation
import StarCppBridge
@testable import StarCore

/// `.automatic(true)` ("Selective Auto Clean", what the startup wizard picks for "remove airplanes
/// and satellites, keep meteors"): the output is the auto image, every outlier already removed, with
/// the original pixels put back over the groups decided keep.
///
/// Two bugs, both reproduced with the cli on test_data/test_a7sii_10 (2026-10-14):
///
///  * the restore covered the groups decided REMOVE, so every airplane the classifier found came
///    back — on frame LRT_00092 13,769 of 14,369 pixels in the remove mask equalled the input;
///  * any 8-bit sequence (every JPEG one) trapped in `PixelatedImage.readPixel` reading the 8-bit
///    original, so `-c automatic:true` died with SIGILL at the first frame with a remove decision.
///
/// These run the real `finishAuto(useOutliers: true)` against a planted auto image, so the
/// decision handling, the depth conversions and the written file are all exercised.
final class AutoPreservationRestoreTests: FrameHarnessTestCase {

    private let width = 128
    private let height = 96

    // Frame 1, not 0: building the harness reads frame 0 for the image info, which can cache it,
    // and these tests replace the frame's file on disk.
    private let frameIndex = 1

    private func flatImage(bits: Int32, value: UInt16) -> PixelatedImage {
        let components = 3
        let count = width * height * components
        let mat: MatWrapper
        if bits == 8 {
            let data = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
            data.initialize(repeating: UInt8(value), count: count)
            mat = MatWrapper(width: width, height: height,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 3),
                             bytesPerRow: width * components,
                             data: UnsafeMutableRawPointer(data), takeOwnership: true)
        } else {
            let data = UnsafeMutablePointer<UInt16>.allocate(capacity: count)
            data.initialize(repeating: value, count: count)
            mat = MatWrapper(width: width, height: height,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 16, componentsPerPixel: 3),
                             bytesPerRow: width * components * 2,
                             data: UnsafeMutableRawPointer(data), takeOwnership: true)
        }
        return PixelatedImage(mat: mat)!
    }

    private func group(id: UInt16, x: Int, y: Int) -> OutlierGroup {
        let size = 4
        let bounds = BoundingBox(min: Coord(x: x, y: y), max: Coord(x: x + size - 1, y: y + size - 1))
        var pixelSet: Set<SortablePixel> = []
        var pixels = [UInt16](repeating: 0, count: size * size)
        for ly in 0..<size { for lx in 0..<size {
            pixels[ly * size + lx] = 1000
            pixelSet.insert(SortablePixel(x: x + lx, y: y + ly, value: .sixteenBit(1000)))
        } }
        return OutlierGroup(id: id, size: UInt(size * size), brightness: 1000, bounds: bounds,
                            frameIndex: frameIndex, imageWidth: Double(width), imageHeight: Double(height),
                            pixels: pixels, pixelSet: pixelSet)
    }

    /// One group per kind of decision, far enough apart (> 2x the 8px paint radius) that their
    /// masks never touch.  Each entry is the group's top-left corner; the asserts read its centre.
    private let placements: [(name: String, reason: RemoveReason?, x: Int, y: Int, restored: Bool)] = [
        ("classifier keep", .fromClassifier(-1), 20, 20, true),
        ("user keep", .userSelected(false), 60, 20, true),
        ("classifier remove", .fromClassifier(1), 100, 20, false),
        ("user remove", .userSelected(true), 20, 70, false),
        ("undecided", nil, 60, 70, false),
    ]

    /// Runs finishAuto(useOutliers: true) on a frame whose original is flat `originalValue` and whose
    /// auto image is flat `autoValue`, both at `bits`, and returns the written output.
    private func render(bits: Int32, originalValue: UInt16, autoValue: UInt16,
                        named name: String) async throws -> PixelatedImage {
        let h = try await FrameHarness.make(frameCount: 2, width: width, height: height, named: name)
        harness = h
        let frame = h.frames[frameIndex]

        // the frame's own file becomes the original; the planted auto image is what finishAuto
        // loads instead of building one from aligned neighbours
        let filenames = await h.imageSequence.filenames
        flatImage(bits: bits, value: originalValue).mat.write(to: filenames[frameIndex])
        try h.plantImage(flatImage(bits: bits, value: autoValue),
                         ofType: .autoProcessed, frameIndex: frameIndex)
        if bits == 8 {
            // what Config.set(imageInfo:) records for a JPEG sequence
            await h.updateConfig { $0.imageBitsPerComponent = 8 }
        }

        let outlier = await frame.outlierProcessor
        await outlier.initializeEmptyOutlierGroups()
        let groupsOptional = await outlier.getOutlierGroups()
        let groups = try XCTUnwrap(groupsOptional)
        for (index, p) in placements.enumerated() {
            let g = group(id: UInt16(index + 1), x: p.x, y: p.y)
            await groups.add(g)
            if let reason = p.reason { _ = await g.shouldRemove(reason) }
        }

        try await frame.finishAuto(useOutliers: true)

        let path = try XCTUnwrap(h.imageAccessor.nameForImage(frameIndex: frameIndex,
                                                              ofType: .autoSelectiveProcessed,
                                                              atSize: .original))
        return try XCTUnwrap(PixelatedImage(filename: path), "finishAuto wrote no output at \(path)")
    }

    private func assertRestoredExactlyTheKeepGroups(_ output: PixelatedImage,
                                                    original: UInt16, auto: UInt16) {
        for p in placements {
            let value = output.readPixel(atX: p.x + 2, andY: p.y + 2).red
            if p.restored {
                XCTAssertEqual(value, original, "\(p.name) group was not restored from the original")
            } else {
                XCTAssertEqual(value, auto, "\(p.name) group was restored; it must stay as the auto image")
            }
        }
        // well clear of every group
        XCTAssertEqual(output.readPixel(atX: 100, andY: 80).red, auto,
                       "a pixel far from every group changed")
    }

    func testRestoresTheGroupsDecidedKeepAndNotTheOnesDecidedRemove() async throws {
        let output = try await render(bits: 16, originalValue: 50000, autoValue: 1000, named: "autokeep16")
        XCTAssertEqual(output.bitsPerComponent, 16)
        assertRestoredExactlyTheKeepGroups(output, original: 50000, auto: 1000)
    }

    /// An 8-bit sequence used to trap reading the original; it must also come back out at 8 bits.
    func testEightBitSequenceRendersAndStaysEightBit() async throws {
        let output8 = try await render(bits: 8, originalValue: 200, autoValue: 10, named: "autokeep8")
        XCTAssertEqual(output8.bitsPerComponent, 8, "an 8-bit sequence was written out at another depth")
        // readPixel reads 16-bit images; the 8 -> 16 conversion is exact (x256), so compare there
        assertRestoredExactlyTheKeepGroups(output8.ensure16Bits, original: 200 * 256, auto: 10 * 256)
    }
}
