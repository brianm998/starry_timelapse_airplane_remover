/*

 tile_classifier_tester

 Classifies every full tile in an input image using the CoreML TileClassifier
 and writes a new image of the same dimensions where each tile region is filled
 with the classification colour.

 Usage
 ─────
   tile_classifier_tester <image> <output> [--tile-size N] [--max-concurrent N] [--color-map]

 Output modes
 ────────────
   Binary (default)   sky tiles → white (255)    earth tiles → black (0)
   Colour (--color-map)
     earth      → black   (0, 0, 0)
     star_sky   → green   (0, 255, 0)
     clear_sky  → blue    (255, 0, 0)   ← OpenCV BGR order
     cloudy_sky → red     (0, 0, 255)

 Tiles that fall on a partial edge (smaller than tileSize × tileSize) are
 left black in the output.

*/

import Foundation
import ArgumentParser
import Semaphore
import logging
import StarCore

// MARK: - Entry point

@main
struct TileClassifierMap: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "tile_classifier_tester",
        abstract: "Classify image tiles with the CoreML TileClassifier and write a colour map.",
        discussion: """
            Splits <image> into non-overlapping tiles and classifies each one with the
            trained CoreML tile classifier.  The output is a new image (same dimensions)
            where every tile region is filled with the classification colour.

            Binary mode (default):
              sky tiles → white (255)   earth tiles → black (0)

            Colour-map mode (--color-map):
              earth      → black    star_sky → green
              clear_sky  → blue     cloudy_sky → red
            """
    )

    // MARK: Arguments & options

    @Argument(help: "Input image filename")
    var imageFilename: String

    @Argument(help: "Output image filename (format inferred from extension: .tiff, .png, .jpg, …)")
    var outputFilename: String

    @Option(name: .long, help: "Tile side length in pixels (default: 32)")
    var tileSize: Int = 32

    @Option(name: .long, help: "Maximum concurrent tile classifications (default: 8)")
    var maxConcurrent: Int = 8

    @Flag(name: .long,
          help: "Write a colour map instead of a binary sky/earth mask")
    var colorMap: Bool = false

    // MARK: Run

    mutating func run() async throws {
        Log.add(handler: ConsoleLogHandler(at: .info), for: .console)

        // ── Validate ──────────────────────────────────────────────────────────
        guard tileSize > 0 else {
            throw ValidationError("--tile-size must be positive (got \(tileSize))")
        }
        guard maxConcurrent > 0 else {
            throw ValidationError("--max-concurrent must be positive (got \(maxConcurrent))")
        }
        guard FileManager.default.fileExists(atPath: imageFilename) else {
            throw ValidationError("Image not found: \(imageFilename)")
        }

        // ── Load image ────────────────────────────────────────────────────────
        guard let image = PixelatedImage(filename: imageFilename) else {
            throw "Failed to load image: \(imageFilename)"
        }
        Log.i("Image    : \(imageFilename)  \(image.width)×\(image.height)")

        // ── Split into tiles ──────────────────────────────────────────────────
        let allTiles = image.splitIntoMatrix(maxWidth: tileSize, maxHeight: tileSize)
        // Partial edge tiles (smaller than tileSize×tileSize) stay black in the output.
        let tiles = allTiles.filter { $0.width == tileSize && $0.height == tileSize }
        Log.i("Tiles    : \(allTiles.count) total, \(tiles.count) full \(tileSize)×\(tileSize)")

        // ── Load model ────────────────────────────────────────────────────────
        let classifier = try TileClassifier()
        Log.i("Classifier loaded")

        // ── Classify in parallel with bounded concurrency ─────────────────────
        // Each child task returns its tile index and the predicted class.
        // Results are collected in the parent task (serialised) so that
        // `classifications` and `errorCount` need no locking.
        var classifications = Array(repeating: TileMLClass.earth, count: tiles.count)
        var errorCount = 0
        let semaphore = AsyncSemaphore(value: maxConcurrent)

        Log.i("Classifying \(tiles.count) tile(s)  (max concurrent: \(maxConcurrent))…")
        let t0 = Date()

        await withTaskGroup(of: (Int, TileMLClass, Bool).self) { group in
            for (idx, tile) in tiles.enumerated() {
                await semaphore.wait()
                group.addTask {
                    defer { semaphore.signal() }
                    do {
                        let cls = try classifier.classify(tile.image)
                        return (idx, cls, false)
                    } catch {
                        return (idx, .earth, true)
                    }
                }
            }
            for await (idx, cls, hadError) in group {
                classifications[idx] = cls
                if hadError { errorCount += 1 }
            }
        }

        let elapsed = Date().timeIntervalSince(t0)
        Log.i(String(format: "Done in %.1fs  (%.0f tiles/s)",
                     elapsed, Double(tiles.count) / max(elapsed, 0.001)))

        if errorCount > 0 {
            Log.w("\(errorCount) tile(s) failed classification — treated as earth")
        }

        // ── Log per-class counts ──────────────────────────────────────────────
        var counts: [TileMLClass: Int] = [:]
        for cls in classifications { counts[cls, default: 0] += 1 }
        for cls in TileMLClass.allCases {
            if let n = counts[cls], n > 0 {
                Log.i("  \(cls.rawValue): \(n) tile(s)")
            }
        }

        // ── Build output image ────────────────────────────────────────────────
        // components: 3 (colour BGR) or 1 (grayscale for binary mode)
        let components = colorMap ? 3 : 1
        let outputBuffer = ImageBuffer<UInt8>(
            width:      image.width,
            height:     image.height,
            components: components
        )
        // BufferHolder zero-initialises the allocation — all pixels start black.
        // Access the raw pointer directly to avoid struct mutating-setter constraints.
        let ptr = outputBuffer.pointer

        for (idx, tile) in tiles.enumerated() {
            let (b, g, r) = bgrColor(for: classifications[idx], colorMode: colorMap)
            for row in tile.y ..< tile.y + tile.height {
                for col in tile.x ..< tile.x + tile.width {
                    let base = (row * image.width + col) * components
                    if components == 1 {
                        ptr[base] = b
                    } else {
                        ptr[base]     = b   // B
                        ptr[base + 1] = g   // G
                        ptr[base + 2] = r   // R
                    }
                }
            }
        }

        // Snapshot the filled buffer into a PixelatedImage (ImageBuffer.image clones
        // the buffer into a fresh cv::Mat so the output is self-contained).
        guard let outputImage = outputBuffer.image else {
            throw "Failed to create output PixelatedImage from buffer"
        }

        // ── Write output ──────────────────────────────────────────────────────
        // Create parent directories if needed (best-effort).
        let outputParent = URL(fileURLWithPath: outputFilename)
            .standardized
            .deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: outputParent,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // writeTIFFEncoding uses cv::imwrite — format is inferred from the extension.
        outputImage.writeTIFFEncoding(toFilename: outputFilename)
        Log.i("Written  → \(outputFilename)")

        await TaskWaiter.shared.finish()
        await logging.gremlin.finishLogging()
    }
}

// MARK: - Colour helpers

/// Returns the BGR triplet for a tile classification.
///
/// OpenCV stores colour images in BGR order, so:
///   green (star_sky)   = (B:0, G:255, R:0)
///   blue  (clear_sky)  = (B:255, G:0, R:0)
///   red   (cloudy_sky) = (B:0, G:0, R:255)
///
/// Binary mode: sky → white (255, 255, 255)  /  earth → black (0, 0, 0).
/// The binary output is 1-channel (grayscale), so only the first value is used.
private func bgrColor(
    for cls: TileMLClass,
    colorMode: Bool
) -> (b: UInt8, g: UInt8, r: UInt8) {
    guard colorMode else {
        return cls == .earth ? (0, 0, 0) : (255, 255, 255)
    }
    switch cls {
    case .earth:     return (0,   0,   0)
    case .starrySky: return (0,   255, 0)
    case .clearSky:  return (255, 0,   0)
    case .cloudySky: return (0,   0,   255)
    }
}
