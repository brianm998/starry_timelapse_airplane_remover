/*

 TileClassifier.swift — CoreML tile classifier wrapper for use in SPM targets.

 The compiled model (tile_classifier.mlmodelc) lives in
   StarCore/Sources/StarCore/Resources/
 and is declared as a `.copy` resource in Package.swift so SPM bundles it.
 `Bundle.module` is the SPM-generated accessor for that bundle — it is
 NOT available in Xcode-project targets; use Bundle.main there instead.

 Workflow when the model is retrained:
   1. python train_tile_classifier.py  ...  (produces tile_classifier.mlpackage)
   2. xcrun coremlc compile tile_classifier.mlpackage \
          StarCore/Sources/StarCore/Resources/
   3. Rebuild the Swift package.

*/

import CoreML
import CoreVideo
import Foundation

// MARK: - Output label enum

/// The four classes the tile classifier can predict.
public enum TileMLClass: String, CaseIterable, Sendable {
    case earth      = "earth"
    case starrySky  = "star_sky"
    case clearSky   = "clear_sky"
    case cloudySky  = "cloudy_sky"
}

// MARK: - Errors

public enum TileClassifierError: Error, CustomStringConvertible {
    case modelNotFound
    case pixelBufferCreationFailed
    case unexpectedOutputLabel(String)

    public var description: String {
        switch self {
        case .modelNotFound:
            return "tile_classifier.mlmodelc not found in StarCore bundle. " +
                   "Run: xcrun coremlc compile tile_classifier.mlpackage " +
                   "StarCore/Sources/StarCore/Resources/"
        case .pixelBufferCreationFailed:
            return "Failed to create CVPixelBuffer from tile data."
        case .unexpectedOutputLabel(let label):
            return "Model returned unrecognised class label '\(label)'."
        }
    }
}

extension MLModel: @unchecked Sendable {
    
}

// MARK: - Classifier

/// Wraps the compiled CoreML tile classifier.
///
/// One instance should be shared and reused — `MLModel` is thread-safe for
/// concurrent prediction calls as of macOS 12 / iOS 15.
public final class TileClassifier: Sendable {

    private let model: MLModel

    // MARK: Initialisation

    /// Loads the model from the StarCore resource bundle.
    /// - Parameter configuration: Passed through to `MLModel`; use this to pin
    ///   compute units (e.g. `.cpuOnly` for background threads).
    public init(configuration: MLModelConfiguration = MLModelConfiguration()) throws {
        guard let url = Bundle.module.url(forResource: "tile_classifier",
                                          withExtension: "mlmodelc") else {
            throw TileClassifierError.modelNotFound
        }
        self.model = try MLModel(contentsOf: url, configuration: configuration)
    }

    // MARK: Prediction — CVPixelBuffer

    /// Classifies a tile supplied as a `CVPixelBuffer`.
    ///
    /// The pixel buffer must be 8-bit BGRA or RGB, `tileSize × tileSize`.
    /// CoreML applies the same normalisation that was baked in at export time
    /// (pixel / 127.5 − 1), so **do not** pre-normalise the buffer yourself.
    public func classify(_ pixelBuffer: CVPixelBuffer) throws -> TileMLClass {
        let featureProvider = try MLDictionaryFeatureProvider(
            dictionary: ["image": MLFeatureValue(pixelBuffer: pixelBuffer)])
        let output = try model.prediction(from: featureProvider)
        guard let label = output.featureValue(for: "classLabel")?.stringValue else {
            throw TileClassifierError.unexpectedOutputLabel("<nil>")
        }
        guard let tileClass = TileMLClass(rawValue: label) else {
            throw TileClassifierError.unexpectedOutputLabel(label)
        }
        return tileClass
    }

    // MARK: Prediction — raw 8-bit RGB bytes

    /// Classifies a tile from a flat `[UInt8]` buffer in **RGB** order,
    /// with `width × height` pixels.
    ///
    /// This is a convenience wrapper that builds a `CVPixelBuffer` internally.
    /// Prefer the `CVPixelBuffer` overload in hot loops to avoid repeated
    /// allocations.
    public func classify(rgbBytes: UnsafeBufferPointer<UInt8>,
                         width: Int,
                         height: Int) throws -> TileMLClass {
        let pixelBuffer = try makePixelBuffer(from: rgbBytes, width: width, height: height)
        return try classify(pixelBuffer)
    }

    // MARK: - Private helpers

    /// Wraps an 8-bit RGB byte buffer in a `CVPixelBuffer` (kCVPixelFormatType_24RGB).
    private func makePixelBuffer(from bytes: UnsafeBufferPointer<UInt8>,
                                 width: Int,
                                 height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_24RGB,
            attrs as CFDictionary,
            &pixelBuffer)

        guard status == kCVReturnSuccess, let pb = pixelBuffer else {
            throw TileClassifierError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let dst = CVPixelBufferGetBaseAddress(pb) else {
            throw TileClassifierError.pixelBufferCreationFailed
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let srcBytesPerRow = width * 3   // tightly packed RGB

        if bytesPerRow == srcBytesPerRow {
            // Fast path: no padding, copy in one shot
            dst.copyMemory(from: bytes.baseAddress!, byteCount: height * srcBytesPerRow)
        } else {
            // Row-by-row copy when the buffer has alignment padding
            for row in 0 ..< height {
                let srcRow = bytes.baseAddress! + row * srcBytesPerRow
                let dstRow = dst + row * bytesPerRow
                dstRow.copyMemory(from: srcRow, byteCount: srcBytesPerRow)
            }
        }

        return pb
    }
}
