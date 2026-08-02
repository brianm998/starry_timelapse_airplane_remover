import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession, URLRequest live here on Linux
#endif
import logging
#if canImport(SwiftUI)
import SwiftUI
#endif

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

 */

/*

 We need a config manager class

 an main actor which holds a config

 and knows how to save it again

 use this same config manager for all config accesses

 use this to allow changes in config at runtime in the gui to be used by StarCore

 The config manager can give the latest config, which is then used within a method

 save and load config in background
 
 */

@MainActor 
public class ConfigManager {
    private var _jsonFilename: String

    private var _config: Config

    private var updateCallbacks: [(Config) -> Void] = []

    /// Shared state for adaptive horizon parameter search across frames.
    /// This allows subsequent frames to narrow their search based on what worked
    /// for previous frames in the same sequence.
    public let adaptiveHorizonState = AdaptiveHorizonState()

    /// Shared SQLite database for neighbor homography results.
    /// All frames in a sequence share one instance via their shared ConfigManager.
    public let homographyDatabase: HomographyDatabase

    public init() {
        _jsonFilename = ""
        _config = Config()
        homographyDatabase = HomographyDatabase(tempOutputPath: _config.tempOutputPath)
    }

    public init(configFilename: String, config: Config) {
        self._jsonFilename = configFilename
        self._config = config
        homographyDatabase = HomographyDatabase(tempOutputPath: config.tempOutputPath)
    }

    public init(configFilename: String) throws {
        self._jsonFilename = configFilename
        if FileManager.default.fileExists(atPath: _jsonFilename) {
            self._config = try Config.read(fromJsonFilename: _jsonFilename)
        } else {
            self._config = Config()
        }
        homographyDatabase = HomographyDatabase(tempOutputPath: _config.tempOutputPath)
    }

    public func onUpdate(closure: @escaping @Sendable (Config) -> Void) {
        updateCallbacks.append(closure)
    }
    
    public func save() {
        _config.writeJson(named: _jsonFilename, overwrite: true) 
    }

    public func jsonFilename() -> String { _jsonFilename }
    
    public func config() -> Config { _config }

    /// Replace the managed config and notify observers.
    ///
    /// Pass `save: false` when the caller persists the config itself. `save()` goes
    /// through `Config.writeJson`, which resolves a filename that isn't prefixed by
    /// `tempOutputPath` against `tempOutputPath` — so for an absolute json path
    /// (as stard uses) saving here would write to a bogus location.
    public func update(_ config: Config, save shouldSave: Bool = true) {
        self._config = config
        if shouldSave { save() }
        for callback in updateCallbacks {
            callback(config)
        }
    }
}

public struct Config: Codable, Sendable {
 
    public init() {
        self.outputPath = "."
        self.tempOutputPath = "."
        self.cleanMethod = .automatic(false)
        self.detectionType = .strong
        //self.numConcurrentRenders = 0
        self.imageSequenceDirname = ""
        self.imageSequencePath = ""
        self.writeOutlierGroupFiles = false
        self.writeFramePreviewFiles = false
        self.writeFrameProcessedPreviewFiles = false
        self.writeFrameThumbnailFiles = false
    }

    // returns a stored json config file
    public static func read(fromJsonFilename filename: String) throws -> Config {
        let config_url = NSURL(fileURLWithPath: filename, isDirectory: false) as URL

        let config_data = try Data(contentsOf: config_url)
        //let (config_data, _) = try await URLSession.shared.data(for: URLRequest(url: config_url))
        let decoder = JSONDecoder()
        let config = try decoder.decode(Config.self, from: config_data)

        return config
    }

    public init(
      outputPath: String?,
      cleanMethod: CleanMethod = .automatic(false),
      detectionType: DetectionType = .strong,
      imageSequenceName: String,
      imageSequencePath: String,
      writeOutlierGroupFiles: Bool,
      writeFramePreviewFiles: Bool,
      writeFrameProcessedPreviewFiles: Bool,
      writeFrameThumbnailFiles: Bool
    ) {
        let prefix = "star_temp_\(imageSequenceName)"
        
        if let outputPath {
            self.tempOutputPath = "\(outputPath)/\(prefix)"
            self.outputPath = outputPath
        } else {
            self.tempOutputPath = "./\(prefix)"
            self.outputPath = "."
        }
        
        self.cleanMethod = cleanMethod
        self.detectionType = detectionType
        self.imageSequenceDirname = imageSequenceName
        self.imageSequencePath = imageSequencePath
        self.writeOutlierGroupFiles = writeOutlierGroupFiles
        self.writeFramePreviewFiles = writeFramePreviewFiles
        self.writeFrameProcessedPreviewFiles = writeFrameProcessedPreviewFiles
        self.writeFrameThumbnailFiles = writeFrameThumbnailFiles
    }

    // the base dir under which to create dir(s) for output sequence(s)
    public var outputPath: String

    // the base dir under which to create dir(s) for output sequence(s)
    public var tempOutputPath: String

    // the default pixel replement method for this sequence
    public var cleanMethod: CleanMethod

    // any frame specific overrides to the default pixel replacement method
    // indexed by frame number
    public var pixelReplacementOverrides: [Int:CleanMethod] = [:]

    public func cleanMethod(for frameIndex: Int) -> CleanMethod {
        if let method = pixelReplacementOverrides[frameIndex] {
            method
        } else {
            cleanMethod
        }
    }

    // per-frame overrides for numberStaticNeighborFrames, indexed by frame number.
    // allows specific frames to use a larger (or smaller) neighbor count for the
    // merged horizon computation without slowing down the whole sequence.
    public var staticNeighborFrameOverrides: [Int:Int] = [:]

    public func numberStaticNeighborFrames(for frameIndex: Int) -> Int {
        if let override = staticNeighborFrameOverrides[frameIndex] {
            override
        } else {
            numberStaticNeighborFrames
        }
    }

    // per-frame overrides for numberAlignedNeighborFrames, indexed by frame number.
    // allows specific frames to use a different neighbor count for star alignment
    // without changing the default for the whole sequence.
    public var alignedNeighborFrameOverrides: [Int:Int] = [:]

    public func overriddenNeighborCount(for frameIndex: Int) -> Bool {
        if let _ = alignedNeighborFrameOverrides[frameIndex] {
            return true
        } else {
            return false
        }
    }
    
    public func numberAlignedNeighborFrames(for frameIndex: Int) -> Int {
        if let override = alignedNeighborFrameOverrides[frameIndex] {
            override
        } else {
            numberAlignedNeighborFrames
        }
    }
    
    // used with CleanMethod.selective and .automatic(true)
    public var detectionType: DetectionType

    // was the tripod head static, or moving?  Static assumed when not set.
    public var tripodHeadWasMoving: Bool = false
    
    // the name of the directory containing the input sequence
    public var imageSequenceDirname: String

    // where the input image sequence dir lives
    public var imageSequencePath: String
    
    // write out individual outlier group images
    public var writeOutlierGroupFiles: Bool

    public var writeOutlierClassificationValues: Bool = false
    
    // write out a preview file for each frame
    public var writeFramePreviewFiles: Bool

    // write out a processed preview file for each frame
    public var writeFrameProcessedPreviewFiles: Bool

    // write out a small thumbnail preview file for each frame
    public var writeFrameThumbnailFiles: Bool

    /// Write each frame's output image, rather than only its outlier data.
    ///
    /// False is star's "analyse but do not render" mode, driven by the cli's
    /// `--skip-output-files`: `FrameAirplaneRemover.finishAuto` and `finishSelective`
    /// both write the outlier remove reasons and, if asked, the classification value
    /// CSV, and then return before writing any image.  Useful for gathering classifier
    /// training data over a sequence there is no intention of rendering.
    ///
    /// It saves the image writes rather than the work behind them: the outliers come out
    /// of subtracting the merged frame, so the alignment and the merge still run.  It is
    /// also only meaningful for a `cleanMethod` where `usesOutliers` is true — under
    /// `.automatic(false)` there is no outlier data, so a run writes nothing whatsoever.
    ///
    /// Like every other config field the command line can set, this is saved into
    /// config.json, so a resume that does not repeat `--skip-output-files` still skips
    /// them.  That is why that flag, unlike star's other `@Flag`s, has a `--no-` form:
    /// without one, a single `-s` run would leave a config that could never render again.
    /// The gui always renders and ignores this.
    public var writeOutputFiles: Bool = true

    // how far in each direction do we go when doing final processing?
    // used for OutlierGroupFeature data
    public var numberFinalProcessingNeighborsNeeded = 2 // in each direction

    // align this many total neighbor frames for both
    // creating the subtraction image and calculating pixel values during removal
    public var numberAlignedNeighborFrames = 8 // total

    // use when smoothing homography of moving videos
    // smaller values give more smoothing
    public var homographySmoothingEpsilon = 1e-2 // get this right

    // when camera is not moving, use this value instead of
    // numberAlignedNeighborFrames for calculating the merged horizon for each frame
    public var numberStaticNeighborFrames = 16 // total
    
    // this can stay this way more easily now that star supports video import to .tiff directly

    // really this should be filtered with cv::haveImageReader("image.exr");
    // and it is not specific to an image sequence, move it elsewhere
    public var supportedImageFileTypes = [".tif", ".tiff", "jpg", "jpeg", "png", "bmp", "ndr", "ppm", "pgm", "pdm"]

    // Fraction of physical memory that star is allowed to reserve for in-flight ops.
    // Value between 0.1 and 0.95.
    public var maxMatMemoryFraction: Double = 0.85

    // Per-op memory multipliers: rawImageBytes × multiplier = estimated reservation.

    /// Estimated peak memory of one keypoint op, as a multiple of the raw frame.
    ///
    /// Measured rather than guessed: detecting on a 42MP 16-bit 3-channel frame
    /// through `ia_find_features` peaks at 9921MB of process RSS against a 241.3MiB
    /// raw frame — 41.1x, rounded up to 42 so the estimate covers the measurement
    /// rather than sitting just under it. SIFT's scale space is the bulk of that and
    /// costs a near-constant ~210 bytes per pixel of whatever image it is handed, so
    /// the ratio holds across resolutions (36.5x measured at 12MP for the detector
    /// alone). It is therefore NOT true that bigger images need a bigger multiplier.
    ///
    /// Re-confirmed since, one op per fresh process against the real
    /// `ia_find_features` — the only way to size this downward, per `MemoryProbe`.
    /// Whole-op peak (load included), as a multiple of `workingFrameBytes`:
    ///
    ///     12MP sky   2672MB  38.9x   93% of the reservation
    ///     24MP sky   5189MB  37.8x   90%   (5187-5214MB over four runs)
    ///     42MP sky   9666MB  40.0x   95%   (9664-9669MB over three runs)
    ///     24MP earth 2817MB  20.5x   49%
    ///     42MP earth 4511MB  18.7x   45%
    ///
    /// Two things follow. Sky (SIFT) is the binding case: earth (AKAZE) costs about
    /// half, so the shared multiplier covers it with room to spare. And there is only
    /// ~5% headroom at 42MP, so this is not a value to shave — the ratio drifts up
    /// slightly with frame size, and 42MP is where the machine already hurts.
    ///
    /// A mask changes nothing (37.8x unmasked vs 38.0x masked at 24MP): the scale space
    /// is built over the whole frame either way, and the mask only filters what is kept.
    ///
    /// This value is only the memory estimate. It used to double as the sole way to
    /// limit keypoint concurrency — the limiter divides the budget by it — so raising
    /// it to calm a large sequence also silently inflated every reservation, and
    /// correcting it to the real figure loosened concurrency. Use
    /// `maxConcurrentKeypointOps` to bound concurrency directly instead.
    public var keypointMemoryMultiplier: Int = 42

    /// What one keypoint op should reserve, as a multiple of the working frame, given the
    /// detection divisor.
    ///
    /// `keypointMemoryMultiplier` was measured entirely at full resolution, and until this
    /// existed nothing reduced it when detection ran on a smaller copy — so a half-res run
    /// reserved 42x for work that peaks near a quarter of that, and got the concurrency of
    /// a full-res run for no reason. That is pure lost throughput on exactly the setting
    /// someone reaches for when they are short of memory.
    ///
    /// Split rather than scaled whole, because only part of the peak is the detector. Of
    /// the measured 42x, ~38x is SIFT's scale space at a near-constant ~210 bytes per
    /// pixel of the image it is handed, which falls as `1/divisor²`; the remaining ~4x is
    /// the original frame, its gray copy and the mask, which do not shrink because the
    /// downscale happens after them.
    ///
    ///     divisor   scale space   fixed   total    independently measured
    ///     1.0            38         4      42      41.1x at 42MP
    ///     1.5            17         4      21      not yet measured
    ///     2.0           9.5         4      14      9.5-12x (two runs: 4.43x and 3.5x
    ///                                              reductions from 42x)
    ///
    /// The 2.0 row is deliberately the conservative end of those two measurements: 14
    /// over-reserves against both rather than splitting them, because under-reserving
    /// costs the machine while over-reserving only costs concurrency.
    public func effectiveKeypointMemoryMultiplier() -> Int {
        let divisor = quantizedKeypointDivisor
        guard divisor > 1.0 else { return keypointMemoryMultiplier }

        let fixed = 4
        let scaleSpace = max(keypointMemoryMultiplier - fixed, 0)
        let scaled = Int((Double(scaleSpace) / (divisor * divisor)).rounded(.up))
        return max(fixed + scaled, 1)
    }

    /// Explicit cap on how many keypoint ops may run at once. 0 means "no explicit
    /// cap": the limit comes from the memory budget and
    /// `numberOfFramesToProcessConcurrently` alone.
    ///
    /// This is a cap, not an override — it can only lower the limit, never raise it
    /// above what the budget allows. Reach for this when you want to be more
    /// conservative than the budget math, instead of inflating
    /// `keypointMemoryMultiplier`, which distorts the accounting for every op.
    public var maxConcurrentKeypointOps: Int = 0

    /// Byte budget for the in-memory keypoint cache, in megabytes. 0 = unbounded.
    ///
    /// The cache deduplicates keypoint-file parsing across neighbouring HomographyOps,
    /// and it held strong references with no bound: one entry per frame per alignment
    /// type, so 2000 entries on a 1000-frame sequence. Sky entries are ~1MB (capped by
    /// `alignmentMaxKeypoints`) but earth entries are not capped at all — AKAZE runs with
    /// a 1e-5 threshold and ignores `maxKeypoints` — so per-entry size varies by orders
    /// of magnitude and an entry-count limit would not bound anything. Hence bytes.
    ///
    /// The access pattern is local: a HomographyOp reads only its own neighbours. So this
    /// only needs to cover roughly `numberOfFramesToProcessConcurrently x
    /// numberAlignedNeighborFrames` entries for the hit rate to stay high.
    public var keypointCacheMaxMB: Int = 1024

    /// Estimated peak memory of one merge op, and of one outlier op, as a multiple of
    /// the raw frame — NOT counting the sources of a merge inside the op that keeps
    /// them all in memory. Charge an op with `effectiveMergeMemoryMultiplier` /
    /// `effectiveOutlierMemoryMultiplier`, which add that back when it applies;
    /// nothing should use these two values directly.
    ///
    /// Either op can be the one that builds an aligned frame, which is why both share
    /// the resident term below. A streaming build warps or decodes one source at a
    /// time and spills it (`ia_align_and_median_merge`,
    /// `ia_median_merge_image_with_filenames`), so it peaks at the original, one
    /// source, one warp and the merge output no matter how many neighbours there are.
    /// Measured in a fresh process, one 9-source aligned merge at 42MP against a
    /// 241.3MiB raw frame: 727MB streaming (3.02x) versus 2178MB resident (9.02x).
    ///
    /// On top of that build, measured at 12MP with streaming forced on. These runs used
    /// `--num-concurrent-renders 2`, not 1 as MemoryProbe advises, because concurrency
    /// 1 stalls the keypoint phase. Two ops in flight means the reported deltas come in
    /// pairs — both ops of a pair are charged the same process growth — so what the
    /// pair figure has to fit inside is TWO reservations, not one:
    ///   - merge ops peaked at 3.0x per pair with `cleanMethod = .automatic` and 5.2x
    ///     with `.selective`, which also holds the original and an `ensure16Bits` clone
    ///     of the earth-aligned frame, against 12x for the pair at 6 each;
    ///   - outlier ops peaked at 11.5x per pair, typically 4.3x, against 18x for the
    ///     pair at 9 each. The blobber is the bulk of it. That is why the outlier figure
    ///     is now the larger of the two, where before both were pinned to the aligned
    ///     build.
    ///
    /// The blobber has since been measured directly — `FullFrameBlobber` in a fresh
    /// process, one frame, nothing else running — and it does not have a single peak.
    /// It has a floor plus a term in how many pixels are bright, because a
    /// `SortablePixel` is stored for every pixel above `minPixelIntensity` and for every
    /// pixel dim enough that its contrast falls under `startMinContrast`, which for the
    /// strong defaults (6000, 70) means everything above 1800. Blobber only, as a
    /// multiple of the working frame, at 24MP and again at 42MP:
    ///
    ///     bright pixels    24MP           42MP
    ///     none (floor)     183MB  1.3x    322MB  1.3x
    ///     0.001%           203MB  1.5x
    ///     0.01%            366MB  2.7x
    ///     0.1%             748MB  5.4x
    ///     1%               873MB  6.4x   1524MB  6.3x
    ///     15.7%            960MB  7.0x
    ///
    /// Add the original and the `[UInt16]` subtraction copy that the op holds across all
    /// of this and the process peak runs 2.7x at the floor to 8.7x at the top — against
    /// 9x. So 9 covers a realistically-aligned frame, where densities sit in the tenths
    /// of a percent, and it has very little left over for the rest of the op (the Hough
    /// connector, the trimmers, outlier group construction, the saves). Density is the
    /// variable to watch, not frame size: every ratio above is the same at 24MP and
    /// 42MP. The 15.7% row is an upper bound — it comes from subtracting an UNALIGNED
    /// neighbour, so every star that moved survives as residual.
    ///
    /// Two corrections to the walk-through above, which under-counted:
    ///   - the 8-bytes-per-pixel array is `PixelStatusTracker.pixelStatus`
    ///     (`[SortablePixel.Status]`, one slot per pixel, allocated up front). That is
    ///     the whole of the 1.3x floor, and it is the only part that does not depend on
    ///     the data.
    ///   - `[[SortablePixel?]]` is 24 bytes per pixel, not 8 (`SortablePixel` is 21
    ///     bytes, 24-byte stride, and the optional is free — it uses a spare
    ///     inhabitant). At 24MP that grid is 549MB, 4x on its own. It is NOT paid up
    ///     front, though: `Array(repeating: innerArray, count: width)` gives every
    ///     column a reference to one shared buffer, so a column only materializes its
    ///     4000 optionals when a pixel in it is stored. The cost is therefore per
    ///     touched column, and it saturates once outliers are spread across the frame —
    ///     which takes about 0.1% of pixels, hence the jump to 5.4x there.
    ///
    /// `tripodHeadWasMoving` used to add 8 warped horizon masks to an outlier op; the
    /// aligned merge no longer produces those at all, since its one caller discarded
    /// them.
    public var outlierMemoryMultiplier: Int = 9
    public var mergeMemoryMultiplier: Int = 6

    /// Estimated peak memory of one horizon op, as a multiple of the working frame.
    ///
    /// Was 2, and it was the only reservation real data caught short. Instrumenting a
    /// 24MP run (`--log-op-memory`), the first horizon op grew the process by 753MB
    /// against a 274MB charge — 5.5x, i.e. 274% of its reservation. Later horizon ops
    /// reported 84MB, but that is the footprint artifact described on `MemoryProbe`
    /// rather than cheaper work: both frames log the same detection path, and the second
    /// one is simply reusing pages the first had already faulted in.
    ///
    /// So the honest figure for the op that runs first — and one always does — is 5.5x.
    ///
    /// 7 rather than 6, which would have covered the measurement with only 8% to spare.
    /// Most of that 756MB is one-time process start-up — runtime and OpenCV
    /// initialisation, decision-tree loading, first touch of the loaded frame — rather
    /// than the horizon detector itself. That part is roughly constant, so expressing it
    /// as a multiple of the frame is the wrong shape for it: the same fixed cost reads as
    /// ~3x at 42MP and ~19x at 6MP. This value is therefore calibrated at 24MP and errs
    /// toward under-reserving below that, and a fixed component that varies with the
    /// machine and the build does not deserve a thin margin.
    ///
    /// Over-reserving is close to free here: at 7x even a 16GB machine admits 14
    /// concurrent horizon ops, so `numberOfFramesToProcessConcurrently` binds long before
    /// the budget does.
    ///
    /// That fresh-process measurement has since been done — `CombinedHorizonDetector`
    /// called directly, one detection per cold process. It confirms the "wrong shape"
    /// suspicion above, gives it a mechanism, and shows the multiplier is genuinely short
    /// below 24MP. First detection in a cold process:
    ///
    ///     frame  working  peak    xframe  % of 7x
    ///      6MP     34MB   424MB   12.3x    176%   <- under-reserved
    ///     12MP     69MB   633MB    9.2x    132%   <- under-reserved
    ///     24MP    137MB   723MB    5.3x     75%
    ///     42MP    241MB   966MB    4.0x     57%
    ///
    /// The cost barely moves with frame size — 424MB to 966MB while pixels grow 7x —
    /// because the detector does almost all its work at FIXED internal resolution:
    /// `Params.baseWorkingSize` is 512 for Otsu/DP/SIOX, and `rwMaxWorkingWidth` caps
    /// the Random Walker at 4096. Only loading and scaling the frame track its real
    /// size. Fitting the rows above: about 350MB of fixed detector workspace plus
    /// ~11MB per megapixel. A multiple of the frame cannot express that, which is why
    /// this reads as 4x where it was calibrated and 12.3x at 6MP.
    ///
    /// The start-up/work split, which the in-run numbers could not separate:
    ///   - genuinely one-time per process is only ~155MB (the footprint still held after
    ///     the first detection settles: 157, 153, 173 and 152MB at 6, 12, 24 and 42MP —
    ///     flat, as a runtime/OpenCV init cost should be).
    ///   - the rest is per-op transient, and it does NOT amortise across concurrent ops.
    ///     At 24MP, K cold detections at once peak at 723MB (K=1), 1295MB (K=2) and
    ///     2273MB (K=4) — about 150MB fixed plus 530-570MB for every op in flight. So
    ///     the per-op reservation is the right idea even though its unit is wrong.
    ///   - sequential ops in a warm process report +0 to +51MB, which is the `MemoryProbe`
    ///     artifact, not cheap work: each still produces a full mask, and still takes its
    ///     several seconds. Reading those as the steady-state cost would argue for
    ///     lowering this value, and the concurrent figures show that would be wrong.
    ///
    /// What this wants is a floor in bytes rather than a larger multiplier, which is what
    /// `horizonReservationFloorMB` below now supplies. Do not raise this multiplier to
    /// cover the small end: 12.3x would be needed at 6MP, and that same 12.3x at 42MP
    /// would reserve 2966MB against a measured 966MB.
    public var horizonMemoryMultiplier: Int = 7

    /// Floor, in megabytes, under which one horizon op's reservation must not fall.
    ///
    /// A horizon op's cost is mostly fixed, not per-pixel — see the measurements on
    /// `horizonMemoryMultiplier`. The detector runs Otsu/DP/SIOX at
    /// `CombinedHorizonDetector.Params.baseWorkingSize` (512) and caps the Random Walker
    /// at `rwMaxWorkingWidth` (4096), so shrinking the input frame barely shrinks the
    /// work: 424MB at 6MP against 966MB at 42MP, for 7x the pixels. Expressed as a
    /// multiple of the frame that inverts, and the multiplier is short exactly where the
    /// frame is small — 176% of its reservation at 6MP, 132% at 12MP, both measured.
    ///
    /// 900MB. The cost fits `~505MB + 11MB/MP`, and the floor only binds below ~17MP,
    /// where `horizonMemoryMultiplier` overtakes it — so the worst case it has to cover
    /// is that crossover, ~700MB, and 900 leaves ~29% for the machine-to-machine and
    /// build-to-build variance in the fixed part. It is deliberately under the 961MB that
    /// 7x already gives at 24MP, so this changes nothing at or above the size the
    /// multiplier was calibrated on.
    ///
    /// 0 disables the floor.
    public var horizonReservationFloorMB: Int = 900

    /// `horizonMemoryMultiplier`, raised if needed so the reservation clears
    /// `horizonReservationFloorMB`.
    ///
    /// A multiplier rather than a byte count because that is the only unit
    /// `AsyncOperation` takes, and keeping the floor here means every horizon op picks it
    /// up without each call site doing its own arithmetic. Rounds the floor UP to a whole
    /// multiple, so the reservation covers the floor rather than landing just under it.
    ///
    /// Applies to every horizon op, not just `HorizonDetectionOp`: the merge and
    /// refinement ops reach `loadOrCreateFinalHorizonMask`, which falls back to
    /// `loadOrCreateHorizonMask` — the detector — whenever there is no merged mask to
    /// load. Any of them can therefore be the one that pays this.
    public func effectiveHorizonMemoryMultiplier() -> Int {
        let working = workingFrameBytes
        // 0 means the frame size is not known yet, which already disables gating
        // entirely (reservation = 0 x anything). Do not invent a reservation here.
        guard working > 0, horizonReservationFloorMB > 0 else {
            return horizonMemoryMultiplier
        }
        let floorBytes = UInt64(horizonReservationFloorMB) * 1024 * 1024
        let floorMultiplier = (floorBytes + working - 1) / working   // round up
        return max(horizonMemoryMultiplier, Int(floorMultiplier))
    }

    // used by updatable log
    public var progressBarLength = 35

    public var previewWidth: Int = defaultPreviewWidth
    public var previewHeight: Int = defaultPreviewHeight

    // if set outlier groups that are not further than this from the bottom
    // of the image will be ingored
    public var ignoreLowerPixels: Int = 0

    // XXX try making these larger now that video plays better
    public static let defaultPreviewWidth: Int = 1617 // 1080p in 4/3 aspect ratio
    public static let defaultPreviewHeight: Int = 1080
    
    public var thumbnailWidth: Int = defaultThumbnailWidth
    public var thumbnailHeight: Int = defaultThumbnailHeight

    nonisolated(unsafe) public static var defaultThumbnailWidth: Int = 80
    nonisolated(unsafe) public static var defaultThumbnailHeight: Int = 60

    // how far away from an outlier group pixel do we keep painting?
    public static let defaultOutlierGroupPaintBorderPixels: Double = 8

    // how far away from an outlier group pixel do we paint fully?
    // the distance between here and defaultOutlierGroupPaintBorderPixels is blended
    public static let defaultOutlierGroupPaintBorderInnerWallPixels: Double = 2

    // how many pixels out from the edge of an outlier group to paint further
    // pixels less than distance will be painted over with a fade until
    // outlierGroupPaintBorderInnerWallPixels reached.
    public var outlierGroupPaintBorderPixels: Double = defaultOutlierGroupPaintBorderPixels

    // where the fade of the alpha on the border begins.
    // pixels closer than this are fully painted over
    public var outlierGroupPaintBorderInnerWallPixels: Double = defaultOutlierGroupPaintBorderInnerWallPixels

    // the frame rate of the incoming and outgoing video
    public var frameRate: FrameRate = .fps_30

    // the codec of the incoming and outgoing video
    public var codec: FFmpegCodec = .prores

    // the encoder to use to encode the resulting video
    public var encoder: FFmpegEncoder = .prores

    // the pixelformat of the incoming and outgoing video
    //
    // Has to be one the default encoder above can actually emit.  This was yuv422p14le, which
    // none of the four prores encoders supports — prores is a 10 bit codec, and only ffvhuff,
    // ffv1 and libopenjpeg take a 14 bit format.  yuv422p10le is what ProRes 422 really uses.
    //
    // The gui never showed the problem because RenderVideoSheetView substitutes
    // encoder.pixelFormats[0] whenever the config's format is missing from the encoder's list.
    // The daemon's export has no such guard: ExportHandlers passes this straight through as
    // `-pix_fmt`, so an export with untouched settings handed ffmpeg a combination it rejects.
    public var pixelFormat: FFmpegPixelFormat = .yuv422p10le

    // the muxer (container) of the incoming and outgoing video
    public var muxer: FFmpegMuxer = .mov

    // did the incoming video have an audio track?
    public var hasAudio: Bool = false

    // do horizon processing or not.
    // if not set, defaults to true
    public var horizonDetectionEnabled: Bool = true

    // true when the user has painted a reference horizon for a static sequence,
    // so FrameGraphBuilder can skip per-frame detection and merge operations.
    public var hasStaticReferenceHorizon: Bool = false

    // when true and tripodHeadWasMoving is set, frames that are within
    // referenceHorizonSmoothingMaxDistance of a user-defined reference horizon
    // frame have their computed horizon filtered against that reference to weed
    // out statistically implausible column values, before the result is saved as
    // the merged horizon.  Frames outside the distance window fall through to the
    // normal median-merge smoothing pass.
    public var useReferenceHorizonSmoothing: Bool = true

    // maximum frame distance (inclusive) from a user-defined reference horizon
    // within which reference-based smoothing is applied.
    public var referenceHorizonSmoothingMaxDistance: Int = 30

    // when true and tripodHeadWasMoving is set, refine per-pixel sky/ground classification
    // in a band around the horizon using brightness and Y-position evidence from the
    // nearest 1–2 user-defined reference horizon frames.
    public var useReferenceHorizonBrightnessRefinement: Bool = true

    // half-height of the per-pixel refinement band in pixels, measured from the widest
    // possible horizon Y bounds across the nearby reference frames.
    public var referenceHorizonBrightnessRefinementSearchRadius: Int = 100

    // number of buckets in the per-region intensity histograms used by the brightness
    // refinement step.  Higher values give finer intensity resolution at the cost of
    // sparser bucket counts when few reference pixels are available.
    public var referenceHorizonBrightnessRefinementHistogramBuckets: Int = 256

    // odd side length of the square neighbourhood used when sampling pixel colour/intensity
    // for reference-horizon statistics and per-pixel refinement.  For a given pixel the
    // neighbourhood average (excluding cross-boundary pixels in the stats pass) is used
    // instead of the single centre value, giving more stable colour estimates near the
    // horizon.  Must be a positive odd integer; even values are treated as the next lower
    // odd number (e.g. 4 → 3×3).  Set to 1 to use single-pixel sampling (legacy behaviour).
    public var referenceHorizonNeighborhoodSize: Int = 5

    // when true, a spike-removal pass runs on the per-column horizon Y after brightness
    // refinement, eliminating narrow upward protrusions (wind turbines, towers, etc.).
    public var horizonSpikeRemovalEnabled: Bool = true

    // maximum run of consecutive columns that qualifies as a spike (wider runs are
    // treated as legitimate terrain features and left unchanged).
    public var horizonSpikeMaxWidth: Int = 30

    // spike trigger threshold expressed as a fraction of image height.  A column whose
    // horizon Y is more than (fraction × imageHeight) pixels above the local median is
    // considered the top of a spike.
    public var horizonSpikeMaxDeviationFraction: Double = 0.02

    // half-width of the local-median window (in columns) used for spike detection.
    // A wider window is more robust: the spike value itself is a smaller fraction of
    // the median sample, so the median is less pulled toward the spike.
    public var horizonSpikeWindowHalf: Int = 300

    // use the combined+RW horizon detector (Otsu + DP + SIOX → median → Random Walker)?
    // when true, this replaces the legacy adaptive Otsu/DP search in loadOrCreateHorizonMask.
    // set to false to fall back to the previous adaptive search approach.
    public var useCombinedHorizonDetection: Bool = true

    // the max size of each strip used to calculate the horizon image.
    // smaller strips can help reduce noise especially around the edges of the frame
    // too small and the horizon can get calculated wrong
    public var horizonStripWidth: Int = 200

    // should we use canny edge detection along with otsu for horizon detection?
    // or just otsu?  Defaults to true (use both)
    public var useCannyForHorizonDetection: Bool = true

    // min threshold for canny edge detection for finding horizons
    public var cannyMinThreshold: Double = 50

    // max threshold for canny edge detection for finding horizons
    public var cannyMaxThreshold: Double = 120

    // should canny edge detection use the L2 Gradient or edge gradient?
    // true is for the L2Gradient, which is the default
    public var cannyUseL2Gradient: Bool = true
    
    // the vertical bounds of the horizon over the entire image sequence, if known
    public var horizonMinY: Int?
    public var horizonMaxY: Int?

    public var numberOfFramesToProcessConcurrently: Int = ProcessInfo.processInfo.processorCount
    
    // when doing auto aligned outputs, how far to shift up the horizon mask
    // when doing a final composite image.
    public var horizonVerticalShiftAmount: Int = 8

    // try to align earth on moving frames?
    // turned off by default as it's still expermintal
    public var allowEarthAlignment: Bool = false

    // --- Adaptive horizon detection parameters ---

    // What size do we detect the horizon at?
    // Lower values are faster but less precise
    // expressed as [width, height] 
    public var horizonSearchSize: [Int] = [384, 384]

    // [min, max] bounds for the crop percentage search range.
    // Each value is a percentage (0-100) of the image height to ignore from the top.
    // The actual crop amounts tested are computed by dividing this range into
    // horizonSearchCropCount1 evenly spaced steps for the first pass, then
    // horizonSearchCropCount2 steps for a refined second pass around the first best.
    // An empty array disables adaptive search.
    public var horizonSearchCropBounds: [Double] = [10, 90]

    // Number of evenly spaced crop percentage values to test in the first pass.
    // The range defined by horizonSearchCropBounds is divided into this many steps.
    // e.g. bounds=[30,70] and count1=5 produces [30, 40, 50, 60, 70].
    public var horizonSearchCropCount1: Int = 16

    // Number of evenly spaced crop percentage values to test in the second
    // refinement pass. The second pass search area is centered on the first pass
    // best value and spans one first-pass step in each direction, divided into
    // this many steps.
    // e.g. if first pass step=10 and best=50, second pass searches [40..60]
    // divided into horizonSearchCropCount2 steps.
    public var horizonSearchCropCount2: Int = 24

    // After the first frame's horizon is detected, narrow the search area for
    // subsequent frames. This is the number of percentage points to add above
    // and below the previously detected best crop amount.
    // e.g. if best crop was 50 and this is 15, next frame searches [35, 50, 65].
    public var horizonSearchNarrowingRange: Double = 20

    // [min, max] range for the DP smoothness penalty (cost per pixel of vertical
    // displacement). Higher = smoother horizon line. Typical range: 0.5–5.0.
    // Set both values equal (and count=1) to use a single fixed value.
    public var dpHorizonSmoothnessLambdaRange: [Double] = [1, 2]

    // Number of evenly-spaced lambda values to test within the range above.
    // 1 = use only the min (or both equal) value. Higher = finer grid search.
    public var dpHorizonSmoothnessLambdaCount: Int = 4

    // [min, max] range for the Sobel vertical gradient weight in the DP cost.
    // Higher values make the path follow strong intensity transitions more.
    public var dpHorizonSobelWeightRange: [Double] = [0.2, 1.2]

    // Number of evenly-spaced Sobel weight values to test within the range above.
    public var dpHorizonSobelWeightCount: Int = 4

    // [min, max] range for the Canny edge presence weight in the DP cost.
    // Higher values make the path follow detected edges more.
    public var dpHorizonCannyWeightRange: [Double] = [0.2, 1.2]

    // Number of evenly-spaced Canny weight values to test within the range above.
    public var dpHorizonCannyWeightCount: Int = 4

    public var alignmentMaxKeypoints: Int = 2000
    public var alignmentWriteDebugImages: Bool = false
    public var alignmentGroundHorizonExtension: Int = 100 // extend the horizon for ground by this amount to get more keypoints
    public var alignmentSkyHorizonExtension: Int = 40
    public var alignmentBaseImageDilateSize: Int = 20
    public var alignmentBaseImageThresholdValue: Int = 100

    /// Divide each frame's dimensions by this before detecting keypoints on it.
    /// 1.0 detects at full resolution, 2.0 on a half-size copy, 1.5 on a two-thirds copy.
    ///
    /// Replaces the `alignmentHalfResolutionKeypoints` bool, which only offered 1.0 and
    /// 2.0 and left no way to sit between them. Old configs carrying that key still
    /// load: see `init(from:)`, which maps true to 2.0.
    ///
    /// Detection cost and peak memory both scale with the PIXEL COUNT handed to the
    /// detector, so with the area term they fall as `1/divisor²` — 4x at 2.0 but 2.25x
    /// at 1.5. SIFT's scale space is a near-constant ~210 bytes per pixel of the image
    /// it is given, measured at 38.4x the raw frame at 42MP, which is what
    /// `effectiveKeypointMemoryMultiplier()` scales.
    ///
    /// What you trade for it is alignment precision, and the mechanism is worth being
    /// precise about because it is not resampling: keypoints never touch output pixels,
    /// they only produce the homography. Detecting on a smaller copy makes keypoint
    /// LOCALISATION coarser — SIFT's subpixel refinement happens at detection scale, so
    /// its error is multiplied by the divisor on the way back to full-frame coordinates.
    /// A slightly wrong homography warps each neighbour slightly wrong, and the median
    /// merge then averages stars that are a fraction of a pixel apart, which reads as
    /// softness in the final frame. Observed at 2.0 on a 42MP sequence, side by side
    /// against 1.0. The error should fall roughly linearly with the divisor, which is
    /// the whole reason for allowing values between 1.0 and 2.0.
    ///
    /// Below 1.0 is meaningless and is clamped, not honoured — see
    /// `keypointDetectionScale`. The C++ takes a scale rather than a divisor and treats
    /// anything >= 1.0 as full resolution silently, so an unclamped divisor under 1.0
    /// would detect at full size while the cache filename claimed otherwise.
    ///
    /// Feature files are keyed by this value (see `keypointFilename`), because a
    /// descriptor describes the patch at the resolution it was computed at and sets from
    /// two different divisors must never be matched against each other.
    public var alignmentKeypointDetectionDivisor: Double = 1.0

    /// The fraction of full resolution to hand the detector, which is what the C++ wants.
    ///
    /// One conversion site for the whole pipeline, and it clamps rather than trusting the
    /// caller: every surface that can set the divisor (the CLI, the macOS settings, the
    /// protobuf wire, a hand-edited config.json) can put a nonsense value in, and the
    /// Kotlin client's `DoubleField` has no min/max at all. `ia_find_features` would
    /// accept a scale >= 1.0 without complaint and detect at full size.
    public var keypointDetectionScale: Double {
        guard alignmentKeypointDetectionDivisor > 1.0 else { return 1.0 }
        return 1.0 / alignmentKeypointDetectionDivisor
    }

    /// The divisor rounded to the precision the cache filename encodes, so that the value
    /// deciding the work and the value naming the file cannot disagree.
    ///
    /// Two decimals: enough for the 1.5 and 1.25 cases worth trying, and it keeps float
    /// drift out of a filename. Without quantising, a divisor that arrived as
    /// 1.4999999999999998 would write a feature file no later run could find.
    public var quantizedKeypointDivisor: Double {
        guard alignmentKeypointDetectionDivisor > 1.0 else { return 1.0 }
        return (alignmentKeypointDetectionDivisor * 100).rounded() / 100
    }

    /// Above this many bytes of would-be-resident sources, a median merge streams
    /// from scratch files instead of holding every frame in memory.
    ///
    /// The merge needs all N values for a pixel at once, so the naive form holds
    /// N whole frames. Streaming puts each source into a raw scratch file under
    /// `tempOutputPath` as it is produced or decoded, then reads back a band of rows
    /// at a time, which bounds peak memory to a few hundred MB. The output is
    /// bit-identical; the cost is writing and re-reading each source once.
    ///
    /// This governs both merges that matter:
    ///   - the static-earth merge, base + `numberStaticNeighborFrames` (16) decoded
    ///     from disk, 17x the frame — 4102MB at 42MP;
    ///   - the star-aligned build, base + `numberAlignedNeighborFrames` (8) warps,
    ///     9x the frame — 2172MB at 42MP, measured 2178MB resident against 728MB
    ///     streaming.
    ///
    /// Was 2048, which at 16-bit RGB streams the static merge above 21MP and the
    /// aligned build above 40MP. At 42MP that put the aligned build 124MB — 6% — over
    /// the line, so every merge of either kind in a 42MP run streamed on a near miss.
    ///
    /// The trade was measured per merge, in a fresh process, where it looks free.
    /// Measured end to end it is not. Controlled A/B on 20 frames at 42MP, identical
    /// config but for this value:
    ///
    ///     frame concurrency    resident    streaming    peak RSS resident/streaming
    ///     6                        339s         681s              41.4 / 41.0 GB
    ///     36 (the default)         420s         773s              70.5 / 70.3 GB
    ///
    /// 1.8-2.0x faster for no peak memory at all, 20 of 20 output frames bit-identical
    /// in both arms. (The concurrency-6 pair ran back to back and is the controlled
    /// one; the 36 pair confirms it holds at the shipped default and that peak RSS
    /// does not move.)
    ///
    /// Streaming saved nothing because the peak of a run is set by the keypoint phase
    /// — concurrent full-res SIFT, ~7GB an op — which has finished before the first
    /// merge starts. What it bought instead was ~79GB of extra scratch traffic, which
    /// is the whole of the second column. It would still earn its keep where the
    /// merge really is the peak: `alignmentHalfResolutionKeypoints` cuts the keypoint
    /// peak ~3.5x, and then a 4GB merge can be the largest thing in the run.
    ///
    /// 8192 holds a 17-source static merge resident up to 84MP, and a 9-source aligned
    /// build up to 159MP — so it clears every current full-frame sensor, 61MP included
    /// (17 x 345MB = 5858MB). Above that, or with `numberStaticNeighborFrames` raised
    /// (the crossover moves inversely with the source count), streaming engages again,
    /// which is what it is for. Set to 0 to always keep everything resident.
    ///
    /// A fixed megabyte figure is still the wrong shape for "too big to hold" — that
    /// depends on the machine, not the frame. Making it relative to physical memory
    /// needs an "auto" sentinel, and 0 is already taken by "never stream", so it would
    /// have to widen the wire field and both settings UIs. Left as a follow-up.
    ///
    /// The per-op memory estimates follow this: see `mergeStreams(sourceCount:)` and
    /// `residentBuildExtraMultiplier`, which apply the same test so a reservation
    /// cannot describe the path not taken. Raising this therefore raises what a merge
    /// op reserves — at 42MP from 6x to 21x the frame — and the budget converts that
    /// into fewer concurrent merges on its own. No multiplier needs to change with it.
    public var mergeStreamingThresholdMB: Int = 8192

    public var imageWidth: Int = 0
    public var imageHeight: Int = 0
    public var imageBytesPerPixel: Int = 0
    public var imageBitsPerComponent: Int = 0
    public var fileExtension: String = "tiff"
    
    // threshold used for throwing out bad pixels before replacing with them
    // good vs
    var pixelThreshold: Double = 1.2
    
    mutating public func set(videoInfo: VideoInfo) {
        self.frameRate = videoInfo.frameRate
        self.codec = videoInfo.codec
        self.encoder = videoInfo.encoder ?? .prores
        self.pixelFormat = videoInfo.pixelFormat
        self.muxer = videoInfo.muxer
        self.hasAudio = videoInfo.hasAudio
    }

    mutating public func set(imageInfo: ImageInfo) {
        self.imageWidth = imageInfo.imageWidth
        self.imageHeight = imageInfo.imageHeight
        self.imageBytesPerPixel = imageInfo.imageBytesPerPixel
        self.imageBitsPerComponent = imageInfo.imageBitsPerComponent
        self.fileExtension = imageInfo.fileExtension
    }

    /// Decode a config.json, tolerating keys it does not contain.
    ///
    /// This cannot be left to the synthesized `Decodable` conformance, which requires every
    /// key to be present and ignores inline default values entirely: a
    /// `struct S: Codable { var a: Int = 5 }` still throws `keyNotFound` when handed `{}`
    /// (verified on Swift 6.2). Since a config.json written by an older star lacks whatever
    /// has been added since, the synthesized decoder would fail every such resume outright
    /// rather than default the missing fields. Hence the hand-written pass.
    ///
    /// The invariant, and the whole hazard of writing it by hand: **encoding is synthesized,
    /// so every stored property is written — therefore every stored property must be read
    /// back here.** A property added to the struct and not added below round-trips to its
    /// default, which then gets persisted over the real value by the next
    /// `ConfigManager.save()`. That had happened to 16 of 93 properties, `finalOutputDir`
    /// among them. `ConfigRoundTripTests` enumerates the properties with `Mirror` and fails
    /// on any that does not survive an encode/decode, so a missed one is a test failure
    /// rather than a silently reverted setting.
    /// Keys that no longer exist as stored properties but still appear in config.json
    /// files written by older versions.
    ///
    /// `CodingKeys` is synthesized from the stored property names, so a renamed property
    /// takes its old JSON key with it and there is no case left to read the old name
    /// through. Rather than hand-write all 93 cases to keep one alias, the legacy names
    /// live here and get their own container off the same decoder.
    private enum LegacyCodingKeys: String, CodingKey {
        /// Replaced by `alignmentKeypointDetectionDivisor`; true meant a divisor of 2.0.
        case alignmentHalfResolutionKeypoints
    }

    public init(from decoder: Decoder) throws {
        // start with all your initializer defaults
        self = Config()

        let c = try decoder.container(keyedBy: CodingKeys.self)
        
        self.pixelThreshold = try c.decodeIfPresent(Double.self, forKey: .pixelThreshold) ?? self.pixelThreshold
        self.tempOutputPath = try c.decodeIfPresent(String.self, forKey: .tempOutputPath) ?? self.tempOutputPath
        self.outputPath = try c.decodeIfPresent(String.self, forKey: .outputPath) ?? self.outputPath
        self.cleanMethod = try c.decodeIfPresent(CleanMethod.self, forKey: .cleanMethod) ?? self.cleanMethod
        self.pixelReplacementOverrides = try c.decodeIfPresent([Int:CleanMethod].self, forKey: .pixelReplacementOverrides) ?? self.pixelReplacementOverrides
        self.staticNeighborFrameOverrides = try c.decodeIfPresent([Int:Int].self, forKey: .staticNeighborFrameOverrides) ?? self.staticNeighborFrameOverrides
        self.alignedNeighborFrameOverrides = try c.decodeIfPresent([Int:Int].self, forKey: .alignedNeighborFrameOverrides) ?? self.alignedNeighborFrameOverrides        
        self.detectionType = try c.decodeIfPresent(DetectionType.self, forKey: .detectionType) ?? self.detectionType
        self.tripodHeadWasMoving = try c.decodeIfPresent(Bool.self, forKey: .tripodHeadWasMoving) ?? self.tripodHeadWasMoving

        self.imageSequenceDirname = try c.decodeIfPresent(String.self, forKey: .imageSequenceDirname) ?? self.imageSequenceDirname
        self.imageSequencePath = try c.decodeIfPresent(String.self, forKey: .imageSequencePath) ?? self.imageSequencePath

        self.writeOutlierGroupFiles = try c.decodeIfPresent(Bool.self, forKey: .writeOutlierGroupFiles) ?? self.writeOutlierGroupFiles
        self.writeOutlierClassificationValues = try c.decodeIfPresent(Bool.self, forKey: .writeOutlierClassificationValues) ?? self.writeOutlierClassificationValues
        self.writeFramePreviewFiles = try c.decodeIfPresent(Bool.self, forKey: .writeFramePreviewFiles) ?? self.writeFramePreviewFiles
        self.writeFrameProcessedPreviewFiles = try c.decodeIfPresent(Bool.self, forKey: .writeFrameProcessedPreviewFiles) ?? self.writeFrameProcessedPreviewFiles
        self.writeFrameThumbnailFiles = try c.decodeIfPresent(Bool.self, forKey: .writeFrameThumbnailFiles) ?? self.writeFrameThumbnailFiles
        self.writeOutputFiles = try c.decodeIfPresent(Bool.self, forKey: .writeOutputFiles) ?? self.writeOutputFiles

        self.ignoreLowerPixels = try c.decodeIfPresent(Int.self, forKey: .ignoreLowerPixels) ?? self.ignoreLowerPixels

        self.frameRate = try c.decodeIfPresent(FrameRate.self, forKey: .frameRate) ?? self.frameRate
        self.codec = try c.decodeIfPresent(FFmpegCodec.self, forKey: .codec) ?? self.codec
        self.encoder = try c.decodeIfPresent(FFmpegEncoder.self, forKey: .encoder) ?? self.encoder
        self.pixelFormat = try c.decodeIfPresent(FFmpegPixelFormat.self, forKey: .pixelFormat) ?? self.pixelFormat
        self.muxer = try c.decodeIfPresent(FFmpegMuxer.self, forKey: .muxer) ?? self.muxer
        self.hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? self.hasAudio

        self.horizonDetectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .horizonDetectionEnabled) ?? self.horizonDetectionEnabled
        self.useReferenceHorizonSmoothing = try c.decodeIfPresent(Bool.self, forKey: .useReferenceHorizonSmoothing) ?? self.useReferenceHorizonSmoothing
        self.referenceHorizonSmoothingMaxDistance = try c.decodeIfPresent(Int.self, forKey: .referenceHorizonSmoothingMaxDistance) ?? self.referenceHorizonSmoothingMaxDistance
        self.useReferenceHorizonBrightnessRefinement = try c.decodeIfPresent(Bool.self, forKey: .useReferenceHorizonBrightnessRefinement) ?? self.useReferenceHorizonBrightnessRefinement
        self.referenceHorizonBrightnessRefinementSearchRadius = try c.decodeIfPresent(Int.self, forKey: .referenceHorizonBrightnessRefinementSearchRadius) ?? self.referenceHorizonBrightnessRefinementSearchRadius
        self.referenceHorizonBrightnessRefinementHistogramBuckets = try c.decodeIfPresent(Int.self, forKey: .referenceHorizonBrightnessRefinementHistogramBuckets) ?? self.referenceHorizonBrightnessRefinementHistogramBuckets
        self.horizonSpikeRemovalEnabled = try c.decodeIfPresent(Bool.self, forKey: .horizonSpikeRemovalEnabled) ?? self.horizonSpikeRemovalEnabled
        self.horizonSpikeMaxWidth = try c.decodeIfPresent(Int.self, forKey: .horizonSpikeMaxWidth) ?? self.horizonSpikeMaxWidth
        self.horizonSpikeMaxDeviationFraction = try c.decodeIfPresent(Double.self, forKey: .horizonSpikeMaxDeviationFraction) ?? self.horizonSpikeMaxDeviationFraction
        self.horizonSpikeWindowHalf = try c.decodeIfPresent(Int.self, forKey: .horizonSpikeWindowHalf) ?? self.horizonSpikeWindowHalf
        self.useCombinedHorizonDetection = try c.decodeIfPresent(Bool.self, forKey: .useCombinedHorizonDetection) ?? self.useCombinedHorizonDetection
        self.horizonStripWidth = try c.decodeIfPresent(Int.self, forKey: .horizonStripWidth) ?? self.horizonStripWidth
        self.useCannyForHorizonDetection = try c.decodeIfPresent(Bool.self, forKey: .useCannyForHorizonDetection) ?? self.useCannyForHorizonDetection
        self.cannyMinThreshold = try c.decodeIfPresent(Double.self, forKey: .cannyMinThreshold) ?? self.cannyMinThreshold
        self.cannyMaxThreshold = try c.decodeIfPresent(Double.self, forKey: .cannyMaxThreshold) ?? self.cannyMaxThreshold
        self.cannyUseL2Gradient = try c.decodeIfPresent(Bool.self, forKey: .cannyUseL2Gradient) ?? self.cannyUseL2Gradient

        self.horizonMinY = try c.decodeIfPresent(Int.self, forKey: .horizonMinY)
        self.horizonMaxY = try c.decodeIfPresent(Int.self, forKey: .horizonMaxY)
        self.numberOfFramesToProcessConcurrently = try c.decodeIfPresent(Int.self, forKey: .numberOfFramesToProcessConcurrently) ?? self.numberOfFramesToProcessConcurrently

        self.horizonVerticalShiftAmount = try c.decodeIfPresent(Int.self, forKey: .horizonVerticalShiftAmount) ?? self.horizonVerticalShiftAmount

        self.allowEarthAlignment = try c.decodeIfPresent(Bool.self, forKey: .allowEarthAlignment) ?? self.allowEarthAlignment

        // Was previously not decoded, so a painted static reference horizon was lost on config
        // reload/resume even though it is encoded. Decode it for round-trip fidelity.
        self.hasStaticReferenceHorizon = try c.decodeIfPresent(Bool.self, forKey: .hasStaticReferenceHorizon) ?? self.hasStaticReferenceHorizon

        self.alignmentMaxKeypoints = try c.decodeIfPresent(Int.self, forKey: .alignmentMaxKeypoints) ?? self.alignmentMaxKeypoints
        self.alignmentWriteDebugImages = try c.decodeIfPresent(Bool.self, forKey: .alignmentWriteDebugImages) ?? self.alignmentWriteDebugImages
        self.alignmentGroundHorizonExtension = try c.decodeIfPresent(Int.self, forKey: .alignmentGroundHorizonExtension) ?? self.alignmentGroundHorizonExtension
        self.alignmentSkyHorizonExtension = try c.decodeIfPresent(Int.self, forKey: .alignmentSkyHorizonExtension) ?? self.alignmentSkyHorizonExtension
        self.alignmentBaseImageDilateSize = try c.decodeIfPresent(Int.self, forKey: .alignmentBaseImageDilateSize) ?? self.alignmentBaseImageDilateSize
        self.alignmentBaseImageThresholdValue = try c.decodeIfPresent(Int.self, forKey: .alignmentBaseImageThresholdValue) ?? self.alignmentBaseImageThresholdValue
        // The divisor, or the bool it replaced. `try?` on both reads rather than `try`:
        // an old config.json holds `alignmentHalfResolutionKeypoints: true`, and
        // decodeIfPresent(Double.self) against a JSON bool THROWS typeMismatch rather
        // than returning nil — so a plain `try` here would fail the whole decode and
        // every resume of an existing sequence would die on it.
        // `try?` flattens the double optional, so nil here covers both "key absent" and
        // "key present but not a number" — and both should fall through to the legacy
        // read, so there is nothing to distinguish.
        if let divisor = try? c.decodeIfPresent(Double.self,
                                                forKey: .alignmentKeypointDetectionDivisor) {
            self.alignmentKeypointDetectionDivisor = divisor
        } else if let legacy = try? decoder.container(keyedBy: LegacyCodingKeys.self)
                    .decodeIfPresent(Bool.self, forKey: .alignmentHalfResolutionKeypoints) {
            // CodingKeys is synthesized from the stored property names, so renaming the
            // property renamed the on-disk key and the old one is no longer a case. A
            // second container keyed by its own enum is how the old name stays readable.
            self.alignmentKeypointDetectionDivisor = legacy ? 2.0 : 1.0
        }
        self.mergeStreamingThresholdMB = try c.decodeIfPresent(Int.self, forKey: .mergeStreamingThresholdMB) ?? self.mergeStreamingThresholdMB
        self.maxConcurrentKeypointOps = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentKeypointOps) ?? self.maxConcurrentKeypointOps
        self.keypointCacheMaxMB = try c.decodeIfPresent(Int.self, forKey: .keypointCacheMaxMB) ?? self.keypointCacheMaxMB
        self.horizonMemoryMultiplier = try c.decodeIfPresent(Int.self, forKey: .horizonMemoryMultiplier) ?? self.horizonMemoryMultiplier
        self.horizonReservationFloorMB = try c.decodeIfPresent(Int.self, forKey: .horizonReservationFloorMB) ?? self.horizonReservationFloorMB
        

        self.starVersion = try c.decodeIfPresent(String.self, forKey: .starVersion) ?? self.starVersion

        self.numberFinalProcessingNeighborsNeeded = try c.decodeIfPresent(Int.self, forKey: .numberFinalProcessingNeighborsNeeded) ?? self.numberFinalProcessingNeighborsNeeded
        self.numberAlignedNeighborFrames = try c.decodeIfPresent(Int.self, forKey: .numberAlignedNeighborFrames) ?? self.numberAlignedNeighborFrames
        self.numberStaticNeighborFrames = try c.decodeIfPresent(Int.self, forKey: .numberStaticNeighborFrames) ?? self.numberStaticNeighborFrames        
        self.homographySmoothingEpsilon = try c.decodeIfPresent(Double.self, forKey: .homographySmoothingEpsilon) ?? self.homographySmoothingEpsilon
        self.supportedImageFileTypes = try c.decodeIfPresent([String].self, forKey: .supportedImageFileTypes) ?? self.supportedImageFileTypes

        self.horizonSearchSize = try c.decodeIfPresent([Int].self, forKey: .horizonSearchSize) ?? self.horizonSearchSize
        self.horizonSearchCropBounds = try c.decodeIfPresent([Double].self, forKey: .horizonSearchCropBounds) ?? self.horizonSearchCropBounds
        self.horizonSearchCropCount1 = try c.decodeIfPresent(Int.self, forKey: .horizonSearchCropCount1) ?? self.horizonSearchCropCount1
        self.horizonSearchCropCount2 = try c.decodeIfPresent(Int.self, forKey: .horizonSearchCropCount2) ?? self.horizonSearchCropCount2
        self.horizonSearchNarrowingRange = try c.decodeIfPresent(Double.self, forKey: .horizonSearchNarrowingRange) ?? self.horizonSearchNarrowingRange
        self.dpHorizonSmoothnessLambdaRange = try c.decodeIfPresent([Double].self, forKey: .dpHorizonSmoothnessLambdaRange) ?? self.dpHorizonSmoothnessLambdaRange
        self.dpHorizonSmoothnessLambdaCount = try c.decodeIfPresent(Int.self, forKey: .dpHorizonSmoothnessLambdaCount) ?? self.dpHorizonSmoothnessLambdaCount
        self.dpHorizonSobelWeightRange = try c.decodeIfPresent([Double].self, forKey: .dpHorizonSobelWeightRange) ?? self.dpHorizonSobelWeightRange
        self.dpHorizonSobelWeightCount = try c.decodeIfPresent(Int.self, forKey: .dpHorizonSobelWeightCount) ?? self.dpHorizonSobelWeightCount
        self.dpHorizonCannyWeightRange = try c.decodeIfPresent([Double].self, forKey: .dpHorizonCannyWeightRange) ?? self.dpHorizonCannyWeightRange
        self.dpHorizonCannyWeightCount = try c.decodeIfPresent(Int.self, forKey: .dpHorizonCannyWeightCount) ?? self.dpHorizonCannyWeightCount

        self.maxMatMemoryFraction = try c.decodeIfPresent(Double.self, forKey: .maxMatMemoryFraction) ?? self.maxMatMemoryFraction
        self.keypointMemoryMultiplier = try c.decodeIfPresent(Int.self, forKey: .keypointMemoryMultiplier) ?? self.keypointMemoryMultiplier
        self.outlierMemoryMultiplier = try c.decodeIfPresent(Int.self, forKey: .outlierMemoryMultiplier) ?? self.outlierMemoryMultiplier
        self.mergeMemoryMultiplier = try c.decodeIfPresent(Int.self, forKey: .mergeMemoryMultiplier) ?? self.mergeMemoryMultiplier

        // Where the finals go. Undecoded until now, which was the worst of the omissions:
        // encoding writes it, so `star <seq> <outputDir>` recorded it and the resume then
        // decoded nil and fell through to `outputSequenceDirname`'s `<outputPath>/<basename>`
        // branch. The resume therefore wrote its finals into a second, freshly created dir,
        // did not find the existing ones where `.final` is looked for (so every merge re-ran),
        // and `configManager.update` persisted the loss back into config.json.
        self.finalOutputDir = try c.decodeIfPresent(String.self, forKey: .finalOutputDir) ?? self.finalOutputDir

        self.progressBarLength = try c.decodeIfPresent(Int.self, forKey: .progressBarLength) ?? self.progressBarLength
        self.previewWidth = try c.decodeIfPresent(Int.self, forKey: .previewWidth) ?? self.previewWidth
        self.previewHeight = try c.decodeIfPresent(Int.self, forKey: .previewHeight) ?? self.previewHeight
        self.thumbnailWidth = try c.decodeIfPresent(Int.self, forKey: .thumbnailWidth) ?? self.thumbnailWidth
        self.thumbnailHeight = try c.decodeIfPresent(Int.self, forKey: .thumbnailHeight) ?? self.thumbnailHeight
        self.outlierGroupPaintBorderPixels = try c.decodeIfPresent(Double.self, forKey: .outlierGroupPaintBorderPixels) ?? self.outlierGroupPaintBorderPixels
        self.outlierGroupPaintBorderInnerWallPixels = try c.decodeIfPresent(Double.self, forKey: .outlierGroupPaintBorderInnerWallPixels) ?? self.outlierGroupPaintBorderInnerWallPixels
        self.referenceHorizonNeighborhoodSize = try c.decodeIfPresent(Int.self, forKey: .referenceHorizonNeighborhoodSize) ?? self.referenceHorizonNeighborhoodSize

        // `Processor.init` overwrites these from the sequence's first frame via
        // `set(imageInfo:)`, so leaving them undecoded was benign for the cli. Decoded
        // anyway: nothing guarantees every consumer of a config.json runs that path, and
        // "encoded but not decoded" is the property this whole initializer has to hold.
        self.imageWidth = try c.decodeIfPresent(Int.self, forKey: .imageWidth) ?? self.imageWidth
        self.imageHeight = try c.decodeIfPresent(Int.self, forKey: .imageHeight) ?? self.imageHeight
        self.imageBytesPerPixel = try c.decodeIfPresent(Int.self, forKey: .imageBytesPerPixel) ?? self.imageBytesPerPixel
        self.imageBitsPerComponent = try c.decodeIfPresent(Int.self, forKey: .imageBitsPerComponent) ?? self.imageBitsPerComponent
        self.fileExtension = try c.decodeIfPresent(String.self, forKey: .fileExtension) ?? self.fileExtension
    }

    /// Expand a [min, max] range and a step count into an array of evenly-spaced values.
    /// - count=1 → [min]  (single value; if min==max this is just that value)
    /// - count=2 → [min, max]
    /// - count>2 → min, min+step, …, max
    public static func expandRange(_ range: [Double], count: Int) -> [Double] {
        guard range.count >= 2 else { return [range.first ?? 0] }
        let lo = range[0]
        let hi = range[1]
        let n  = max(1, count)
        if n == 1 { return [lo] }
        let step = (hi - lo) / Double(n - 1)
        return (0..<n).map { lo + Double($0) * step }
    }

    /// Convenience accessors that expand the range+count pairs into value arrays.
    public var dpHorizonSmoothnessLambdaValues: [Double] {
        Config.expandRange(dpHorizonSmoothnessLambdaRange, count: dpHorizonSmoothnessLambdaCount)
    }
    public var dpHorizonSobelWeightValues: [Double] {
        Config.expandRange(dpHorizonSobelWeightRange, count: dpHorizonSobelWeightCount)
    }
    public var dpHorizonCannyWeightValues: [Double] {
        Config.expandRange(dpHorizonCannyWeightRange, count: dpHorizonCannyWeightCount)
    }

    // 0.0.2 added more detail group hough transormation analysis, based upon a data set
    // 0.0.3 included the data set analysis to include group size and fill, and to use histograms
    // 0.0.4 included .inStreak final processing
    // 0.0.5 added pixel overlap between outlier groups
    // 0.0.6 fixed streak processing and added another layer afterwards
    // 0.0.7 really fixed streak processing and lots of refactoring
    // 0.0.8 got rid of more false positives with weighted scoring and final streak tweaks
    // 0.0.9 softer outlier boundries, more streak tweaks, outlier overlap adjustments
    // 0.0.10 add alpha on soft outlier boundries, speed up final process some, fix memory problem
    // 0.0.11 fix soft outlier boundries, better constants, initial group filter
    // 0.0.12 fix a streak bug, other small fixes
    // 0.1.0 added height based size constraints, runs faster, gets 95% or more airplanes
    // 0.1.1 updatable logging, try to improve speed
    // 0.1.2 lots of speed/memory usage improvements, better updatable log
    // 0.1.3 started to add the gui
    // 0.2.0 added first gui, outlier groups can be saved, and reloaded with config
    // 0.3.0 added machine learning group classification, better threading, and more
    // 0.3.1 added release scripts for distribution, plus bug fixes
    // 0.3.2 fixed bugs, speed up tree forest, removes small outlier group dismissal
    // 0.3.3 speed up outlier saving, bug fixes, code improvements, renamed to star
    // 0.3.4 lots of UI improvements
    // 0.4.0 star alignment
    // 0.4.1 fixes after star alignment, better constants
    // 0.4.2 clean up memory usage during outlier detection, save outlier pixels as 16 bit, not 32
    // 0.4.3 subtraction images saved and re-used when available
    // 0.4.4 border painting enabled with config options
    // 0.5.0 blobber
    // 0.5.1 write validation images and use them for new outliers if present
    // 0.6.0 kernel hough transform and new blob to outlier group logic
    // 0.6.1 rewrote outlier detection logic to find smaller groups better
    // 0.6.2 added IsolatedBolbRemover, and BlobSmasher, tweaked lots of other blob stuff as well
    // 0.6.3 more cleanup, removed outlierMaxThreshold, changed how this is represented (/4 gone)
    // 0.6.4 attempted speed up, more blob filtering
    // 0.6.5 re-worked blob detection again, added separate DetectionType
    // 0.6.6 re-wrote outlier saving, using one image per frame for outlier data now
    // 0.6.7 y-axis outlier images, two new classfication features
    // 0.7.0 swift 6, blob updates, gui a lot better, KHT works, display lines, etc
    // 0.7.1 completely reworked excessive processing mode, memory fixes, blob processing window,
    //       custom blob processing, more user prefs
    //       dustbin filled by adding another .isolated decision tree before inter-frame processing
    // 0.7.3 small blobs as image / lots of other gui updates / fixes
    //       32bit BlobID
    //       fix HoughLineMatrix processor
    //       add shovel to gui
    //       cursors and icons in gui
    //       lots of renaming
    //       debug logging view
    //       lines better connected, fixed LinearBlobConnector
    //       use multiple aligned images to clean up really noisy frame sequences
    // 0.8.0 embed ffmpeg, ffprobe and align_image_stack in the app properly
    //       allow starting directly with a video and having the image sequence extracted
    //       ability to render to video from gui
    // 0.8.1 fix bug with non-standard incoming filenames
    // 0.9.0 add horizon detection
    //       add ground alignment images
    //       adjust pixel removal to use ground image when appropriate
    //       replace align_image_stack with custom opencv2 SIFT code for speed and accuracy
    //       move image subtraction logic to opencv2 for speed
    //       add MatWrapper for better cv::Mat memory handling
    //       fix shovel bug
    //       better hovering logic
    // 0.9.1 every PixelatedImage is a cv::Mat
    //       better image caching, uses less ram
    //       upgrade sheet on startup if there is a new version
    //       fix bug where outliers got way to large
    //       add memory stats on left panel
    //       add re-processing mode to right panel for easier re-processing
    // 0.10.0 added automatic as new processing mode
    //        much improved initial instructions view
    //        bug fixes
    //        lots of horizon calculation improvements
    // 0.10.1 save full image alignment info
    //        add alignment params to config and UI
    //        add support for jpeg and other file types
    // 0.10.2 a lot of small 8 bit image fixes
    // 0.10.3 added alignment info window
    //        added fix bad alignment button (use existing homography)
    //        added second pass of alignment to fix bad alignment automatically
    // 0.10.4 fixed second pass of alignment to actually work
    //        updated deviation checks to use a min/max range, not median
    // 0.10.5 added more status and error reporting
    //        single thread alignment pre frame for better results
    // 0.10.6 added graph processing, split up processing into smaller chunks
    //        added alignment validation to estimate alignment for frames without enough stars
    //        bug fixes, runs a lot faster, less ram (hopefully)
    //        resurrected CLI
    // 0.10.7 adaptive horizon detection
    //        resurrected merged horizons
    //        finds best static horizon
    //        much faster preview generation in GUI
    //        much faster startup in GUI
    // 0.11.0 new horizon work
    //        grid mode
    //        linux cli support
    //        lots more
    // 0.11.1 use github actions for release
    //        windows cli support
    // 0.11.2 lots of memory and speed improvements
    //        more unit tests and bug fixes
    // 0.11.3 better crash and error reporting across the board
    
    public var starVersion = Config.latestVersion

    public static let latestVersion = "0.11.3"

    // defaults to basename below if not set
    public var finalOutputDir: String? = nil
    
    public var basename: String {
        let _basename = "\(self.imageSequenceDirname)-star-v-\(self.starVersion)"
          .sanitized
        return _basename.replacingOccurrences(of: ".", with: "_")
    }

    public var outlierOutputDirname: String {
        "\(self.tempOutputPath)/outliers"
    }
    
    /// Where `writeJson(named:)` puts `filename`.
    ///
    /// A filename carrying a directory component already says where it goes.  That is how
    /// the cli hands a saved config path back in on resume, and how stard names its
    /// session dir.  A bare filename lives under tempOutputPath, which is how a fresh
    /// image sequence run passes plain "config.json".
    ///
    /// This used to ask whether filename had tempOutputPath as a prefix, which only
    /// recognised the absolute-and-identical case: a relative resume path like
    /// 'star_temp_foo/config.json' got appended to the absolute tempOutputPath read out
    /// of that same file, doubling the dirname.
    ///
    /// The cli's post-run cleanup resolves the same path to decide what to spare, so this
    /// stays the one answer to where the config file lands.
    public func jsonPath(named filename: String) -> String {
        var dirname = (filename as NSString).deletingLastPathComponent
        if dirname.isEmpty { dirname = self.tempOutputPath }
        return "\(dirname)/\((filename as NSString).lastPathComponent)"
    }

    public func writeJson(named filename: String, overwrite: Bool = false) {
        
        // write to config json

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]

        do {
            let jsonData = try encoder.encode(self)

            let fullPath = self.jsonPath(named: filename)
            let dirname = (fullPath as NSString).deletingLastPathComponent

            if FileManager.default.fileExists(atPath: fullPath),
               !overwrite
            {
                Log.w("cannot write to \(fullPath), it already exists")
                return
            }

            // the dir may not exist yet.  on a fresh image sequence run this is the
            // first thing written under tempOutputPath, well before any ImageAccessor
            // has built the temp dir tree — and createFile() only returned false in
            // that case, so the write failed silently.
            mkdir(dirname)

            try jsonData.write(to: URL(fileURLWithPath: fullPath))
            Log.i("wrote \(fullPath)")
        } catch {
            Log.e("could not write \(filename): \(error)")
        }
    }

    /// Bytes in one uncompressed source frame.
    ///
    /// Truthful about the source, which is what `mergeStreams` and
    /// `residentBuildExtraMultiplier` need: they reason about frames actually held in
    /// memory. For sizing a *reservation*, use `workingFrameBytes` instead.
    ///
    /// Zero until `set(imageInfo:)` has been called, which is the condition
    /// `FrameGraphBuilder.build` warns loudly about: a zero here silently disables
    /// all memory gating.
    public var rawImageBytes: UInt64 {
        UInt64(imageWidth) * UInt64(imageHeight) * UInt64(max(imageBytesPerPixel, 1))
    }

    /// Components per pixel of the source, e.g. 3 for BGR at any depth.
    ///
    /// 0 when it cannot be derived, which needs `imageBitsPerComponent` as well as
    /// `imageBytesPerPixel`. `set(imageInfo:)` always sets both together.
    public var componentsPerPixel: Int {
        let bytesPerComponent = imageBitsPerComponent / 8
        guard bytesPerComponent > 0 else { return 0 }
        return max(max(imageBytesPerPixel, 1) / bytesPerComponent, 1)
    }

    /// Bytes of one frame at the depth the pipeline actually works in — the unit every
    /// memory multiplier in this file was derived against.
    ///
    /// All of those multipliers were measured on 16-bit 3-channel input, and the costs
    /// they describe barely depend on the source depth:
    ///
    ///   - SIFT's scale space is CV_32F over the gray it is handed, so the 42x figure is
    ///     per pixel — an 8-bit source builds exactly the same pyramid.
    ///   - the blobber's `[[SortablePixel?]]` is 24 bytes per pixel regardless of depth.
    ///   - `finishSelective` promotes to 16 bits via `ensure16Bits` and works there.
    ///
    /// So an 8-bit source does not make that work cheaper — but it does halve
    /// `rawImageBytes`, which would halve every reservation while the work stayed the
    /// same. Flooring the per-pixel figure at the 16-bit working depth keeps the
    /// multipliers meaning what they were measured to mean, on any source depth.
    ///
    /// A source deeper than 16 bits is not shrunk: 32-bit input reserves against its own
    /// size, since the pipeline will be carrying that.
    /// Falls back to `rawImageBytes` when the component depth is unknown. Without it,
    /// 3 bytes per pixel could be 8-bit BGR (working depth 6) or a 24-bit single
    /// component (working depth 3), and guessing the first would double every
    /// reservation for any config that happens not to carry the field.
    public var workingFrameBytes: UInt64 {
        let perPixel = workingBytesPerPixel
        guard perPixel > 0 else { return rawImageBytes }
        return UInt64(imageWidth) * UInt64(imageHeight) * UInt64(perPixel)
    }

    /// The per-pixel half of `workingFrameBytes` — see there for why the source depth is
    /// floored at the 16-bit working depth.
    ///
    /// Separate from `workingFrameBytes` because the resolution advice in
    /// `keypointDivisorAdvice` needs the per-pixel cost without a resolution baked into
    /// it: it divides a memory budget by it to get back a pixel count.
    ///
    /// 0 when the component depth is unknown, the same condition under which
    /// `workingFrameBytes` falls back to `rawImageBytes`.
    public var workingBytesPerPixel: Int {
        let components = componentsPerPixel
        guard components > 0 else { return 0 }
        return max(max(imageBytesPerPixel, 1), 2 * components)
    }

    /// Whether a merge of `sourceCount` frames streams its sources to scratch at this
    /// frame size, rather than holding all of them at once.
    ///
    /// Mirrors the threshold check in `ia_align_and_median_merge` and
    /// `ia_median_merge_image_with_filenames`. The estimate and the code have to agree
    /// on this, or a reservation ends up describing the path that was not taken.
    ///
    /// For an 8-bit source this reads low, because `rawImageBytes` counts source bytes
    /// per pixel while the C++ check measures the 16-bit working frame. That errs
    /// toward calling a merge resident, i.e. toward the larger reservation.
    public func mergeStreams(sourceCount: Int) -> Bool {
        guard mergeStreamingThresholdMB > 0 else { return false }
        let sources = UInt64(max(sourceCount, 0))
        return rawImageBytes * sources > UInt64(mergeStreamingThresholdMB) * 1024 * 1024
    }

    /// Extra multiples of the raw frame for whichever merge inside a merge or outlier
    /// op holds all of its sources at once, or 0 when they all stream.
    ///
    /// Two merges can run inside those ops, and each is streamed or resident on its
    /// own source count, so the thresholds are crossed at different frame sizes:
    ///   - the star-aligned build, `numberAlignedNeighborFrames` + 1 sources;
    ///   - the static-earth build, `numberStaticNeighborFrames` + 1 sources, which
    ///     with the default 16 stays resident up to a much smaller frame than the
    ///     aligned build does.
    /// They happen one after the other, so the larger of the two is what has to be
    /// covered rather than their sum.
    ///
    /// A resident build holds every source instead of one, and the sources are what
    /// grows with the neighbour count: measured at 42MP, 8 aligned neighbours cost
    /// 9.03x resident against 3.02x streaming, i.e. 6 more multiples of the frame for
    /// 8 neighbours. Charged as `neighbours - 1` so the same shape covers the
    /// 16-neighbour static build with a little margin rather than exactly.
    ///
    /// This is what the old flat 14 was missing: the static-earth build is resident by
    /// default and needs ~18x, which is why merge ops in a 12MP run were logging OVER
    /// RESERVATION against it.
    ///
    /// Since `mergeStreamingThresholdMB` rose to 8192 that is no longer the small-frame
    /// case — it is every frame size up to 84MP, so this term now carries the estimate
    /// for a normal run rather than an edge of one. Worth checking the arithmetic
    /// against what the C++ actually holds: `ia_median_merge_image_with_filenames`
    /// peaks at `count + 2` whole frames resident (the base, every decoded source, and
    /// the output medianImageFromMats allocates while they are all still live), so 18
    /// at the default 16 static neighbours. Charged here as 15, plus
    /// `mergeMemoryMultiplier`'s 6 for the op's own frames, is 21. Covered.
    /// Pass the ACTUAL neighbour counts for the frame, not the configured ones.
    /// `FrameAlignmentProcessor.calculateNeighborIndices` clamps to the sequence bounds,
    /// so a frame near either end — or any frame at all in a sequence shorter than the
    /// configured count — has fewer neighbours than configured. Charging for eight when
    /// one exists over-reserves by seven whole frames: measured on a 2-frame 24MP
    /// sequence, an outlier op reserved 2197MB (16x) and used 255MB, and a merge op
    /// 1785MB (13x) against 137MB.
    ///
    /// `nil` means the caller could not determine the count, and falls back to the
    /// configured value — over-reserving, which only costs concurrency, rather than
    /// under-reserving, which costs the machine. An actual 0 is honoured as 0: a frame
    /// really can have no neighbours (the only frame of a single-frame sequence does),
    /// and a merge with no sources to merge holds nothing extra.
    public func residentBuildExtraMultiplier(alignedNeighbours: Int?,
                                             staticNeighbours: Int?) -> Int {
        let aligned = alignedNeighbours ?? numberAlignedNeighborFrames
        let statics = staticNeighbours ?? numberStaticNeighborFrames

        var extra = 0
        if !mergeStreams(sourceCount: aligned + 1) {
            extra = max(extra, aligned - 1)
        }
        if !mergeStreams(sourceCount: statics + 1) {
            extra = max(extra, statics - 1)
        }
        return max(extra, 0)
    }

    /// What one merge op should reserve, as a multiple of the raw frame.
    /// See `residentBuildExtraMultiplier` for what the counts mean, and what `nil` costs.
    public func effectiveMergeMemoryMultiplier(alignedNeighbours: Int?,
                                              staticNeighbours: Int?) -> Int {
        mergeMemoryMultiplier + residentBuildExtraMultiplier(alignedNeighbours: alignedNeighbours,
                                                            staticNeighbours: staticNeighbours)
    }

    /// What one outlier op should reserve, as a multiple of the raw frame.
    /// See `residentBuildExtraMultiplier` for what the counts mean, and what `nil` costs.
    public func effectiveOutlierMemoryMultiplier(alignedNeighbours: Int?,
                                                staticNeighbours: Int?) -> Int {
        outlierMemoryMultiplier + residentBuildExtraMultiplier(alignedNeighbours: alignedNeighbours,
                                                              staticNeighbours: staticNeighbours)
    }

    /// The result of `keypointConcurrency(physicalMemory:)`.
    public struct KeypointConcurrency: Sendable {
        /// How many keypoint ops may run at once — the smallest of the terms below.
        public let limit: Int
        /// How many `bytesPerOp` reservations fit in `budget`, or nil when image
        /// dimensions are unknown and the budget term cannot be computed at all.
        public let budgetLimit: Int?
        /// `workingFrameBytes × effectiveKeypointMemoryMultiplier()`.
        public let bytesPerOp: UInt64
        /// `physicalMemory × maxMatMemoryFraction`.
        public let budget: UInt64
        /// Which term actually decided `limit` — worth logging, because it tells you
        /// which knob will change anything.
        public let binding: String
    }

    /// How many keypoint ops may run concurrently, and which limit is binding.
    ///
    /// Three independent terms, smallest wins:
    ///   - the memory budget: `budget / (workingFrameBytes × effectiveKeypointMemoryMultiplier())`
    ///   - `numberOfFramesToProcessConcurrently`, the pipeline-wide concurrency
    ///   - `maxConcurrentKeypointOps`, an explicit keypoint-only cap when non-zero
    ///
    /// Keeping these separate is the point. Previously only the first existed, so the
    /// memory multiplier was the sole concurrency knob — and it was inert whenever the
    /// frame count was the smaller term, which is why it appeared to do nothing at
    /// 12MP and everything at 42MP.
    public func keypointConcurrency(physicalMemory: UInt64) -> KeypointConcurrency {
        let budget = UInt64(Double(physicalMemory) * maxMatMemoryFraction)
        let bytesPerOp = workingFrameBytes * UInt64(max(effectiveKeypointMemoryMultiplier(), 1))

        var limit = max(1, numberOfFramesToProcessConcurrently)
        var binding = "numberOfFramesToProcessConcurrently"

        var budgetLimit: Int? = nil
        if bytesPerOp > 0 {
            let fits = Int(max(1, budget / bytesPerOp))
            budgetLimit = fits
            if fits < limit {
                limit = fits
                binding = "memory budget"
            }
        }

        // A cap, never an override: it can lower the limit but not raise it past what
        // the budget allows.
        if maxConcurrentKeypointOps > 0, maxConcurrentKeypointOps < limit {
            limit = maxConcurrentKeypointOps
            binding = "maxConcurrentKeypointOps"
        }

        return KeypointConcurrency(limit: limit,
                                   budgetLimit: budgetLimit,
                                   bytesPerOp: bytesPerOp,
                                   budget: budget,
                                   binding: binding)
    }

    /// The divisor to suggest when full resolution does not fit the machine.
    ///
    /// 1.5 rather than 2: it recovers 2.25x of the 4x that 2 does, and on 42MP frames the
    /// two outputs were compared side by side and 1.5 was indistinguishable from 1.0 while
    /// 2 was visibly softer. Shared with the GUI so the up-front prompt and any test
    /// asserting on it cannot drift apart.
    public static let recommendedReducedKeypointDivisor: Double = 1.5

    /// Whether this machine can keep its cores busy detecting keypoints on this
    /// sequence at full resolution, and what to suggest when it cannot.
    ///
    /// See `keypointDivisorAdvice(physicalMemory:)`.
    public struct KeypointDivisorAdvice: Sendable, Equatable {
        /// True when the memory budget, not the core count, is what limits full
        /// resolution keypoint concurrency for this sequence on this machine.
        public let reduceRecommended: Bool
        /// `Config.recommendedReducedKeypointDivisor` when `reduceRecommended`, else 1.0.
        public let recommendedDivisor: Double
        /// The largest frame, in pixels, this machine can detect on at full resolution
        /// without the budget throttling concurrency. `reduceRecommended` is exactly
        /// `imagePixels > thresholdPixels`.
        public let thresholdPixels: Int
        /// This sequence's frame, in pixels.
        public let imagePixels: Int
        /// How many keypoint ops actually run at once at full resolution...
        public let fullResolutionConcurrency: Int
        /// ...against how many the pipeline would run if memory were free.
        public let frameConcurrency: Int
    }

    /// Where the up-front keypoint divisor prompt should kick in, for this sequence on
    /// this machine.
    ///
    /// Not a new heuristic — it is `keypointConcurrency(physicalMemory:)` solved for the
    /// resolution at which its two terms cross. Below the crossover the core count is
    /// binding, so a divisor buys a little per-op speed and no concurrency; at or above
    /// it the memory budget is binding, so the divisor buys concurrency directly and is
    /// the difference between a machine that is busy and one that is waiting on RAM.
    /// That crossover is also the observable the user reports: on a 128GB 18-core
    /// (36 logical) iMac Pro, 12MP frames run full resolution comfortably and 42MP ones
    /// throttle to 10 of 36 concurrent ops, and the arithmetic below puts the boundary at
    /// 12.9MP with no fitting.
    ///
    ///     thresholdPixels = physicalMemory x maxMatMemoryFraction
    ///                       / (numberOfFramesToProcessConcurrently
    ///                          x workingBytesPerPixel x keypointMemoryMultiplier)
    ///
    /// Deliberately `keypointMemoryMultiplier` and not
    /// `effectiveKeypointMemoryMultiplier()`: the question is what full resolution would
    /// cost, so the answer must not move once a divisor is already set.
    ///
    /// It scales with every term for a reason. Physical memory and the working depth are
    /// the machine and the footage. `numberOfFramesToProcessConcurrently` is in there
    /// because a machine with more cores wants more ops in flight to fill them, so it runs
    /// out of memory at a *smaller* frame — a 16GB 8-core laptop crosses over around 7MP,
    /// a 192GB Ultra around 29MP.
    ///
    /// `nil` when `set(imageInfo:)` has not run: without dimensions and depth there is no
    /// resolution to compare and no per-pixel cost to compare it against. Callers should
    /// treat that as "say nothing", not as "recommend a divisor".
    public func keypointDivisorAdvice(physicalMemory: UInt64) -> KeypointDivisorAdvice? {
        let perPixel = workingBytesPerPixel
        let pixels = imageWidth * imageHeight
        guard perPixel > 0, pixels > 0, physicalMemory > 0 else { return nil }

        let frameConcurrency = max(1, numberOfFramesToProcessConcurrently)
        let bytesPerPixelPerOp = perPixel * max(keypointMemoryMultiplier, 1)
        let budget = Double(physicalMemory) * maxMatMemoryFraction

        // The largest frame that still fits frameConcurrency ops in the budget.
        let threshold = Int(budget / Double(frameConcurrency * bytesPerPixelPerOp))

        // How many fit at this frame size. floor(x) < n is exactly x < n for integer n,
        // so this is `> threshold` and the two can never disagree at the boundary.
        let fits = max(1, Int(budget / Double(pixels * bytesPerPixelPerOp)))
        let reduce = fits < frameConcurrency

        return KeypointDivisorAdvice(
          reduceRecommended: reduce,
          recommendedDivisor: reduce ? Self.recommendedReducedKeypointDivisor : 1.0,
          thresholdPixels: max(threshold, 1),
          imagePixels: pixels,
          fullResolutionConcurrency: min(fits, frameConcurrency),
          frameConcurrency: frameConcurrency)
    }

    public var dirForKeypointData: String {
        "\(self.tempOutputPath)/keypoints"
    }

    /// Filename of a frame's persisted OpenCV feature set, within `dirForKeypointData`.
    ///
    /// Keyed by detection scale, because a descriptor describes the image patch at the
    /// resolution it was detected at. A feature set found at one divisor must never be
    /// matched against one found at another, so each divisor gets its own file
    /// (`3.sky.yaml`, `3.sky.half.yaml`, `3.sky.div1.50.yaml`) and changing
    /// `alignmentKeypointDetectionDivisor` cannot pick up the wrong one.
    ///
    /// The two names the bool era wrote are kept exactly — no suffix at 1.0 and `.half`
    /// at 2.0 — so feature files already on disk stay valid instead of being orphaned.
    /// Nothing prunes `dirForKeypointData`, so an orphan is silent waste rather than an
    /// error, but there is no reason to create it.
    ///
    /// Everything else is `.div<divisor>` to two decimals, from
    /// `quantizedKeypointDivisor` rather than the raw value, so the name is stable across
    /// runs and float formatting can never produce `.div1.4999999999999998`.
    ///
    /// Build the name here rather than at each call site: the base frame and each of its
    /// neighbours are loaded from different places, and they must all agree.
    public func keypointFilename(frameIndex: Int, ofType type: FrameViewMode) -> String? {
        let divisor = self.quantizedKeypointDivisor
        let scaleSuffix: String
        if divisor <= 1.0 {
            scaleSuffix = ""
        } else if divisor == 2.0 {
            scaleSuffix = ".half"
        } else {
            scaleSuffix = String(format: ".div%.2f", divisor)
        }
        switch type {
        case .starAligned:  return "\(frameIndex).sky\(scaleSuffix).yaml"
        case .earthAligned: return "\(frameIndex).earth\(scaleSuffix).yaml"
        default:            return nil
        }
    }


    public func dirForImage(ofType type: FrameViewMode,
                            atSize size: ImageDisplaySize = .original) -> String?
    {
        switch type {
        case .original:
            switch size {
            case .original:
                return "\(self.imageSequencePath)/\(self.imageSequenceDirname)"
            case .preview:
                return "\(self.tempOutputPath)/previews"
            case .thumbnail:
                return "\(self.tempOutputPath)/thumbnails"
            }
        case .starAligned:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/aligned"

            case .preview:
                return "\(self.tempOutputPath)/aligned-previews"
            case .thumbnail:
                return nil
            }
        case .failedStarAligned:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/failed-aligned"

            case .preview:
                return "\(self.tempOutputPath)/failed-aligned-previews"
            case .thumbnail:
                return nil
            }
        case .failedEarthAligned:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/earth-failed-aligned"

            case .preview:
                return "\(self.tempOutputPath)/earth-failed-aligned-previews"
            case .thumbnail:
                return nil
            }
        case .earthAligned:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/earth-aligned"

            case .preview:
                return "\(self.tempOutputPath)/earth-aligned-previews"
            case .thumbnail:
                return nil
            }
        case .horizon:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/horizon"

            case .preview:
                return "\(self.tempOutputPath)/horizon-previews"
            case .thumbnail:
                return nil
            }
        case .mergedHorizon:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/mergedHorizon"

            case .preview:
                return "\(self.tempOutputPath)/mergedHorizon-previews"
            case .thumbnail:
                return nil
            }
        case .userHorizon:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/horizonReference"
            case .preview:
                return "\(self.tempOutputPath)/horizonReference-previews"
            case .thumbnail:
                return nil
            }
        case .subtraction:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/aligned-subtracted"
            case .preview:
                return "\(self.tempOutputPath)/aligned-subtracted-previews"
            case .thumbnail:
                return nil
            }
        case .blobs:
            switch size {
            case .original:
                return nil
            case .preview:
                return "\(self.tempOutputPath)/blobs-preview"
            case .thumbnail:
                return nil
            }
        case .removeMask:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/paintMask"
            case .preview:
                return "\(self.tempOutputPath)/paintMask-preview"
            case .thumbnail:
                return nil
            }
        case .validation:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/validated-outlier-images"
            case .preview:
                return "\(self.tempOutputPath)/validated-outlier-images-previews"
            case .thumbnail:
                return nil
            }
        case .autoProcessed:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/auto-processed"
            case .preview:
                return "\(self.tempOutputPath)/auto-processed-previews"
            case .thumbnail:
                return nil
            }

        case .autoSelectiveProcessed:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/auto-selective-processed"
            case .preview:
                return "\(self.tempOutputPath)/auto-selective-processed-previews"
            case .thumbnail:
                return nil
            }

        case .selectiveProcessed:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/selective-processed"
            case .preview:
                return "\(self.tempOutputPath)/selective-processed-previews"
            case .thumbnail:
                return nil
            }

        case .final:
            switch size {
            case .original:
                return self.outputSequenceDirname
            case .preview:
                return "\(self.tempOutputPath)/final-sequence-previews"
            case .thumbnail:
                return nil
            }
        }
    }

    public var outputSequenceDirname: String {
        if let finalOutputDir {
            return finalOutputDir
        } else {
            return "\(self.outputPath)/\(self.basename)"
        }
    }
    
    public var allImageDirnames: [String] {
        var ret: [String] = []
        
        if let dir = self.dirForImage(ofType: .starAligned) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .failedStarAligned) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .failedEarthAligned) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .earthAligned) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .horizon) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .mergedHorizon) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .userHorizon) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .subtraction) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .validation) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .autoProcessed) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .autoSelectiveProcessed) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .selectiveProcessed) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .final) { ret.append(dir) }
        
        if self.writeFramePreviewFiles {
            if let dir = self.dirForImage(ofType: .original, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .starAligned, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .failedStarAligned, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .earthAligned, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .horizon, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .mergedHorizon, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .userHorizon, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .subtraction, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .validation, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .blobs, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .removeMask, atSize: .preview) { ret.append(dir) }
        }
        if self.writeFrameThumbnailFiles {
            if let dir = self.dirForImage(ofType: .original, atSize: .thumbnail) { ret.append(dir) }
        }
        if self.writeFrameProcessedPreviewFiles {
            if let dir = self.dirForImage(ofType: .final, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .autoProcessed, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .autoSelectiveProcessed, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .selectiveProcessed, atSize: .preview) { ret.append(dir) }
        }
        return ret
    }
}

public enum OutlierLoadingState: Sendable {
    case unloaded
    case loading
    case loaded
}

public struct Callbacks: Sendable {
    
    public var updatable: UpdatableLog?

    public var frameStateChangeCallback: (@Sendable (FrameAirplaneRemover, FrameProcessingState) -> ())?

    public var frameSavingStateChangeCallback: (@Sendable (FrameAirplaneRemover, FrameSavingState, FrameSavingState) -> ())?

    public var exisingFrameStateChangeCallback: (@Sendable (Int) -> ())?

    // called for the user to see a frame
    public var frameCheckClosure: (@Sendable (FrameAirplaneRemover) -> ())?

    public var frameOutliersLoadedCallback: (@Sendable (Int, OutlierLoadingState) -> Void)?

    /// Called when star notices something about the machine that the user should know
    /// before it becomes a crash — memory pressure, a footprint past its budget, a
    /// previous run that died.  See `StarWarning`.
    ///
    /// Setting this is not enough on its own: the things that notice these conditions are
    /// process-wide singletons, so call `installWarningHandler()` once after building the
    /// callbacks.  Kept as a field here rather than only as a `StarWarnings` call so that
    /// warnings live alongside every other client hook instead of in a separate mechanism
    /// a client has to know to go looking for.
    public var warningCallback: (@Sendable (StarWarning) -> ())?

    public init() { }

    /// Route `StarWarnings` to `warningCallback`, and record every warning into the current
    /// `RunMarker` so a run that gets killed leaves behind the last thing star noticed.
    ///
    /// Call once per client at startup.  Calling it again replaces the handler, which is
    /// what the gui needs when it opens a different sequence.
    public func installWarningHandler() async {
        let callback = self.warningCallback
        await StarWarnings.shared.set { warning in
            Task { await RunMarkerStore.shared.note(warning: warning) }
            callback?(warning)
        }
        // Installing the handler is also what turns on the source of the most important
        // warning.  Doing it here means a client cannot end up with a handler wired to
        // nothing, which is what happened while memory-pressure monitoring started lazily
        // inside `reserve()`.
        await MemoryMonitor.shared.startMonitoring()
    }
}


extension String {
    /// Returns a sanitized version of the string, replacing shell-unsafe characters with `_`.
    var sanitized: String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/")
        let ret = self.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.reduce("") { $0 + String($1) }
        return ret
    }
}
