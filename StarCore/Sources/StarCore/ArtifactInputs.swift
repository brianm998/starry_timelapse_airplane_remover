import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// A cached stage whose artifacts are reused across runs, and which therefore has to be
/// invalidated when the settings that produced them change.
///
/// Declared in dependency order, because each stage consumes the one before it: the
/// merged horizon is a vote over first-round horizon masks, and keypoint detection is
/// masked with the merged horizon.  `andDownstream` relies on that order.
public enum ArtifactStage: String, Codable, CaseIterable, Sendable {
    case horizon
    case mergedHorizon
    case keypoints
    case alignment
    case outliers
    case output

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
        case .alignment:     return "alignment results"
        case .outliers:      return "outlier groups"
        case .output:        return "output images"
        }
    }

    /// What this stage leaves on disk — the other half of the setting-to-file mapping,
    /// whose first half is `ArtifactInputs.current(from:)`.
    ///
    /// English, and for logs, like `logDescription`.  What actually deletes these is
    /// `FrameGraphBuilder.invalidateStaleArtifacts`, and this is the list that switch has
    /// to keep matching: a stage that records a setting but deletes nothing when it moves
    /// is exactly the bug `ArtifactInputs` exists to fix, one level further down.
    public var artifactDescription: String {
        switch self {
        case .horizon:
            return "<temp>/*-horizon-*.tif (full size and preview)"
        case .mergedHorizon:
            return "<temp>/*-mergedHorizon-*.tif (full size and preview)"
        case .keypoints:
            return "<temp>/keypoints/*.yml, for both star and earth alignment"
        case .alignment:
            return "homography.db rows, the aligned-neighbour count file, and the " +
                   "starAligned / earthAligned / subtraction images"
        case .outliers:
            return "<outliers>/<frame>/, the classified outlier group binary"
        case .output:
            return "the written output frame, and the autoProcessed / " +
                   "autoSelectiveProcessed / selectiveProcessed previews beside it"
        }
    }
}

/// The settings each cached stage was built with, recorded alongside the artifacts so a
/// later run can tell whether they are still valid.
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
    public static let currentVersion = 1

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
            ArtifactStage.alignment.rawValue:     alignmentInputs(config),
            ArtifactStage.outliers.rawValue:      outlierInputs(config),
            ArtifactStage.output.rawValue:        outputInputs(config),
        ])
    }

    /// What `FrameHorizonProcessor.loadOrCreateHorizonMask` reads.
    ///
    /// Branches on the detection mode so that changing a setting the current mode does
    /// not consult cannot invalidate anything.  The combined+RW detector takes no config
    /// at all — `CombinedHorizonDetector.detect(image:)` is fully parameterised in code
    /// — so in that mode the only input is the choice of mode itself.
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
    /// `ImageAligner.findFeatures`.
    ///
    /// `keypointDetectionScale` is recorded even though it is also encoded in the
    /// filename: the filename makes a divisor change invalidate on its own, but a run
    /// that changes several settings at once should still be able to report it.
    private static func keypointInputs(_ config: Config) -> [String: String] {
        [
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

    /// What `FrameAlignmentProcessor`, `HomographyOp` and `AlignmentValidationOp` read.
    ///
    /// The stored homography is fitted to the keypoints and to a particular set of
    /// neighbours, so which neighbours and how many is an input to it, as is
    /// `pixelThreshold` — the outlier threshold the aligned neighbours are median merged
    /// under, which decides the pixels the merged neighbour ends up with.
    ///
    /// `alignmentNeighborDilateSize` and `alignmentNeighborThresholdValue` are absent on
    /// purpose: they are `Config` fields with a `FocusedField` case each and no reader
    /// anywhere in the pipeline.  Recording a setting nothing consumes would throw away
    /// alignment when it moved, for no change in what came out.
    private static func alignmentInputs(_ config: Config) -> [String: String] {
        var inputs: [String: String] = [
            "tripodHeadWasMoving":           str(config.tripodHeadWasMoving),
            "allowEarthAlignment":           str(config.allowEarthAlignment),
            "homographySmoothingEpsilon":    str(config.homographySmoothingEpsilon),
            "pixelThreshold":                str(config.pixelThreshold),
            "numberAlignedNeighborFrames":   str(config.numberAlignedNeighborFrames),
            "numberStaticNeighborFrames":    str(config.numberStaticNeighborFrames),
            "alignedNeighborFrameOverrides": str(config.alignedNeighborFrameOverrides),
            "staticNeighborFrameOverrides":  str(config.staticNeighborFrameOverrides),
            // Whether the merge is masked with a horizon, and so whether the sky and the
            // ground are aligned separately at all.
            "horizonDetectionEnabled":       str(config.horizonDetectionEnabled),
        ]
        // A fixed camera has no ground to align: the earth branch median merges the
        // static neighbours instead, and reads none of the earth settings.
        if !config.tripodHeadWasMoving {
            inputs.removeValue(forKey: "allowEarthAlignment")
        }
        return inputs
    }

    /// What outlier detection reads.
    ///
    /// `detectionType` picks the blob processor — `FrameOutlierProcessor` reads it from
    /// `constants` rather than from here, but it is `Config` that seeds those (see
    /// `Session.swift` and the gui's `applySettings`), and it is `Config` that persists
    /// it across runs.
    ///
    /// Recorded only for a clean method that has outliers at all: for `.automatic(false)`
    /// no outlier group is ever written, so nothing about their detection can be stale.
    private static func outlierInputs(_ config: Config) -> [String: String] {
        var inputs: [String: String] = [
            "cleanMethod": str(config.cleanMethod),
        ]
        guard config.cleanMethod.usesOutliers else { return inputs }

        inputs["detectionType"] = config.detectionType.rawValue
        inputs["ignoreLowerPixels"] = str(config.ignoreLowerPixels)
        // The radius of neighbouring frames each group is classified against.
        inputs["numberFinalProcessingNeighborsNeeded"] =
          str(config.numberFinalProcessingNeighborsNeeded)
        return inputs
    }

    /// What `FrameAirplaneRemover` reads while writing the finished frame.
    ///
    /// The last stage, so everything upstream cascades into it and only what it reads
    /// *itself* belongs here: how the removed pixels are painted, which layer the frame is
    /// composited from, and the per-frame clean method overrides the user sets from the
    /// right panel.
    private static func outputInputs(_ config: Config) -> [String: String] {
        var inputs: [String: String] = [
            "cleanMethod":                          str(config.cleanMethod),
            "pixelReplacementOverrides":            str(config.pixelReplacementOverrides),
            "outlierGroupPaintBorderPixels":        str(config.outlierGroupPaintBorderPixels),
            "outlierGroupPaintBorderInnerWallPixels":
              str(config.outlierGroupPaintBorderInnerWallPixels),
            // Decides whether the sky is composited back over the ground at all.
            "horizonDetectionEnabled":              str(config.horizonDetectionEnabled),
        ]
        // Which layer the sky is composited over — but only where there are two layers.
        // A fixed camera never aligns the ground, whatever this says.
        if config.tripodHeadWasMoving {
            inputs["allowEarthAlignment"] = str(config.allowEarthAlignment)
        }
        return inputs
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

    /// Spelled here rather than taken from `String(describing:)`, which is a debug
    /// description and free to change with the compiler — this string is compared against
    /// one written by an earlier version of star.
    private static func str(_ value: CleanMethod) -> String {
        switch value {
        case .automatic(let selective): return "automatic(\(str(selective)))"
        case .selective:                return "selective"
        }
    }

    private static func str(_ values: [Int: CleanMethod]) -> String {
        "[" + values.keys.sorted()
                .map { "\($0):\(str(values[$0]!))" }
                .joined(separator: ",") + "]"
    }
}
