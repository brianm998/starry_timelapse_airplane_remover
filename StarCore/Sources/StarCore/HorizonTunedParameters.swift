import Foundation
import logging

/// Persisted tuning parameters for `HomographyHorizonDetector`.
///
/// When a set of user-supplied reference horizon masks are available (painted
/// in Photoshop to show the true skyline), the pipeline runs a fast
/// coordinate-descent search over these parameters to minimise the mean
/// absolute Y error between the algorithm output and the reference masks.
/// The winning parameter set is written to
/// `{output}/horizonReference/tuned_parameters.json`.
///
/// On subsequent runs the JSON is loaded and applied before running the
/// detector, so the tuned parameters take effect without re-running the
/// search.  Users may also edit the JSON by hand to make fine adjustments;
/// the file will not be overwritten once it exists.
public struct HorizonTunedParameters: Codable, Sendable {

    // MARK: - Algorithm parameters (mirror HomographyHorizonDetector fields)

    /// Half-width (in columns) of the sliding-window average applied to both
    /// warped-mask and error-boundary results.
    public var smoothingRadius: Int = 50

    /// How many pixels above the warped-mask baseline to search for the true
    /// skyline via the alignment-error pass.
    public var errorSearchRange: Int = 400

    /// Half-height (±rows) of the vertical sliding window used to smooth the
    /// per-column error profile before thresholding.
    public var errorBlurRadius: Int = 5

    /// Error at a candidate y must exceed the local sky baseline by at least
    /// this multiplicative factor to be accepted as a sky/ground boundary.
    public var errorThresholdFactor: Double = 2.0

    /// Half-width (in columns) of the horizontal sampling window used when
    /// computing the alignment-error profile.  This is fixed at prepare() time
    /// and not changed during coordinate-descent tuning.
    public var errorSampleHalfWidth: Int = 50

    /// Standard-deviation multiplier for the Pass-2 upward-deviation outlier
    /// guard.  Pass-2 column values that deviate more than this many σ above
    /// the mean deviation are replaced with the Pass-1 baseline.
    public var errorOutlierSigma: Double = 2.5

    /// Maximum pixels the refined horizon may be pushed below the current
    /// frame's merged-horizon baseline.  0 = disabled.  A value like 30 stops
    /// Pass-1 warped masks from reclassifying ground as sky in building/
    /// foreground areas on moving-camera timelapses.
    public var maxDownwardExtension: Int = 0

    // MARK: - Canny snap parameters

    /// Half-height (pixels) of the per-column search band used when snapping
    /// the final horizon Y to the nearest Canny edge.  0 = disabled.
    /// A value around 20–40 pixels is a good starting point.
    public var cannySnapRadius: Int = 0

    /// Canny minimum threshold for the snap step.
    public var cannyMinThreshold: Double = 50

    /// Canny maximum threshold for the snap step.
    public var cannyMaxThreshold: Double = 150

    /// Proximity radius (pixels) used to prefer edge candidates that also
    /// fall near the Pass-1 (warped-mask) horizon.  0 = disabled.
    public var cannyFirstDetectedProximityRadius: Int = 20

    // MARK: - Tuning metadata (informational; not used by the detector)

    /// Mean absolute Y error (pixels) achieved on the reference frames.
    /// `nil` when parameters were set by hand rather than by the auto-tuner.
    public var tuningMeanAbsoluteError: Double?

    /// Number of reference frames used when these parameters were tuned.
    public var tuningFrameCount: Int = 0

    // MARK: - Constants

    /// Filename written inside the `horizonReference` directory.
    public static let jsonFilename = "tuned_parameters.json"

    // MARK: - Init

    public init() {}

    /// Decode key by key, falling back to each property's declared default when a key is absent.
    ///
    /// The synthesised `Decodable` requires every non-optional key to be present — a property's
    /// default value in its declaration does not make its key optional to the decoder.  So a
    /// `tuned_parameters.json` written before any of these fields existed failed to decode at all,
    /// and `load(fromDirectory:)` turned that into a nil: a sequence lost its whole tuning the first
    /// time a parameter was added, silently and with a warning in the log at most.
    ///
    /// Same failure mode as `Config`'s hand-written decoder, for the same reason.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = HorizonTunedParameters()

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
        }

        self.smoothingRadius = value(.smoothingRadius, defaults.smoothingRadius)
        self.errorSearchRange = value(.errorSearchRange, defaults.errorSearchRange)
        self.errorBlurRadius = value(.errorBlurRadius, defaults.errorBlurRadius)
        self.errorThresholdFactor = value(.errorThresholdFactor, defaults.errorThresholdFactor)
        self.errorSampleHalfWidth = value(.errorSampleHalfWidth, defaults.errorSampleHalfWidth)
        self.errorOutlierSigma = value(.errorOutlierSigma, defaults.errorOutlierSigma)
        self.maxDownwardExtension = value(.maxDownwardExtension, defaults.maxDownwardExtension)
        self.cannySnapRadius = value(.cannySnapRadius, defaults.cannySnapRadius)
        self.cannyMinThreshold = value(.cannyMinThreshold, defaults.cannyMinThreshold)
        self.cannyMaxThreshold = value(.cannyMaxThreshold, defaults.cannyMaxThreshold)
        self.cannyFirstDetectedProximityRadius =
          value(.cannyFirstDetectedProximityRadius, defaults.cannyFirstDetectedProximityRadius)
        self.tuningMeanAbsoluteError =
          (try? container.decodeIfPresent(Double.self, forKey: .tuningMeanAbsoluteError)) ?? nil
        self.tuningFrameCount = value(.tuningFrameCount, defaults.tuningFrameCount)
    }

    // MARK: - Persistence

    /// Load from `{directory}/tuned_parameters.json`.
    ///
    /// Returns `nil` if the file does not exist or cannot be decoded.
    public static func load(fromDirectory directory: URL) -> HorizonTunedParameters? {
        let url = directory.appendingPathComponent(jsonFilename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else {
            Log.w("HorizonTunedParameters: could not read \(url.path)")
            return nil
        }
        do {
            let params = try JSONDecoder().decode(HorizonTunedParameters.self, from: data)
            Log.i("HorizonTunedParameters: loaded from \(url.path) " +
                  "(MAE: \(params.tuningMeanAbsoluteError.map { String(format: "%.1f", $0) } ?? "n/a"), " +
                  "frames: \(params.tuningFrameCount))")
            return params
        } catch {
            Log.w("HorizonTunedParameters: decode failed for \(url.path): \(error)")
            return nil
        }
    }

    /// Save to `{directory}/tuned_parameters.json`.
    ///
    /// Creates the directory if it does not exist.
    public func save(toDirectory directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let url = directory.appendingPathComponent(HorizonTunedParameters.jsonFilename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
        Log.i("HorizonTunedParameters: saved to \(url.path)")
    }
}
