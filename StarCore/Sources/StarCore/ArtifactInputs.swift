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
///
/// `horizonConsensus` reads the first-round masks and the alignment, and is read by both
/// stages after it: the outlier subtraction and the output composite the two aligned layers
/// across the horizon.
public enum ArtifactStage: String, Codable, CaseIterable, Sendable {
    case horizon
    case mergedHorizon
    case keypoints
    case alignment
    case horizonConsensus
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
        case .horizonConsensus: return "horizon consensus lines"
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
        case .horizonConsensus:
            return "<temp>/horizonConsensus/<frame>.json, and the calibration.json beside them"
        case .outliers:
            return "<outliers>/<frame>/, the classified outlier group binary"
        case .output:
            return "the written output frame, and the autoProcessed / " +
                   "autoSelectiveProcessed / selectiveProcessed previews beside it"
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
    /// Safe to bump *because* nothing upstream of `keypoints` depends on it.
    /// `andDownstream` reaches the alignment, the outlier groups and the frames rendered
    /// from them, and stops there — the horizon stages, which cost far more to rebuild,
    /// are untouched.  (This used to say "because `keypoints` is last"; the three stages
    /// after it were split out of what `invalidateStaleArtifacts` did in one lump, so the
    /// reach is the same work, now named.)
    ///
    /// - 1: the min/max stretch — everything up to and including 0.11.5.  Never written
    ///      by anything: it is what a record that omits this key means, which is why the
    ///      key's mere appearance is what invalidates those records, once.
    /// - 2: percentile stretch (485c4e04).
    /// - 3: sky keypoints kept `kSkyKeypointCutMargin` clear of the sky mask's edge, where
    ///      the black step the masking leaves is ground-locked (ImageAligner.cpp).  This
    ///      bump also carries the sky RANSAC tolerance going from 10px to 3px: that is a
    ///      change to the fit rather than to the keypoints, but it shipped with this one,
    ///      and invalidating the keypoints already takes every homography with them.  A
    ///      fitting change that ships on its own needs a lever on the alignment stage.
    /// - 4: sky feature files keep the frame's star centroids, and the sky homography is
    ///      refined against them (ImageAligner.cpp, refineSkyHomographyWithStars).  A
    ///      version-3 file has no stars, so it would quietly skip the refinement.
    public static let detectionAlgorithmVersion = 4

    /// Which version of the homography *fitting* code produced the stored alignment —
    /// `detectionAlgorithmVersion`'s counterpart for the stage after it, for a change to
    /// `ia_compute_homography` that leaves the keypoints alone.  Bumping the keypoint lever
    /// for one of those would also work, and would re-run every frame's SIFT for nothing.
    ///
    /// Recorded unconditionally, so a record that predates the key counts as changed and
    /// its alignment, outliers and output are rebuilt once.  Every such record also
    /// predates `detectionAlgorithmVersion` 3, which rebuilds those anyway.
    ///
    /// - 1: everything before this key existed.  Never written.
    /// - 2: a sky keypoint fit that plentiful stars refuse, standing on a thin RANSAC
    ///      consensus, is dropped rather than kept (ImageAligner.cpp,
    ///      starsOverruleThinSkyFit).
    public static let alignmentAlgorithmVersion = 2

    /// Which version of the *ground* fit produced the stored earth homographies — the
    /// lever for a change to how `ia_compute_homography` fits the ground alone.
    ///
    /// Not `alignmentAlgorithmVersion`, because only a moving camera with earth alignment
    /// and horizon detection on has earth homographies (`FrameGraphBuilder` builds no
    /// earth homography op otherwise), and bumping the shared lever would re-fit every
    /// static sequence's sky for a change that cannot reach it.  So this is recorded only
    /// where the ground is fitted, the way `cloudAwareMerge` is recorded only while on: a
    /// record that predates the key, from a sequence that does fit its ground, counts as
    /// changed and is re-aligned once; every other record is the one it always was.
    ///
    /// - 1: a 4-DOF similarity (cv::estimateAffinePartial2D).  Never written.
    /// - 2: a camera rotation, K R K^-1, about the frame's centre, with each frame's focal
    ///      length calibrated from its own correspondences (ImageAligner.cpp,
    ///      calibrateGroundFocalLength).
    public static let earthAlignmentAlgorithmVersion = 2

    /// Which version of `CombinedHorizonDetector`, as `FrameHorizonProcessor` runs it on each
    /// frame of a moving sequence, produced the stored first-round horizon masks.
    ///
    /// Recorded only for a moving camera with combined detection on, the one place
    /// per-frame masks are still detected with it (see `horizonInputs`).  A record that
    /// predates the key, from such a sequence, counts as changed and is rebuilt from
    /// scratch once — the whole sequence, since every later stage reads these masks.
    ///
    /// The bump covers frames detected without references, which is what changed; a run
    /// guided by painted references searches the band they give, which did not, but it is
    /// rebuilt too: this record cannot tell the two apart without flipping every time the
    /// first reference is painted, which would cost a full rebuild each time instead of once.
    ///
    /// - 1: everything before this key existed.  Never written.
    /// - 2: the base methods search down to 0.99 of the height rather than 0.85/0.95, so a
    ///      low horizon can be found at all, and an unguided frame is detected on a copy
    ///      `TemporalHorizonDetector.workingWidth` wide (6804f8f3).
    public static let movingHorizonDetectionAlgorithmVersion = 2

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
            ArtifactStage.horizonConsensus.rawValue: horizonConsensusInputs(config),
            ArtifactStage.outliers.rawValue:      outlierInputs(config),
            ArtifactStage.output.rawValue:        outputInputs(config),
        ])
    }

    /// What `FrameHorizonProcessor.loadOrCreateHorizonMask` reads.
    ///
    /// Branches on the detection mode so that changing a setting the current mode does
    /// not consult cannot invalidate anything.  The combined+RW detector takes no config
    /// at all — `CombinedHorizonDetector.detect(image:)` is fully parameterised in code
    /// — so in that mode the inputs are the choice of mode and the code's version.
    ///
    /// That version is `movingHorizonDetectionAlgorithmVersion`, recorded only where
    /// per-frame masks are detected with it: a moving camera.  `horizon` is first in the dependency order, so
    /// bumping it takes the merged masks and every keypoint set and every homography with
    /// it, i.e. the entire sequence — a lever for a change that moves masks, not for one
    /// that is output-neutral by its own measurement (8364ff9e, 97928062).
    private static func horizonInputs(_ config: Config) -> [String: String] {
        var inputs: [String: String] = [
            "horizonDetectionEnabled":    str(config.horizonDetectionEnabled),
            "useCombinedHorizonDetection": str(config.useCombinedHorizonDetection),
        ]
        if config.useCombinedHorizonDetection {
            // A static sequence detects no per-frame masks at all — its merge reads the
            // temporal median or the painted reference — so the version means nothing there,
            // and recording it would rebuild a static sequence for a change it never sees.
            if config.horizonDetectionEnabled && config.tripodHeadWasMoving {
                inputs["movingHorizonDetectionAlgorithmVersion"] =
                  str(movingHorizonDetectionAlgorithmVersion)
            }
            return inputs
        }

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

        // A static sequence's merged mask is made by one of two methods (see
        // `Config.useTemporalStaticHorizon`), and they give different masks — on a black
        // ground under the Milky Way, masks 15% of the frame apart.  Recorded with the
        // temporal method's own version, so a change to it rebuilds what it made.
        //
        // Only where the merge actually runs: a painted reference replaces it outright,
        // and recording the method there would rebuild a sequence's keypoints and
        // alignment over a mask nothing reads.
        if !config.tripodHeadWasMoving && !config.hasStaticReferenceHorizon {
            inputs["useTemporalStaticHorizon"] = str(config.useTemporalStaticHorizon)
            if config.useTemporalStaticHorizon {
                inputs["temporalHorizonSampleCount"] = str(config.temporalHorizonSampleCount)
                inputs["temporalHorizonAlgorithmVersion"] =
                  str(TemporalHorizonDetector.algorithmVersion)
            }
        }

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
            "alignmentAlgorithmVersion":     str(alignmentAlgorithmVersion),
        ]
        // A fixed camera has no ground to align: the earth branch median merges the
        // static neighbours instead, and reads none of the earth settings.
        if !config.tripodHeadWasMoving {
            inputs.removeValue(forKey: "allowEarthAlignment")
        }
        // The ground fit's version, where there is a ground fit: see
        // `earthAlignmentAlgorithmVersion`, and the condition FrameGraphBuilder builds
        // the earth homography ops under.
        if config.tripodHeadWasMoving && config.allowEarthAlignment &&
             config.horizonDetectionEnabled
        {
            inputs["earthAlignmentAlgorithmVersion"] = str(earthAlignmentAlgorithmVersion)
        }
        // The cloud-aware merge changes the star aligned image this stage writes, so it
        // is an input to it, but it is recorded only while it is on.  A record that lacks
        // a key counts as changed, so adding the key unconditionally would make every
        // existing temp dir throw away its alignment, outliers and output on the first
        // run after upgrading, with the flag off.  Recorded only when on, a flag-off
        // record is the one it always was, turning it on invalidates, and turning it off
        // again invalidates too, since the record differs from the one that had it.
        if config.cloudAwareMerge {
            inputs["cloudAwareMerge"] = str(config.cloudAwareMerge)
        }
        return inputs
    }

    /// What `HorizonConsensus` reads beyond the stages before it: whether it runs, and the
    /// version of the code.
    ///
    /// Only the camera's motion where it cannot run — a fixed camera, or a run without earth
    /// alignment — so its switch moving there invalidates nothing.  A record from before the
    /// stage existed has no entry for it at all, which counts as no change: the output
    /// already written for such a sequence was composited with its merged masks, and is kept.
    private static func horizonConsensusInputs(_ config: Config) -> [String: String] {
        var inputs: [String: String] = [
            "tripodHeadWasMoving": str(config.tripodHeadWasMoving),
        ]
        guard config.tripodHeadWasMoving, config.horizonDetectionEnabled,
              config.allowEarthAlignment
        else { return inputs }
        inputs["useHorizonConsensus"] = str(config.useHorizonConsensus)
        if config.useHorizonConsensus {
            inputs["horizonConsensusAlgorithmVersion"] = str(HorizonConsensus.algorithmVersion)
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
        // How far the line connector follows neighbours decides which blobs get joined. Recorded
        // only when it is not the default, for the reason `cloudAwareMerge` is above: a record
        // that lacks a key counts as changed, so an unconditional key would throw away every
        // existing temp dir's outliers once. Off the default (including 0, the old unbounded
        // behaviour) it invalidates, and so does returning to the default.
        if config.linearConnectorNeighborHops != Config().linearConnectorNeighborHops {
            inputs["linearConnectorNeighborHops"] = str(config.linearConnectorNeighborHops)
        }
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
        // atomically: a crash part way through a plain write left a torn record, which reads as
        // absent and so invalidates nothing and rebuilds nothing, for the whole temp dir
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
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
