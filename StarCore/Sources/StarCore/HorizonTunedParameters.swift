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
