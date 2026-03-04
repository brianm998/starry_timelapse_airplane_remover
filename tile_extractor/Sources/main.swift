/*

 tile_extractor

 Splits an input image into a grid of tiles and auto-classifies each tile as
 earth or sky using a binary horizon mask (white = sky, black = ground).

 The mask must be the same dimensions as the input image.

 Classification rules:
   - Tile entirely in sky   → default sky classification
   - Tile entirely in ground → earth
   - Mixed tile             → whichever pixel type is more numerous;
                               sky wins on exact ties

 Output directory structure:
   output_dir/
     earth/
     star_sky/
     clear_sky/
     cloudy_sky/

 Tile filenames encode the source directory context and top-left pixel position:
   [grandparent_]parent_tile_XXXXX_YYYYY.<ext>

 Usage:
   tile_extractor <image> <mask> <output-dir> [options]

 Options:
   --sky-default   starry_sky | clear_sky | cloudy_sky   (default: starry_sky)
   --tile-size     square tile side length in pixels     (default: 32)
   --stride        pixel distance between tile origins   (default: tile-size)

*/

import Foundation
import ArgumentParser
import logging
import StarCore
import kht_bridge

// MARK: - Helpers

/// Replaces any character that is not alphanumeric, a dot, a hyphen, or an underscore with `_`.
/// Used to make directory names safe for embedding in filenames.
private func safeName(_ s: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    return s.unicodeScalars
        .map { allowed.contains($0) ? Character($0) : Character("_") }
        .reduce(into: "") { $0.append($1) }
}

// MARK: - Sky classification (command-line argument type)

enum SkyClass: String, ExpressibleByArgument, CaseIterable, Sendable {
    case starrySky = "starry_sky"
    case clearSky  = "clear_sky"
    case cloudySky = "cloudy_sky"

    /// Name of the output subdirectory for this sky type.
    var outputDirName: String {
        switch self {
        case .starrySky: return "star_sky"
        case .clearSky:  return "clear_sky"
        case .cloudySky: return "cloudy_sky"
        }
    }
}

// MARK: - Tile classification (internal)

enum TileClass: Sendable {
    case earth
    case sky(SkyClass)

    var outputDirName: String {
        switch self {
        case .earth:      return "earth"
        case .sky(let s): return s.outputDirName
        }
    }
}

// MARK: - Command

@main
struct TileExtractor: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "tile_extractor",
        abstract: "Extract auto-classified image tiles using a binary horizon mask",
        discussion: """
            Splits an image into a grid of tiles and writes each tile into one of four
            output subdirectories based on its relationship to the horizon mask:

              earth/       — tile is entirely (or mostly) in the ground region
              star_sky/    — tile is entirely (or mostly) in the sky region (starry-sky default)
              clear_sky/   — tile is entirely (or mostly) in the sky region (clear-sky default)
              cloudy_sky/  — tile is entirely (or mostly) in the sky region (cloudy-sky default)

            The horizon mask must be a binary grayscale image the same size as the input.
            White pixels (any non-zero value) represent sky; black pixels represent ground.

            Tile filenames encode the source directory context and tile origin:
              [grandparent_]parent_tile_XXXXX_YYYYY.<ext>
            where XXXXX/YYYYY are the top-left pixel coordinates in the source image.
            """
    )

    // MARK: Arguments

    @Argument(help: "Input image filename")
    var imageFilename: String

    @Argument(help: "Horizon mask filename (binary grayscale: white=sky, black=ground; same size as image)")
    var maskFilename: String

    @Argument(help: "Output directory for classified tiles")
    var outputDir: String

    // MARK: Options

    @Option(name: .long,
            help: "Default classification for sky tiles: starry_sky (default), clear_sky, cloudy_sky")
    var skyDefault: SkyClass = .starrySky

    @Option(name: .long, help: "Tile side length in pixels — tiles are square (default 32)")
    var tileSize: Int = 32

    @Option(name: .long,
            help: "Pixel distance between tile origins (default = tile-size; smaller values create overlapping tiles)")
    var stride: Int?

    // MARK: Run

    mutating func run() async throws {
        Log.add(handler: ConsoleLogHandler(at: .info), for: .console)

        let effectiveStride = stride ?? tileSize

        // --- Input validation ---
        guard tileSize > 0 else {
            throw ValidationError("--tile-size must be positive (got \(tileSize))")
        }
        guard effectiveStride > 0 else {
            throw ValidationError("--stride must be positive (got \(effectiveStride))")
        }
        guard FileManager.default.fileExists(atPath: imageFilename) else {
            throw ValidationError("Image file not found: \(imageFilename)")
        }
        guard FileManager.default.fileExists(atPath: maskFilename) else {
            throw ValidationError("Mask file not found: \(maskFilename)")
        }

        // --- Load image and horizon mask ---
        Log.i("Loading image: \(imageFilename)")
        guard let image = PixelatedImage(filename: imageFilename) else {
            throw "Failed to load image: \(imageFilename)"
        }

        Log.i("Loading mask:  \(maskFilename)")
        guard let mask = PixelatedImage(filename: maskFilename) else {
            throw "Failed to load horizon mask: \(maskFilename)"
        }

        guard mask.width == image.width && mask.height == image.height else {
            throw "Mask size \(mask.width)×\(mask.height) must match image size \(image.width)×\(image.height)"
        }

        Log.i("Image: \(image.width)×\(image.height)")
        Log.i("Tile size: \(tileSize)×\(tileSize)px, stride: \(effectiveStride)px")
        Log.i("Default sky class: \(skyDefault.rawValue) → \(skyDefault.outputDirName)/")

        // --- Preserve source file extension ---
        let imageURL  = URL(fileURLWithPath: imageFilename).standardized
        let sourceExt = imageURL.pathExtension
        let tileExt   = sourceExt.isEmpty ? "tiff" : sourceExt

        // --- Build filename prefix from the image's directory hierarchy ---
        //
        // We include:
        //   • the immediate parent directory name (always)
        //   • the grandparent directory name (when it exists and is not the filesystem root)
        //
        // Example: /data/session_01/LRT_00042.tiff  →  prefix = "session_01"
        //          /data/night/session_01/LRT_00042.tiff  →  prefix = "night_session_01"
        //
        let parentDir     = imageURL.deletingLastPathComponent().lastPathComponent
        let grandparentDir: String = {
            let gp = imageURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .lastPathComponent
            return (gp.isEmpty || gp == "/") ? "" : gp
        }()
        let filePrefix: String = {
            let parts: [String] = grandparentDir.isEmpty
                ? [parentDir]
                : [grandparentDir, parentDir]
            return parts.map { safeName($0) }.joined(separator: "_")
        }()

        // --- Create output directory tree ---
        let outputURL = URL(fileURLWithPath: outputDir)
        for dirName in ["earth", "star_sky", "clear_sky", "cloudy_sky"] {
            let dirURL = outputURL.appendingPathComponent(dirName)
            try FileManager.default.createDirectory(at: dirURL,
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
        }

        // --- Convert stride to overlapPercent for splitIntoMatrix ---
        //
        //  Inside MatWrapper, the tile step is:  stepX = tileWidth * (1 − overlapPercent)
        //  We want stepX = effectiveStride, so:
        //    overlapPercent = 1 − effectiveStride / tileSize
        //
        //  stride < tileSize → positive overlap (tiles share pixels)
        //  stride = tileSize → no overlap (default grid)
        //  stride > tileSize → negative overlap (gaps between tiles)
        //
        let overlapPercent = 1.0 - Double(effectiveStride) / Double(tileSize)

        // --- Split image and mask into matching tile arrays ---
        Log.i("Splitting into tiles (overlapPercent=\(String(format: "%.3f", overlapPercent)))...")
        let imageTiles = image.splitIntoMatrix(maxWidth: tileSize, maxHeight: tileSize,
                                               overlapPercent: overlapPercent)
        let maskTiles  = mask.splitIntoMatrix(maxWidth: tileSize,  maxHeight: tileSize,
                                              overlapPercent: overlapPercent)

        guard imageTiles.count == maskTiles.count else {
            throw "Tile count mismatch: image produced \(imageTiles.count) tiles, " +
                  "mask produced \(maskTiles.count) tiles"
        }

        Log.i("Processing \(imageTiles.count) tiles...")

        // --- Classify and write each tile ---
        var counts: [String: Int] = [:]

        for (imageTile, maskTile) in zip(imageTiles, maskTiles) {
            if imageTile.image.width == tileSize,
               imageTile.image.height == tileSize
            {
                let tileClass = classify(maskTile: maskTile.image, defaultSky: skyDefault)
                let dirName   = tileClass.outputDirName

                // Encode source directory context and top-left pixel coordinates.
                let filename   = String(format: "\(filePrefix)_tile_%05d_%05d.\(tileExt)", imageTile.x, imageTile.y)
                let outputPath = outputURL
                  .appendingPathComponent(dirName)
                  .appendingPathComponent(filename)
                  .path

                // Write tile in same format as the source image (cv::imwrite uses the extension).
                imageTile.image.mat.write(to: outputPath)

                counts[dirName, default: 0] += 1
            }
        }

        // --- Summary ---
        Log.i("Done!")
        for dirName in ["earth", "star_sky", "clear_sky", "cloudy_sky"] {
            let n = counts[dirName, default: 0]
            if n > 0 { Log.i("  \(dirName)/: \(n) tile\(n == 1 ? "" : "s")") }
        }

        await TaskWaiter.shared.finish()
        await logging.gremlin.finishLogging()
    }

    // MARK: - Tile classification

    /// Classifies a tile by counting sky vs ground pixels in the corresponding mask tile.
    ///
    /// - Parameter maskTile: The crop of the horizon mask that covers this tile.
    ///   White (non-zero) pixels = sky; black (zero) pixels = ground.
    /// - Parameter defaultSky: The sky class to assign to sky tiles.
    /// - Returns: `.earth` or `.sky(defaultSky)`.
    func classify(maskTile: PixelatedImage, defaultSky: SkyClass) -> TileClass {
        var skyPixels    = 0
        var groundPixels = 0

        // Step through the pixel buffer one pixel at a time.
        // We only inspect the first component per pixel — for a binary mask
        // (white = all-channels-max, black = all-channels-zero) this is sufficient.
        let step = maskTile.componentsPerPixel

        switch maskTile.imageData {
        case .eightBit(let buffer):
            var idx = 0
            while idx < buffer.count {
                if buffer[idx] > 0 { skyPixels += 1 } else { groundPixels += 1 }
                idx += step
            }
        case .sixteenBit(let buffer):
            var idx = 0
            while idx < buffer.count {
                if buffer[idx] > 0 { skyPixels += 1 } else { groundPixels += 1 }
                idx += step
            }
        case .thirtyTwoBit(let buffer):
            var idx = 0
            while idx < buffer.count {
                if buffer[idx] > 0 { skyPixels += 1 } else { groundPixels += 1 }
                idx += step
            }
        }

        if skyPixels == 0    { return .earth }
        if groundPixels == 0 { return .sky(defaultSky) }

        // Mixed tile: whichever pixel type dominates wins; sky wins on exact ties.
        if groundPixels > skyPixels { return .earth }
        return .sky(defaultSky)
    }
}
