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
    /// The buffer must be `kCVPixelFormatType_24RGB`, 8-bit.
    /// CoreML applies the normalisation baked in at export time
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

    // MARK: Prediction — PixelatedImage

    /// Classifies a tile directly from a `PixelatedImage`.
    ///
    /// Bit-depth conversion (→ 8-bit) and BGR → RGB channel reordering are
    /// handled by `PixelatedImage.toPixelBuffer()`.
    public func classify(_ image: PixelatedImage) throws -> TileMLClass {
        guard let pixelBuffer = image.toPixelBuffer() else {
            throw TileClassifierError.pixelBufferCreationFailed
        }
        return try classify(pixelBuffer)
    }
}
