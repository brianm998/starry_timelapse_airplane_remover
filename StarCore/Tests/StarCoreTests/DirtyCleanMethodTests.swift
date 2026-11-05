import XCTest
import Foundation
import StarCppBridge
@testable import StarCore

/// `CleanMethod.dirtySky` and `.dirtyEarth`: for their own portion of the frame, the colour
/// subtraction `original − aligned reference` per channel, clipped at 0; the other portion black.
///
/// The fixture is one real frame (`FrameHarness`) with its aligned references planted where
/// `loadOrCreateAlignedImage` loads them, and a merged horizon mask at row 48 of 96.  The
/// star-aligned image matches the original in the sky and is black on the ground; the
/// earth-aligned one matches it on the ground and is black in the sky.  So a pixel only comes out
/// near 0 when the right reference was used for its portion, and a dot that is in the original
/// but in neither reference is what "moved".
///
/// The reference blends the earth into the 24 rows above the horizon (`horizonFeatherPixels`),
/// where this fixture's black earth sky is not a stand-in for anything real, so static-sky checks
/// stay above that band; the split itself is the un-feathered mask, so the "exactly 0" checks
/// cover every row of the dropped portion.
final class DirtyCleanMethodTests: FrameHarnessTestCase {

    private let width = 128
    private let height = 96
    private let horizon = 48

    // a static star the synthetic frame puts at (0, 0) for seed 0, present in every image
    private let star = (x: 0, y: 0)
    // the moved dots: in the original only
    private let skyDot = (x: 40, y: 8)
    private let groundDot = (x: 100, y: 80)
    // blue/green/red: the third channel is darker than the background, so it clips to 0
    private let skyDotColour: [UInt16] = [50000, 30000, 1000]
    private let groundDotColour: [UInt16] = [20000, 60000, 500]

    // MARK: - fixture

    private func rgb(_ image: PixelatedImage, _ x: Int, _ y: Int) -> [Int] {
        guard case .sixteenBit(let buffer) = image.imageData else {
            XCTFail("expected 16 bit data")
            return [0, 0, 0]
        }
        let i = (y * image.width + x) * 3
        return [Int(buffer[i]), Int(buffer[i + 1]), Int(buffer[i + 2])]
    }

    private func image(from base: PixelatedImage,
                       _ edit: (_ x: Int, _ y: Int, _ pixel: inout [UInt16]) -> Void) -> PixelatedImage {
        let count = width * height * 3
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: count)
        defer { data.deallocate() }
        for y in 0..<height {
            for x in 0..<width {
                var pixel = rgb(base, x, y).map { UInt16($0) }
                edit(x, y, &pixel)
                for c in 0..<3 { data[(y * width + x) * 3 + c] = pixel[c] }
            }
        }
        let mat = MatWrapper(width: width, height: height,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 16, componentsPerPixel: 3),
                             bytesPerRow: width * 3 * 2,
                             data: UnsafeMutableRawPointer(data),
                             takeOwnership: true)
        return PixelatedImage(mat: mat)!
    }

    private func isDot(_ x: Int, _ y: Int, _ dot: (x: Int, y: Int)) -> Bool {
        abs(x - dot.x) <= 1 && abs(y - dot.y) <= 1
    }

    /// The harness with the original, both references and the horizon planted.
    /// Returns the original and the two references for computing expected values.
    private func makeFrame(named name: String,
                           wholeFrameStarReference: Bool = false) async throws
      -> (FrameHarness, original: PixelatedImage, starRef: PixelatedImage, earthRef: PixelatedImage)
    {
        let h = try await FrameHarness.make(frameCount: 1, width: width, height: height,
                                            horizonRow: horizon, named: name)
        harness = h
        // CLAUDE.md: the GPU median merge crashes this Mac, so tests here never use it (this path does not merge, but the
        // default is on whenever a GPU is detected)
        await h.updateConfig { $0.useGPUForMerge = false }
        let base = FrameHarness.syntheticFrame(width: width, height: height, horizonRow: horizon)
        let original = image(from: base) { x, y, pixel in
            if self.isDot(x, y, self.skyDot) { pixel = self.skyDotColour }
            if self.isDot(x, y, self.groundDot) { pixel = self.groundDotColour }
        }
        let starRef = image(from: base) { _, y, pixel in
            if !wholeFrameStarReference, y >= self.horizon { pixel = [0, 0, 0] }
        }
        let earthRef = image(from: base) { _, y, pixel in
            if y < self.horizon { pixel = [0, 0, 0] }
        }
        try h.plantImage(original, ofType: .original)
        try h.plantImage(starRef, ofType: .starAligned)
        try h.plantImage(earthRef, ofType: .earthAligned)
        try h.plantImage(FrameHarness.flatMask(width: width, height: height, at: horizon),
                         ofType: .mergedHorizon)
        return (h, original, starRef, earthRef)
    }

    private func expected(_ original: PixelatedImage, _ reference: PixelatedImage,
                          _ x: Int, _ y: Int) -> [Int] {
        zip(rgb(original, x, y), rgb(reference, x, y)).map { max(0, $0 - $1) }
    }

    private func output(_ h: FrameHarness, _ type: FrameViewMode) async throws -> PixelatedImage {
        let loaded = try await h.imageAccessor.load(frameIndex: 0, type: type, atSize: .original)
        return try XCTUnwrap(loaded, "no \(type) image was written")
    }

    private func inode(_ path: String) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? UInt64)
    }

    // MARK: - A1, A2

    func testDirtySkyKeepsOnlySkyMotion() async throws {
        let (h, original, starRef, _) = try await makeFrame(named: "dirty-sky")
        await h.updateConfig { $0.cleanMethod = .dirtySky }

        try await h.frame.finish()

        let out = try await output(h, .dirtySkyProcessed)
        XCTAssertEqual(out.componentsPerPixel, 3, "colour, not grayscale")
        XCTAssertEqual(out.bitsPerComponent, 16, "the original's depth")

        // the static star is removed
        XCTAssertEqual(rgb(out, star.x, star.y), [0, 0, 0])
        // the moved sky dot keeps its colour, clipped at 0 per channel
        let dot = expected(original, starRef, skyDot.x, skyDot.y)
        XCTAssertEqual(rgb(out, skyDot.x, skyDot.y), dot)
        XCTAssertGreaterThan(dot[0], 0)
        XCTAssertGreaterThan(dot[1], 0)
        XCTAssertEqual(dot[2], 0, "the fixture's third channel is darker than the sky behind it")
        // static sky, above the feather band, is ~0
        for y in 0..<(horizon - FrameAirplaneRemover.horizonFeatherPixels - 2) {
            for x in 0..<width where !isDot(x, y, skyDot) {
                XCTAssertLessThanOrEqual(rgb(out, x, y).max()!, 2, "static sky at (\(x), \(y))")
            }
        }
        // every ground pixel is exactly 0, the moved ground dot included
        for y in horizon..<height {
            for x in 0..<width {
                XCTAssertEqual(rgb(out, x, y), [0, 0, 0], "ground at (\(x), \(y))")
            }
        }
        let state = await h.frame.processingState()
        XCTAssertEqual(state, .complete)
    }

    func testDirtyEarthKeepsOnlyGroundMotion() async throws {
        let (h, original, _, earthRef) = try await makeFrame(named: "dirty-earth")
        await h.updateConfig { $0.cleanMethod = .dirtyEarth }

        try await h.frame.finish()

        let out = try await output(h, .dirtyEarthProcessed)
        XCTAssertEqual(out.componentsPerPixel, 3)
        XCTAssertEqual(out.bitsPerComponent, 16)

        // the moved ground dot keeps its colour
        let dot = expected(original, earthRef, groundDot.x, groundDot.y)
        XCTAssertEqual(rgb(out, groundDot.x, groundDot.y), dot)
        XCTAssertGreaterThan(dot[0], 0)
        XCTAssertGreaterThan(dot[1], 0)
        XCTAssertEqual(dot[2], 0)
        // static ground is ~0
        for y in horizon..<height {
            for x in 0..<width where !isDot(x, y, groundDot) {
                XCTAssertLessThanOrEqual(rgb(out, x, y).max()!, 2, "static ground at (\(x), \(y))")
            }
        }
        // every sky pixel is exactly 0, the star and the moved sky dot included
        for y in 0..<horizon {
            for x in 0..<width {
                XCTAssertEqual(rgb(out, x, y), [0, 0, 0], "sky at (\(x), \(y))")
            }
        }
    }

    // MARK: - A3

    func testDirtyModesSkipOutlierDetection() async throws {
        XCTAssertFalse(CleanMethod.dirtySky.usesOutliers)
        XCTAssertFalse(CleanMethod.dirtyEarth.usesOutliers)

        for (method, type) in [(CleanMethod.dirtySky, FrameViewMode.dirtySkyProcessed),
                               (.dirtyEarth, .dirtyEarthProcessed)] {
            harness?.cleanUp()
            let (h, _, _, _) = try await makeFrame(named: "dirty-no-outliers")
            await h.updateConfig { $0.cleanMethod = method }

            try await h.frame.finish()

            XCTAssertTrue(h.imageAccessor.imageExists(frameIndex: 0, ofType: type, atSize: .original))
            let state = await h.frame.processingState()
            XCTAssertEqual(state, .complete)
            let outliers = await h.frame.outlierProcessor.outliersDirname
            let written = (try? FileManager.default.contentsOfDirectory(atPath: outliers)) ?? []
            XCTAssertEqual(written, [], "\(method) wrote outlier files: \(written)")
            let groups = await h.frame.getOutlierGroups()
            XCTAssertNil(groups, "\(method) ran outlier detection")
            XCTAssertFalse(h.imageAccessor.imageExists(frameIndex: 0, ofType: .subtraction, atSize: .original))
            XCTAssertFalse(h.imageAccessor.imageExists(frameIndex: 0, ofType: .validation, atSize: .original))
        }
    }

    // MARK: - A5

    func testHorizonOffBehaviour() async throws {
        let (h, original, starRef, _) = try await makeFrame(named: "dirty-no-horizon",
                                                            wholeFrameStarReference: true)
        await h.updateConfig {
            $0.horizonDetectionEnabled = false
            $0.cleanMethod = .dirtySky
        }

        try await h.frame.finish()

        // no ground portion: the whole frame is dirty sky against the star-aligned image
        let out = try await output(h, .dirtySkyProcessed)
        XCTAssertEqual(rgb(out, star.x, star.y), [0, 0, 0])
        XCTAssertEqual(rgb(out, skyDot.x, skyDot.y), expected(original, starRef, skyDot.x, skyDot.y))
        XCTAssertEqual(rgb(out, groundDot.x, groundDot.y), expected(original, starRef, groundDot.x, groundDot.y))
        XCTAssertGreaterThan(rgb(out, groundDot.x, groundDot.y)[1], 0, "the ground dot is kept")
        for y in 0..<height {
            for x in 0..<width where !isDot(x, y, skyDot) && !isDot(x, y, groundDot) {
                XCTAssertLessThanOrEqual(rgb(out, x, y).max()!, 2, "static pixel at (\(x), \(y))")
            }
        }

        // and dirty earth is refused, in the user's language
        await h.updateConfig { $0.cleanMethod = .dirtyEarth }
        do {
            try await h.frame.finish()
            XCTFail("dirty earth ran with horizon detection off")
        } catch {
            XCTAssertEqual("\(error)", Config.dirtyEarthNeedsHorizonMessage)
        }
        XCTAssertFalse(h.imageAccessor.imageExists(frameIndex: 0, ofType: .dirtyEarthProcessed, atSize: .original))
        let refused = await h.configManager.config()
        XCTAssertEqual(refused.cleanMethodConflict, Config.dirtyEarthNeedsHorizonMessage)
    }

    // MARK: - A6

    func testSwitchingLinksCachedOutput() async throws {
        let (h, _, _, _) = try await makeFrame(named: "dirty-switch")
        let finalPath = try XCTUnwrap(h.imageAccessor.nameForImage(frameIndex: 0, ofType: .final, atSize: .original))
        let cachedImage = FrameHarness.syntheticFrame(width: width, height: height, horizonRow: horizon)
        let auto = try h.plantImage(cachedImage, ofType: .autoProcessed)
        let dirtySky = try h.plantImage(cachedImage, ofType: .dirtySkyProcessed)
        let dirtySkyInode = try inode(dirtySky)

        await h.frame.set(cleanMethod: .dirtySky)
        XCTAssertEqual(try inode(finalPath), dirtySkyInode, "the cached dirty sky image is linked")

        await h.frame.set(cleanMethod: .automatic(false))
        XCTAssertEqual(try inode(finalPath), try inode(auto))

        await h.frame.set(cleanMethod: .dirtySky)
        XCTAssertEqual(try inode(finalPath), dirtySkyInode)
        XCTAssertEqual(try inode(dirtySky), dirtySkyInode, "linked, not made again")

        // with nothing cached, the dirty image is made and then linked
        await h.frame.set(cleanMethod: .dirtyEarth)
        let dirtyEarth = try XCTUnwrap(h.imageAccessor.nameForImage(frameIndex: 0, ofType: .dirtyEarthProcessed, atSize: .original))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirtyEarth))
        XCTAssertEqual(try inode(finalPath), try inode(dirtyEarth))

        await h.frame.set(cleanMethod: .dirtySky)
        XCTAssertEqual(try inode(finalPath), dirtySkyInode)

        // and the merge output a reprocess deletes includes both
        XCTAssertTrue(h.frame.mergeOutputExistsOnDisk())
        await h.frame.deleteMergeOutput()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirtySky))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirtyEarth))
    }
}
