import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// A cached stage whose artifacts are reused across runs, and which therefore has to be
/// invalidated when the inputs that produced them change.
///
/// Declared in dependency order, because each stage consumes the one before it: the
/// merged horizon is a vote over first-round horizon masks, and keypoint detection is
/// masked with the merged horizon.  `andDownstream` relies on that order.
public enum ArtifactStage: String, Codable, CaseIterable, Sendable {
    case horizon
    case mergedHorizon
    case keypoints

    /// This stage plus everything that consumes it.
    ///
    /// A stage whose own settings are unchanged is still stale if an upstream one
    /// changed, since its inputs were produced by the old settings.
    public var andDownstream: [ArtifactStage] {
        let all = ArtifactStage.allCases
        guard let index = all.firstIndex(of: self) else { return [self] }
        return Array(all[index...])
    }

    /// For log lines, which are English by design.  Deliberately not used in the
    /// user-facing warning: substituting an English fragment into a localised sentence
    /// produces a half-translated message, so the warning carries only a frame count and
    /// the specifics stay here in the log.
    public var logDescription: String {
        switch self {
        case .horizon:       return "horizon masks"
        case .mergedHorizon: return "merged horizon masks"
        case .keypoints:     return "keypoint sets"
        }
    }
}

/// What each cached stage was built with, recorded alongside the artifacts so a later
/// run can tell whether they are still valid.
///
/// Settings, mostly — but for keypoints also the version of the code that produced them,
/// since that stage's behaviour lives more in `ia_find_features` than in the handful of
/// settings that steer it.  See `detectionAlgorithmVersion`.
///
/// The skip predicates that let a re-run reuse these artifacts ask only whether the file
/// exists (see the note on `FrameAirplaneRemover`'s predicates).  That was as strong as
/// the loads it replaced — the pipeline has always reused whatever was on disk — but it
/// means changing a setting that feeds a stage had no effect on an already-processed
/// sequence.  Raise `alignmentMaxKeypoints` from 2000 to 3000 and every frame kept its
/// 2000-keypoint file; the only setting that ever forced a recompute was
/// `quantizedKeypointDivisor`, and only because it is encoded in the filename.
///
/// Values rather than a hash, deliberately.  A hash would answer "something changed",
/// which is not actionable — and a run that is about to throw away hours of alignment
/// should be able to say *why*.  Stored as strings so the file reads as a record of the
/// run, and so comparison never depends on how a Double happens to serialise.
///
/// Only settings that change what a stage *produces* belong here.  Not
/// `alignmentWriteDebugImages`, not `mergeStreamingThresholdMB`, not concurrency or
/// memory knobs: those change how the work is done or what it costs, and invalidating on
/// them would throw away good artifacts.
public struct ArtifactInputs: Codable, Sendable, Equatable {

    /// Bumped when the *set* of recorded settings changes in a way that makes an older
    /// file not comparable — a stage gaining an input it should always have had, say.
    /// A version mismatch is treated like a missing file rather than like a change, so
    /// upgrading star does not invalidate everyone's work.
    ///
    /// Which is exactly why this is not the lever for "the code that built these
    /// artifacts changed".  That is `detectionAlgorithmVersion`: a recorded input like
    /// any other, so it is compared, reported by name, and invalidates the one stage
    /// that contributes it.
    public static let currentVersion = 1

    /// Which version of the keypoint detection *code* produced a keypoint file.
    ///
    /// Everything else recorded here is a `Config` setting, which is enough for a stage
    /// whose behaviour lives in its settings.  Keypoint detection's largely does not:
    /// the settings only steer `ia_find_features`, and what decides where the features
    /// actually land — the mask handling, the contrast stretch the detector is handed,
    /// the star mask, SIFT and AKAZE and the cap applied to them — is code.  Change any
    /// of that and every cached keypoint file is a record of the old code, with nothing
    /// in the settings to say so.
    ///
    /// Not hypothetical: 485c4e04 moved `toGray8UWithMask`'s contrast stretch from
    /// min/max to percentiles, because one bright light in a near-black ground was
    /// quantising the whole ground to zero before AKAZE ever saw it.  That changes the
    /// image handed to detection on every frame, and so changes every keypoint set — and
    /// a user resuming an existing `star_temp_*` directory with the fixed build would
    /// otherwise keep the keypoints the old stretch produced and see the fix do nothing.
    ///
    /// Bump this whenever a change to `ia_find_features`, or to anything it calls,
    /// changes which keypoints come out.  Not for a change to cost, logging or debug
    /// images: a bump discards every cached keypoint file and every homography fitted to
    /// one, and that is the whole of a sequence's alignment.
    ///
    /// Safe to bump *because* `keypoints` is last in `ArtifactStage`'s dependency order.
    /// `andDownstream` is empty beyond it, so this reaches the alignment and the frames
    /// rendered from it and stops — the horizon stages, which cost far more to rebuild,
    /// are untouched.
    ///
    /// - 1: the min/max stretch — everything up to and including 0.11.5.  Never written
    ///      by anything: it is what a record that omits this key means, which is why the
    ///      key's mere appearance is what invalidates those records, once.
    /// - 2: percentile stretch (485c4e04).
    public static let detectionAlgorithmVersion = 2

    public let version: Int

    /// stage rawValue → setting name → value.  Nested rather than flat so a stage can be
    /// compared, reported and invalidated as a unit.
    public let stages: [String: [String: String]]

    public init(version: Int = ArtifactInputs.currentVersion,
                stages: [String: [String: String]]) {
        self.version = version
        self.stages = stages
    }

    // MARK: - Reading the current settings

    public static func current(from config: Config) -> ArtifactInputs {
        ArtifactInputs(stages: [
            ArtifactStage.horizon.rawValue:       horizonInputs(config),
            ArtifactStage.mergedHorizon.rawValue: mergedHorizonInputs(config),
            ArtifactStage.keypoints.rawValue:     keypointInputs(config),
        ])
    }

    /// What `FrameHorizonProcessor.loadOrCreateHorizonMask` reads.
    ///
    /// Branches on the detection mode so that changing a setting the current mode does
    /// not consult cannot invalidate anything.  The combined+RW detector takes no config
    /// at all — `CombinedHorizonDetector.detect(image:)` is fully parameterised in code
    /// — so in that mode the only input is the choice of mode itself.
    ///
    /// Which means this stage has the same blind spot `detectionAlgorithmVersion` closes
    /// for the keypoints, and more of it: in combined mode a change to the detector is
    /// invisible here.  Deliberately left open for now.  The two levers are not
    /// comparable in cost — `horizon` is first in the dependency order, so a version
    /// here would take the merged masks and every keypoint set and every homography with
    /// it, i.e. the entire sequence, where the keypoint lever stops at the alignment —
    /// and nothing has yet needed it: the horizon code changes since this landed are
    /// output-neutral by their own measurement (8364ff9e scales every candidate in a
    /// comparison equally, so the ordering it feeds cannot move; 97928062 fixes a trap on
    /// an empty horizon, a path that produced no mask to cache).  Add one the first time
    /// a horizon change moves a mask, and expect it to cost a full reprocess.
    private static func horizonInputs(_ config: Config) -> [String: String] {
        var inputs: [String: String] = [
            "horizonDetectionEnabled":    str(config.horizonDetectionEnabled),
            "useCombinedHorizonDetection": str(config.useCombinedHorizonDetection),
        ]
        guard !config.useCombinedHorizonDetection else { return inputs }

        inputs["useCannyForHorizonDetection"] = str(config.useCannyForHorizonDetection)
        inputs["cannyMinThreshold"]           = str(config.cannyMinThreshold)
        inputs["cannyMaxThreshold"]           = str(config.cannyMaxThreshold)
        inputs["cannyUseL2Gradient"]          = str(config.cannyUseL2Gradient)

        // The adaptive search runs only with at least two crop bounds; the single
        // parameter-set fallback reads none of the search settings.
        guard config.horizonSearchCropBounds.count >= 2 else { return inputs }

        inputs["horizonSearchCropBounds"]    = str(config.horizonSearchCropBounds)
        inputs["horizonSearchCropCount1"]    = str(config.horizonSearchCropCount1)
        inputs["horizonSearchCropCount2"]    = str(config.horizonSearchCropCount2)
        inputs["horizonSearchNarrowingRange"] = str(config.horizonSearchNarrowingRange)
        inputs["horizonSearchSize"]          = str(config.horizonSearchSize)
        // The effective grids, not the range/count pairs they come from: two different
        // range/count pairs that produce the same grid are the same input.
        inputs["dpHorizonSmoothnessLambdaValues"] = str(config.dpHorizonSmoothnessLambdaValues)
        inputs["dpHorizonSobelWeightValues"]      = str(config.dpHorizonSobelWeightValues)
        inputs["dpHorizonCannyWeightValues"]      = str(config.dpHorizonCannyWeightValues)
        return inputs
    }

    /// What `FrameHorizonProcessor.createMergedHorizonMask` reads.
    ///
    /// Includes the neighbour counts and their per-frame overrides, since those decide
    /// which masks are voted over.  The override maps are recorded whole: an override
    /// added for one frame changes that frame's merge, and the stage is invalidated
    /// sequence-wide because this record has no per-frame granularity.
    private static func mergedHorizonInputs(_ config: Config) -> [String: String] {
        var inputs: [String: String] = [
            "tripodHeadWasMoving":          str(config.tripodHeadWasMoving),
            "hasStaticReferenceHorizon":    str(config.hasStaticReferenceHorizon),
            "pixelThreshold":               str(config.pixelThreshold),
            "numberAlignedNeighborFrames":  str(config.numberAlignedNeighborFrames),
            "numberStaticNeighborFrames":   str(config.numberStaticNeighborFrames),
            "alignedNeighborFrameOverrides": str(config.alignedNeighborFrameOverrides),
            "staticNeighborFrameOverrides":  str(config.staticNeighborFrameOverrides),
        ]

        // The reference-horizon passes are moving-sequence only.
        guard config.tripodHeadWasMoving else { return inputs }

        inputs["useReferenceHorizonSmoothing"] = str(config.useReferenceHorizonSmoothing)
        if config.useReferenceHorizonSmoothing {
            inputs["referenceHorizonSmoothingMaxDistance"] =
              str(config.referenceHorizonSmoothingMaxDistance)
        }
        inputs["useReferenceHorizonBrightnessRefinement"] =
          str(config.useReferenceHorizonBrightnessRefinement)
        // Read by both the smoothing and the brightness-refinement passes.
        inputs["referenceHorizonNeighborhoodSize"] = str(config.referenceHorizonNeighborhoodSize)
        inputs["referenceHorizonBrightnessRefinementHistogramBuckets"] =
          str(config.referenceHorizonBrightnessRefinementHistogramBuckets)

        guard config.useReferenceHorizonBrightnessRefinement else { return inputs }

        inputs["referenceHorizonBrightnessRefinementSearchRadius"] =
          str(config.referenceHorizonBrightnessRefinementSearchRadius)
        inputs["horizonSpikeRemovalEnabled"] = str(config.horizonSpikeRemovalEnabled)
        if config.horizonSpikeRemovalEnabled {
            inputs["horizonSpikeMaxWidth"] = str(config.horizonSpikeMaxWidth)
            inputs["horizonSpikeMaxDeviationFraction"] =
              str(config.horizonSpikeMaxDeviationFraction)
            inputs["horizonSpikeWindowHalf"] = str(config.horizonSpikeWindowHalf)
        }
        return inputs
    }

    /// What `FrameAlignmentProcessor.loadOrCreateOCVFeatures` passes to
    /// `ImageAligner.findFeatures` — and, unlike the other two stages, the version of
    /// the code on the far side of that call.  See `detectionAlgorithmVersion` for why
    /// this stage needs one and what bumping it costs.
    ///
    /// `keypointDetectionScale` is recorded even though it is also encoded in the
    /// filename: the filename makes a divisor change invalidate on its own, but a run
    /// that changes several settings at once should still be able to report it.
    private static func keypointInputs(_ config: Config) -> [String: String] {
        [
            "detectionAlgorithmVersion":       str(detectionAlgorithmVersion),
            "keypointDetectionScale":          str(config.keypointDetectionScale),
            "alignmentMaxKeypoints":           str(config.alignmentMaxKeypoints),
            "alignmentGroundHorizonExtension": str(config.alignmentGroundHorizonExtension),
            "alignmentSkyHorizonExtension":    str(config.alignmentSkyHorizonExtension),
            "alignmentBaseImageDilateSize":    str(config.alignmentBaseImageDilateSize),
            "alignmentBaseImageThresholdValue": str(config.alignmentBaseImageThresholdValue),
            // Decides whether detection is masked with a horizon at all.
            "horizonDetectionEnabled":         str(config.horizonDetectionEnabled),
        ]
    }

    // MARK: - Comparison

    /// Which recorded settings differ from `other`, per stage, as
    /// `"name 2000 -> 3000"` strings ready for a log line.
    ///
    /// A stage missing from either side yields no differences: that is the shape of an
    /// older record, and a stage that was never recorded is not evidence of a change.
    /// Compare via `staleStages(comparedTo:)` rather than reading this directly, so the
    /// version check and the downstream cascade are not skipped.
    public func differences(from other: ArtifactInputs) -> [ArtifactStage: [String]] {
        var ret: [ArtifactStage: [String]] = [:]
        for stage in ArtifactStage.allCases {
            guard let mine = stages[stage.rawValue],
                  let theirs = other.stages[stage.rawValue]
            else { continue }

            // Settings that moved come before settings that merely started or stopped
            // being recorded.  That ordering carries real information: because the input
            // sets branch on mode, flipping one mode flag makes a dozen settings appear
            // at once, and the flag is the only one of the thirteen that explains
            // anything.  Reported in this order, the cause reads first.
            var moved: [String] = []
            var appearedOrLeft: [String] = []
            for key in Set(mine.keys).union(theirs.keys).sorted() {
                let before = theirs[key]
                let after = mine[key]
                guard before != after else { continue }
                let described = "\(key) \(before ?? "<unset>") -> \(after ?? "<unset>")"
                if before != nil, after != nil {
                    moved.append(described)
                } else {
                    appearedOrLeft.append(described)
                }
            }
            let changes = moved + appearedOrLeft
            if !changes.isEmpty { ret[stage] = changes }
        }
        return ret
    }

    /// The stages whose artifacts `stored` can no longer be trusted for, including
    /// everything downstream of each change.
    ///
    /// Nil `stored`, or a record from a different `version`, yields no stale stages.
    /// That is the deliberate choice for the sequences that already exist on disk: they
    /// have no record, and treating "I cannot tell" as "everything is stale" would make
    /// upgrading star silently reprocess every sequence anyone still has temp files for.
    /// The cost is that a setting changed *before* this ever ran is not caught, which is
    /// exactly the behaviour those sequences have today.
    public func staleStages(comparedTo stored: ArtifactInputs?) -> Set<ArtifactStage> {
        guard let stored else { return [] }
        guard stored.version == version else {
            Log.i("artifact input record is version \(stored.version), this star writes " +
                  "\(version) — treating it as absent rather than as a change, so nothing " +
                  "is invalidated on the strength of a format difference alone")
            return []
        }
        var stale: Set<ArtifactStage> = []
        for stage in differences(from: stored).keys {
            stale.formUnion(stage.andDownstream)
        }
        return stale
    }

    // MARK: - Persistence

    /// Where the record lives, next to the artifacts it describes.
    public static func filename(inTempOutputPath tempOutputPath: String) -> String {
        "\(tempOutputPath)/artifact_inputs.json"
    }

    /// Read the record for this run's temp output, or nil when there is none to read.
    ///
    /// An unreadable or unparseable file is nil too: it means the same thing here as an
    /// absent one — no trustworthy record of what these artifacts were built with — and
    /// failing the run over it would be worse than not invalidating.
    public static func load(fromTempOutputPath tempOutputPath: String) -> ArtifactInputs? {
        let path = filename(inTempOutputPath: tempOutputPath)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try JSONDecoder().decode(ArtifactInputs.self, from: data)
        } catch {
            Log.w("could not read \(path): \(error) — treating it as absent")
            return nil
        }
    }

    /// Persist this record, overwriting any existing one.
    ///
    /// Sorted keys and pretty printing on purpose: this file is meant to be readable,
    /// and a stable key order makes `diff` between two runs' records useful.
    public func save(toTempOutputPath tempOutputPath: String) throws {
        let path = Self.filename(inTempOutputPath: tempOutputPath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        StarCore.mkdir(tempOutputPath)
        try data.write(to: URL(fileURLWithPath: path))
        Log.d("wrote \(path)")
    }

    // MARK: - Value formatting

    /// One place that turns a setting into its recorded form, so a value cannot be
    /// written one way and compared another.
    ///
    /// `%.10g` for Doubles: enough digits to separate any two settings a user could
    /// mean, few enough that the same number never records two ways because it arrived
    /// via different arithmetic.
    private static func str(_ value: Bool) -> String { value ? "true" : "false" }
    private static func str(_ value: Int) -> String { "\(value)" }
    private static func str(_ value: Double) -> String { String(format: "%.10g", value) }
    private static func str(_ values: [Int]) -> String {
        "[" + values.map { str($0) }.joined(separator: ",") + "]"
    }
    private static func str(_ values: [Double]) -> String {
        "[" + values.map { str($0) }.joined(separator: ",") + "]"
    }
    /// Sorted by key so an unordered dictionary cannot record two ways.
    private static func str(_ values: [Int: Int]) -> String {
        "[" + values.keys.sorted().map { "\($0):\(values[$0]!)" }.joined(separator: ",") + "]"
    }
}
