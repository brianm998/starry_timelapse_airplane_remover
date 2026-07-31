import XCTest
import Foundation
import StarCppBridge
@testable import StarCore

/// Builds a real `FrameAirplaneRemover` — and the whole stack of objects one needs — over synthetic
/// frames written to a scratch directory.
///
/// Everything at the frame level in this codebase hangs off `FrameAirplaneRemover`: the three
/// sub-processors (`FrameAlignmentProcessor`, `FrameHorizonProcessor`, `FrameOutlierProcessor`) each
/// hold a weak back-reference to it and read cross-domain values through it, and its `init` is
/// `async throws` and reaches the filesystem twice before returning.  That made ~7k lines of the
/// largest files in `StarCore` untestable in practice, since standing all of it up by hand is 60
/// lines of boilerplate per test.
///
/// What the real pipeline requires, and therefore what this reproduces:
///
///  * frames as actual image files on disk, sorted by name — `ImageSequence` globs a directory and
///    sorts, so frame index N is only frame N if the filenames sort that way.  Real runs use names
///    like `IMG_1234.tiff`; the zero-padded `frame_00.tiff` here sorts the same way.
///  * `Config.set(imageInfo:)` applied to the config *before* anything else reads it.  Leaving
///    `imageWidth`/`imageHeight`/`imageBytesPerPixel` at zero makes every op's
///    `estimatedMemoryBytes` zero, so `AsyncOperation` skips `reserve()` and the keypoint limiter
///    silently falls back — `Processor.readImageInfo` has a comment about exactly this.  A harness
///    that skipped it would test a configuration that never occurs.
///  * `ConfigManager` built on the main actor, since it is `@MainActor`-isolated.
///  * the doubly-linked `previousFrame`/`nextFrame` chain.  The horizon and alignment code walks it
///    for neighbours, and a single unlinked frame exercises a different path from a frame in the
///    middle of a sequence, so both are worth being able to build.
///
/// `ImageAccessor.init` creates every directory the config names, so constructing a harness lays
/// down the full output tree under `root`; `tearDown` removes it.
///
/// Frames are small (default 128x96) 16-bit three-channel TIFFs, matching the depth and channel
/// count of real frames — the 8-bit conversions in the C++ bridge are depth-sensitive, as the
/// `groundOnly`/`skyOnly` fix showed, so a harness built on 8-bit images would miss that class of
/// bug.  The image content is a synthetic night sky: a bright textured band above a chosen horizon
/// row, dark noise below, plus a few point stars.
final class FrameHarness {

    let root: URL
    let sequenceDir: URL
    let config: Config
    let configManager: ConfigManager
    let imageSequence: ImageSequence
    let imageAccessor: ImageAccessor
    let frames: [FrameAirplaneRemover]

    var frame: FrameAirplaneRemover { frames[0] }

    /// The synthetic horizon row used when writing the frames, so a test can compare a detected
    /// horizon against the truth it was built from.
    let horizonRow: Int

    private init(root: URL,
                 sequenceDir: URL,
                 config: Config,
                 configManager: ConfigManager,
                 imageSequence: ImageSequence,
                 imageAccessor: ImageAccessor,
                 frames: [FrameAirplaneRemover],
                 horizonRow: Int) {
        self.root = root
        self.sequenceDir = sequenceDir
        self.config = config
        self.configManager = configManager
        self.imageSequence = imageSequence
        self.imageAccessor = imageAccessor
        self.frames = frames
        self.horizonRow = horizonRow
    }

    // MARK: - construction

    /// Stand up `frameCount` frames and link them.
    ///
    /// - Parameter shiftPerFrame: how many rows the horizon moves between consecutive frames.  Zero
    ///   is a tripod sequence, non-zero stands in for a moving-camera one, which is the case the
    ///   homography paths care about.
    static func make(frameCount: Int = 3,
                     width: Int = 128,
                     height: Int = 96,
                     horizonRow: Int? = nil,
                     shiftPerFrame: Int = 0,
                     writePreviews: Bool = false,
                     named name: String = "harness",
                     file: StaticString = #filePath,
                     line: UInt = #line) async throws -> FrameHarness {

        let root = FileManager.default.temporaryDirectory
          .appendingPathComponent("FrameHarness-\(name)-\(UUID().uuidString)")
        let sequenceDir = root.appendingPathComponent("seq")
        try FileManager.default.createDirectory(at: sequenceDir,
                                                withIntermediateDirectories: true)

        let truthRow = horizonRow ?? height / 2

        for index in 0..<frameCount {
            let image = syntheticFrame(width: width,
                                       height: height,
                                       horizonRow: truthRow + index * shiftPerFrame,
                                       seed: index)
            // zero padded so the glob's lexicographic sort matches frame order
            let path = sequenceDir.appendingPathComponent(String(format: "frame_%03d.tiff", index)).path
            image.mat.write(to: path)
        }

        var config = Config(
          outputPath: root.path,
          imageSequenceName: "seq",
          imageSequencePath: root.path,
          writeOutlierGroupFiles: false,
          writeFramePreviewFiles: writePreviews,
          writeFrameProcessedPreviewFiles: writePreviews,
          writeFrameThumbnailFiles: writePreviews
        )

        let imageSequence = try ImageSequence(dirname: sequenceDir.path,
                                             supportedImageFileTypes: [".tiff"])
        let filenames = await imageSequence.filenames
        XCTAssertEqual(filenames.count, frameCount,
                       "the harness wrote \(frameCount) frames but ImageSequence found " +
                       "\(filenames.count) — a frame failed to encode",
                       file: file, line: line)

        // as Processor.readImageInfo does, and for the reason documented there
        let imageInfo = try await imageSequence.getImageInfo()
        config.set(imageInfo: imageInfo)

        let configManager = await MainActor.run {
            ConfigManager(configFilename: root.appendingPathComponent("config.json").path,
                          config: config)
        }

        var frameIndexToBaseNameMap: [Int: String] = [:]
        for (index, filename) in filenames.enumerated() {
            frameIndexToBaseNameMap[index] = removePath(fromString: filename)
        }

        let imageAccessor = ImageAccessor(
          config: config,
          imageSequence: imageSequence,
          frameIndexToBaseNameMap: frameIndexToBaseNameMap
        )

        var frames: [FrameAirplaneRemover] = []
        for (index, filename) in filenames.enumerated() {
            let frame = try await FrameAirplaneRemover(
              with: configManager,
              initialConfig: config,
              width: imageInfo.imageWidth,
              height: imageInfo.imageHeight,
              componentsPerPixel: imageInfo.componentsPerPixel,
              callbacks: Callbacks(),
              imageSequence: imageSequence,
              atIndex: index,
              outputFilename: "\(config.outputPath)/\(config.basename)",
              baseName: removePath(fromString: filename),
              writeOutputFiles: true,
              imageAccessor: imageAccessor
            )
            frames.append(frame)
        }

        // the horizon and alignment code walks previousFrame/nextFrame for neighbours; an unlinked
        // chain silently takes the no-neighbour path everywhere
        for (index, frame) in frames.enumerated() {
            if index > 0 { await frame.setPreviousFrame(frames[index - 1]) }
            if index < frames.count - 1 { await frame.setNextFrame(frames[index + 1]) }
        }

        return FrameHarness(root: root,
                            sequenceDir: sequenceDir,
                            config: config,
                            configManager: configManager,
                            imageSequence: imageSequence,
                            imageAccessor: imageAccessor,
                            frames: frames,
                            horizonRow: truthRow)
    }

    /// Remove the whole scratch tree.  Call from `tearDown`.
    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - synthetic images

    /// A night-sky-ish 16-bit three-channel frame: a bright, gently textured sky above `horizonRow`,
    /// dark noise below it, and a handful of point stars.
    ///
    /// The gradient matters — a uniform sky over uniform ground gives the gradient- and
    /// texture-based detectors nothing to disagree about, so every method returns the same answer
    /// and the confidence weighting never gets exercised.  `seed` varies the noise per frame so
    /// neighbouring frames are not byte-identical, which is what the alignment diffing assumes.
    static func syntheticFrame(width: Int,
                               height: Int,
                               horizonRow: Int,
                               seed: Int = 0) -> PixelatedImage {
        let components = 3
        let count = width * height * components
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: count)

        // a small deterministic PRNG — Int.random would make failures unreproducible
        var state = UInt64(truncatingIfNeeded: seed &* 6364136223846793005 &+ 1442695040888963407)
        func next() -> UInt16 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt16(truncatingIfNeeded: state >> 33)
        }

        let clampedHorizon = max(0, min(height, horizonRow))

        for y in 0..<height {
            let isSky = y < clampedHorizon
            for x in 0..<width {
                let base: Int
                if isSky {
                    // brightens gently towards the top, plus mild noise
                    let gradient = 22000 - (y * 8000) / max(1, clampedHorizon)
                    base = gradient + Int(next() % 900)
                } else {
                    // ground: darker, with more texture than the sky
                    let depth = y - clampedHorizon
                    base = 3200 + depth * 40 + Int(next() % 2600)
                }
                let value = UInt16(clamping: base)
                for c in 0..<components {
                    data[(y * width + x) * components + c] = value
                }
            }
        }

        // point stars, well above the horizon so they cannot be confused for ground texture
        if clampedHorizon > 4 {
            for i in 0..<12 {
                let sx = (i * 37 + seed * 5) % width
                let sy = (i * 11 + seed * 3) % max(1, clampedHorizon - 2)
                for c in 0..<components {
                    data[(sy * width + sx) * components + c] = 62000
                }
            }
        }

        let mat = MatWrapper(width: width, height: height,
                            cvType: MatWrapper.cvType(forBitsPerComponent: 16,
                                                      componentsPerPixel: Int32(components)),
                            bytesPerRow: width * components * 2,
                            data: UnsafeMutableRawPointer(data),
                            takeOwnership: true)
        return PixelatedImage(mat: mat)!
    }

    /// A binary horizon mask in the codebase's convention: white (255) above `horizonRow` is sky,
    /// black (0) below is ground.  Single channel 8-bit, which is what every OpenCV call downstream
    /// requires.
    static func syntheticMask(width: Int,
                              height: Int,
                              horizonAt: (Int) -> Int) -> PixelatedImage {
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        for y in 0..<height {
            for x in 0..<width {
                data[y * width + x] = y < horizonAt(x) ? 255 : 0
            }
        }
        let mat = MatWrapper(width: width, height: height,
                            cvType: MatWrapper.cvType(forBitsPerComponent: 8,
                                                      componentsPerPixel: 1),
                            bytesPerRow: width,
                            data: UnsafeMutableRawPointer(data),
                            takeOwnership: true)
        return PixelatedImage(mat: mat)!
    }

    static func flatMask(width: Int, height: Int, at horizonRow: Int) -> PixelatedImage {
        syntheticMask(width: width, height: height) { _ in horizonRow }
    }

    // MARK: - writing fixtures into the harness tree

    /// Write an image to a scratch path under `root` and return the path, for the APIs that take
    /// filenames rather than images — `HomographyHorizonDetector.prepare` is the main one.
    func writeScratch(_ image: PixelatedImage, named name: String) -> String {
        let dir = root.appendingPathComponent("scratch")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(name).path
        image.mat.write(to: path)
        return path
    }
}

/// A base class that owns a harness and tears it down, so the per-file boilerplate is one override.
class FrameHarnessTestCase: XCTestCase {
    var harness: FrameHarness?

    override func tearDown() {
        harness?.cleanUp()
        harness = nil
        super.tearDown()
    }
}
