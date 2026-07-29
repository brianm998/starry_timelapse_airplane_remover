import Foundation
import StarCore

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// Every command line flag that overrides a field on a `Config`, in one place, so that
/// it applies however that `Config` was arrived at.
///
/// star's positional argument is either an image sequence dirname, where the `Config` is
/// built from scratch, or a previously saved `config.json`, where it is decoded from
/// disk. The flags below used to be applied only on the first path: the config file
/// branch loaded the config and applied nothing but `writeOutlierClassificationValues`,
/// so `star --half-res-keypoints --log-op-memory foo/config.json` ran with neither in
/// effect and said nothing about it. Every flag now goes through here, which is the
/// point of the type — a new flag wired into one branch and forgotten in the other is no
/// longer possible, because there is only one branch to wire it into.
///
/// `nil` means the user asked for nothing, so whatever the config already holds
/// survives. That is why the `@Option`s are `Int?` rather than `Int`, and it is why the
/// `@Flag`s — which cannot be nil, since they default to false and have no `--no-` form
/// — are only ever carried here as `true`. Handing over a `false` that means "the user
/// did not type this flag" would overwrite a saved config's `true`, which is the same
/// bug pointed the other way.
///
/// `writeOutputFiles` is the one flag that does arrive as either. `-s` is the only flag
/// that takes output away rather than adding some, so a saved `false` that no flag can
/// clear would be a config that never renders again; it is declared `Bool?` with a
/// `--no-` form so that "off", "on" and "unmentioned" are three different things rather
/// than two.
///
/// Note that `writeOutlierClassificationValues` changes behaviour on the config file
/// path because of this: it used to be assigned unconditionally there, so resuming a
/// config that had it set, without passing `-W`, turned it back off. It now survives.
///
/// Deliberately absent: `--output-path`. A saved config's `outputPath` and
/// `tempOutputPath` are where its temp state already lives, so repointing them mid
/// resume would strand the run rather than redirect it.
struct ConfigOverrides {

    var cleanMethod: CleanMethod?
    var detectionType: DetectionType?
    var finalOutputDir: String?
    /// `-w`, which drives four config fields rather than one.
    var writeOutlierGroupFiles: Bool?
    var writeOutlierClassificationValues: Bool?
    /// `-s`, inverted: the flag turns writing the output images off.
    var writeOutputFiles: Bool?
    /// `--no-horizon`, inverted: the flag turns horizon detection off.
    var horizonDetectionEnabled: Bool?
    var tripodHeadWasMoving: Bool?
    var alignmentHalfResolutionKeypoints: Bool?
    var mergeStreamingThresholdMB: Int?
    var maxConcurrentKeypointOps: Int?
    var horizonReservationFloorMB: Int?
    var numberOfFramesToProcessConcurrently: Int?
    var ignoreLowerPixels: Int?

    func apply(to config: inout Config) {
        if let cleanMethod { config.cleanMethod = cleanMethod }
        if let detectionType { config.detectionType = detectionType }
        if let finalOutputDir { config.finalOutputDir = finalOutputDir }
        if let writeOutlierGroupFiles {
            // one flag, four fields — the previews and thumbnails are what makes the
            // written outlier group files legible, so they have always moved together
            config.writeOutlierGroupFiles = writeOutlierGroupFiles
            config.writeFramePreviewFiles = writeOutlierGroupFiles
            config.writeFrameProcessedPreviewFiles = writeOutlierGroupFiles
            config.writeFrameThumbnailFiles = writeOutlierGroupFiles
        }
        if let writeOutlierClassificationValues {
            config.writeOutlierClassificationValues = writeOutlierClassificationValues
        }
        if let writeOutputFiles { config.writeOutputFiles = writeOutputFiles }
        if let horizonDetectionEnabled {
            config.horizonDetectionEnabled = horizonDetectionEnabled
        }
        if let tripodHeadWasMoving { config.tripodHeadWasMoving = tripodHeadWasMoving }
        if let alignmentHalfResolutionKeypoints {
            config.alignmentHalfResolutionKeypoints = alignmentHalfResolutionKeypoints
        }
        if let mergeStreamingThresholdMB {
            config.mergeStreamingThresholdMB = mergeStreamingThresholdMB
        }
        if let maxConcurrentKeypointOps {
            config.maxConcurrentKeypointOps = maxConcurrentKeypointOps
        }
        if let horizonReservationFloorMB {
            config.horizonReservationFloorMB = horizonReservationFloorMB
        }
        if let numberOfFramesToProcessConcurrently {
            config.numberOfFramesToProcessConcurrently = numberOfFramesToProcessConcurrently
        }
        if let ignoreLowerPixels { config.ignoreLowerPixels = ignoreLowerPixels }
    }
}
