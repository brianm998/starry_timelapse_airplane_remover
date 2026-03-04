/*

 tile_extractor

 Splits images into grids of tiles and auto-classifies each tile as earth or sky
 using a binary horizon mask (white = sky, black = ground).

 Two modes of operation
 ──────────────────────

 SINGLE-IMAGE MODE  (default — identical to previous behaviour)
   tile_extractor <image> <mask> <output-dir> [--sky-default ...] [--tile-size N] [--stride N]

 BATCH MODE
   tile_extractor batch <raw-dir> <output-dir> [--tile-size N] [--stride N]

   Traverses a raw ML-data hierarchy rooted at <raw-dir>:
     <raw-dir>/
       star_sky/
         <sequence-name>/
           original/   ← source images
           horizon/    ← matching horizon masks (identical filenames)
       clear_sky/
         <sequence-name>/ …
       cloudy_sky/
         <sequence-name>/ …

   The sky classification for each image is taken from its containing sky
   directory (star_sky → starry_sky, clear_sky → clear_sky, etc.).

 Output directory structure (both modes)
 ────────────────────────────────────────
   <output-dir>/
     earth/
     star_sky/
     clear_sky/
     cloudy_sky/

 Tile filenames encode the source directory context and top-left pixel position:
   [grandparent_]parent_tile_XXXXX_YYYYY.<ext>

 Classification rules
 ────────────────────
   Tile entirely in sky    → default sky class
   Tile entirely in ground → earth
   Mixed tile              → whichever pixel type is more numerous;
                             sky wins on exact ties

*/

import Foundation
import ArgumentParser
import logging
import StarCore
import kht_bridge

// MARK: - Helpers

/// Replaces any character that is not alphanumeric, `.`, `-`, or `_` with `_`.
/// Used to embed directory names safely inside tile filenames.
private func safeName(_ s: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    return s.unicodeScalars
        .map { allowed.contains($0) ? Character($0) : Character("_") }
        .reduce(into: "") { $0.append($1) }
}

// MARK: - Types

enum SkyClass: String, ExpressibleByArgument, CaseIterable, Sendable {
    case starrySky = "starry_sky"
    case clearSky  = "clear_sky"
    case cloudySky = "cloudy_sky"

    /// Name of the output subdirectory (and raw-data input subdirectory) for this sky type.
    var outputDirName: String {
        switch self {
        case .starrySky: return "star_sky"
        case .clearSky:  return "clear_sky"
        case .cloudySky: return "cloudy_sky"
        }
    }

    /// Returns the SkyClass whose output directory name equals `name`, or `nil`.
    static func from(dirName name: String) -> SkyClass? {
        allCases.first { $0.outputDirName == name }
    }
}

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

// MARK: - Shared tile options

struct TileOptions: ParsableArguments {
    @Option(name: .long, help: "Tile side length in pixels — tiles are square (default 32)")
    var tileSize: Int = 32

    @Option(name: .long,
            help: "Pixel distance between tile origins (default = tile-size; smaller → overlapping tiles)")
    var stride: Int?
}

// MARK: - Core logic (free functions used by both modes)

/// Counts sky vs ground pixels in a mask tile and returns the tile classification.
/// Sky wins on exact ties.
func classify(maskTile: PixelatedImage, defaultSky: SkyClass) -> TileClass {
    var skyPixels    = 0
    var groundPixels = 0

    // Only the first component per pixel is checked — for a binary mask
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

    if skyPixels    == 0 { return .earth }
    if groundPixels == 0 { return .sky(defaultSky) }
    if groundPixels  > skyPixels { return .earth }
    return .sky(defaultSky)   // sky wins on ties
}

/// Loads one image+mask pair, splits into tiles, classifies each tile, and writes
/// full-size tiles into the appropriate subdirectory of `outputURL`.
///
/// Output subdirectories are created automatically (idempotent).
/// Edge tiles smaller than `tileSize×tileSize` are silently skipped.
///
/// - Returns: tile counts keyed by output directory name.
func processImage(
    imageFilename: String,
    maskFilename:  String,
    outputURL:     URL,
    skyDefault:    SkyClass,
    tileSize:      Int,
    effectiveStride: Int
) throws -> [String: Int] {

    guard let image = PixelatedImage(filename: imageFilename) else {
        throw "Failed to load image: \(imageFilename)"
    }
    guard let mask = PixelatedImage(filename: maskFilename) else {
        throw "Failed to load mask: \(maskFilename)"
    }
    guard mask.width == image.width && mask.height == image.height else {
        throw "Mask \(mask.width)×\(mask.height) does not match image \(image.width)×\(image.height) — \(imageFilename)"
    }

    // Preserve the source file extension.
    let imageURL  = URL(fileURLWithPath: imageFilename).standardized
    let sourceExt = imageURL.pathExtension
    let tileExt   = sourceExt.isEmpty ? "tiff" : sourceExt

    // Build the filename prefix from the image's two enclosing directory names.
    // e.g.  .../sequence_01/original/LRT_00042.tiff  →  "sequence_01_original"
    let filename = imageURL.lastPathComponent.replacing(".", with: "_")
    let parentDir = imageURL.deletingLastPathComponent().lastPathComponent
    let grandparentDir: String = {
        let gp = imageURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .lastPathComponent
        return (gp.isEmpty || gp == "/") ? "" : gp
    }()
    let filePrefix: String = {
        let parts: [String] = grandparentDir.isEmpty
          ? [parentDir, filename]
            : [grandparentDir, parentDir, filename]
        return parts.map { safeName($0) }.joined(separator: "_")
    }()

    // Create output subdirectories (no-op if they already exist).
    for dirName in ["earth", "star_sky", "clear_sky", "cloudy_sky"] {
        try FileManager.default.createDirectory(
            at: outputURL.appendingPathComponent(dirName),
            withIntermediateDirectories: true,
            attributes: nil)
    }

    // stride = tileSize × (1 − overlapPercent)
    let overlapPercent = 1.0 - Double(effectiveStride) / Double(tileSize)

    let imageTiles = image.splitIntoMatrix(maxWidth: tileSize, maxHeight: tileSize,
                                           overlapPercent: overlapPercent)
    let maskTiles  = mask.splitIntoMatrix(maxWidth: tileSize,  maxHeight: tileSize,
                                          overlapPercent: overlapPercent)

    guard imageTiles.count == maskTiles.count else {
        throw "Tile count mismatch (\(imageTiles.count) vs \(maskTiles.count)) for \(imageFilename)"
    }

    var counts: [String: Int] = [:]

    for (imageTile, maskTile) in zip(imageTiles, maskTiles) {
        // Skip partial edge tiles.
        guard imageTile.image.width  == tileSize,
              imageTile.image.height == tileSize else { continue }

        let tileClass  = classify(maskTile: maskTile.image, defaultSky: skyDefault)
        let dirName    = tileClass.outputDirName
        let filename   = String(format: "\(filePrefix)_tile_%05d_%05d.\(tileExt)",
                                imageTile.x, imageTile.y)
        let outputPath = outputURL
            .appendingPathComponent(dirName)
            .appendingPathComponent(filename)
            .path

        // Convert to 8-bit RGB (÷256 fixed scaling) before writing,
        // so all tiles are 8-bit regardless of the source image bit depth.
        // This matches the robust_loader in train_tile_classifier.py (>> 8).
        imageTile.image.mat.ensure8Bits().write(to: outputPath)
        counts[dirName, default: 0] += 1
    }

    return counts
}

// MARK: - Root command (dispatches to subcommands; single-image is the default)

@main
struct TileExtractor: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "tile_extractor",
        abstract: "Extract auto-classified image tiles using a binary horizon mask",
        discussion: """
            SINGLE-IMAGE MODE (default):
              tile_extractor <image> <mask> <output-dir> [options]

            BATCH MODE:
              tile_extractor batch <raw-dir> <output-dir> [--tile-size N] [--stride N]

            Output subdirectories:  earth/  star_sky/  clear_sky/  cloudy_sky/
            Tile filenames:  [grandparent_]parent_tile_XXXXX_YYYYY.<ext>
            """,
        subcommands: [SingleMode.self, BatchMode.self],
        defaultSubcommand: SingleMode.self
    )
}

// MARK: - Single-image subcommand (default)

struct SingleMode: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "single",
        abstract: "Extract tiles from one image+mask pair (default mode)"
    )

    @OptionGroup var tiles: TileOptions

    @Option(name: .long,
            help: "Default sky classification: starry_sky (default), clear_sky, cloudy_sky")
    var skyDefault: SkyClass = .starrySky

    @Argument(help: "Input image filename")
    var imageFilename: String

    @Argument(help: "Horizon mask filename (binary grayscale: white=sky, black=ground; same size as image)")
    var maskFilename: String

    @Argument(help: "Output directory for classified tiles")
    var outputDir: String

    mutating func run() async throws {
        Log.add(handler: ConsoleLogHandler(at: .info), for: .console)

        let effectiveStride = tiles.stride ?? tiles.tileSize

        guard tiles.tileSize > 0 else {
            throw ValidationError("--tile-size must be positive (got \(tiles.tileSize))")
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

        Log.i("Image: \(imageFilename)")
        Log.i("Mask:  \(maskFilename)")
        Log.i("Tile: \(tiles.tileSize)×\(tiles.tileSize)px, stride: \(effectiveStride)px")
        Log.i("Default sky class: \(skyDefault.rawValue) → \(skyDefault.outputDirName)/")

        let counts = try processImage(
            imageFilename:   imageFilename,
            maskFilename:    maskFilename,
            outputURL:       URL(fileURLWithPath: outputDir),
            skyDefault:      skyDefault,
            tileSize:        tiles.tileSize,
            effectiveStride: effectiveStride
        )

        Log.i("Done!")
        printCounts(counts)

        await TaskWaiter.shared.finish()
        await logging.gremlin.finishLogging()
    }
}

// MARK: - Batch subcommand

struct BatchMode: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "batch",
        abstract: "Batch-process a raw ML data directory tree",
        discussion: """
            Expects the following hierarchy under <raw-dir>:

              <raw-dir>/
                star_sky/
                  <sequence>/
                    original/   ← source images
                    horizon/    ← masks (identical filenames to original/)
                clear_sky/
                  <sequence>/ …
                cloudy_sky/
                  <sequence>/ …

            The sky classification for each image is inferred from its sky
            directory (star_sky → starry_sky, etc.).
            Images whose matching mask is absent are skipped with a warning.
            """
    )

    @OptionGroup var tiles: TileOptions

    @Argument(help: "Root of the raw ML data hierarchy (contains star_sky/, clear_sky/, cloudy_sky/)")
    var rawDir: String

    @Argument(help: "Output directory for classified tiles")
    var outputDir: String

    mutating func run() async throws {
        Log.add(handler: ConsoleLogHandler(at: .info), for: .console)

        let effectiveStride = tiles.stride ?? tiles.tileSize

        guard tiles.tileSize > 0 else {
            throw ValidationError("--tile-size must be positive (got \(tiles.tileSize))")
        }
        guard effectiveStride > 0 else {
            throw ValidationError("--stride must be positive (got \(effectiveStride))")
        }
        guard FileManager.default.fileExists(atPath: rawDir) else {
            throw ValidationError("Raw directory not found: \(rawDir)")
        }

        Log.i("Batch mode")
        Log.i("Raw dir:  \(rawDir)")
        Log.i("Output:   \(outputDir)")
        Log.i("Tile: \(tiles.tileSize)×\(tiles.tileSize)px, stride: \(effectiveStride)px")

        let rawURL    = URL(fileURLWithPath: rawDir)
        let outputURL = URL(fileURLWithPath: outputDir)

        var totalCounts: [String: Int] = [:]
        var imagesProcessed = 0
        var imagesSkipped   = 0

        // ── Walk star_sky/ clear_sky/ cloudy_sky/ ──────────────────────────────
        for skyDirName in ["star_sky", "clear_sky", "cloudy_sky"] {
            let skyDirURL = rawURL.appendingPathComponent(skyDirName)

            guard FileManager.default.fileExists(atPath: skyDirURL.path) else {
                Log.i("  \(skyDirName)/  not found, skipping")
                continue
            }
            guard let skyClass = SkyClass.from(dirName: skyDirName) else {
                Log.w("  Unknown sky-class directory name '\(skyDirName)', skipping")
                continue
            }

            Log.i("Processing \(skyDirName)/...")

            // ── Walk sequence directories ─────────────────────────────────────
            let sequenceDirs = try subdirectories(of: skyDirURL)

            for sequenceURL in sequenceDirs {
                let originalURL = sequenceURL.appendingPathComponent("original")
                let horizonURL  = sequenceURL.appendingPathComponent("horizon")

                guard FileManager.default.fileExists(atPath: originalURL.path),
                      FileManager.default.fileExists(atPath: horizonURL.path) else {
                    Log.w("  Skipping \(sequenceURL.lastPathComponent): missing original/ or horizon/")
                    continue
                }

                // ── Walk image files in original/ ─────────────────────────────
                let imageFiles = try imageFilesIn(originalURL)
                Log.i("  \(sequenceURL.lastPathComponent)/: \(imageFiles.count) image(s)")

                for imageFile in imageFiles {
                    let maskFile = horizonURL.appendingPathComponent(imageFile.lastPathComponent)

                    guard FileManager.default.fileExists(atPath: maskFile.path) else {
                        Log.w("    No mask for \(imageFile.lastPathComponent) — skipped")
                        imagesSkipped += 1
                        continue
                    }

                    do {
                        let counts = try processImage(
                            imageFilename:   imageFile.path,
                            maskFilename:    maskFile.path,
                            outputURL:       outputURL,
                            skyDefault:      skyClass,
                            tileSize:        tiles.tileSize,
                            effectiveStride: effectiveStride
                        )
                        for (dir, n) in counts { totalCounts[dir, default: 0] += n }
                        imagesProcessed += 1
                        Log.i("    \(imageFile.lastPathComponent) → \(counts.values.reduce(0, +)) tiles")
                    } catch {
                        Log.e("    Error processing \(imageFile.lastPathComponent): \(error)")
                        imagesSkipped += 1
                    }
                }
            }
        }

        // ── Summary ────────────────────────────────────────────────────────────
        Log.i("Batch complete: \(imagesProcessed) image(s) processed, \(imagesSkipped) skipped")
        printCounts(totalCounts)

        await TaskWaiter.shared.finish()
        await logging.gremlin.finishLogging()
    }
}

// MARK: - Directory traversal helpers

/// Returns immediate subdirectories of `url`, sorted by name, skipping hidden entries.
private func subdirectories(of url: URL) throws -> [URL] {
    try FileManager.default
        .contentsOfDirectory(at: url,
                             includingPropertiesForKeys: [.isDirectoryKey],
                             options: [.skipsHiddenFiles])
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// Returns files in `url` that have a non-empty path extension, sorted by name.
private func imageFilesIn(_ url: URL) throws -> [URL] {
    try FileManager.default
        .contentsOfDirectory(at: url,
                             includingPropertiesForKeys: [.isRegularFileKey],
                             options: [.skipsHiddenFiles])
        .filter { !$0.pathExtension.isEmpty }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

// MARK: - Output helper

private func printCounts(_ counts: [String: Int]) {
    for dirName in ["earth", "star_sky", "clear_sky", "cloudy_sky"] {
        let n = counts[dirName, default: 0]
        if n > 0 { Log.i("  \(dirName)/: \(n) tile\(n == 1 ? "" : "s")") }
    }
}
