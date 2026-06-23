import Foundation
import StarCore
import StarDaemonMessages

// Bidirectional type mapping between StarCore types and proto types.
enum Mapping {

    // MARK: - FrameViewMode

    static func frameViewMode(from proto: Star_V1_FrameViewMode) -> StarCore.FrameViewMode {
        switch proto {
        case .viewOriginal:    return .original
        case .viewProcessed:   return .autoProcessed
        case .viewSubtraction: return .subtraction
        case .viewValidation:  return .validation
        default:               return .original
        }
    }

    // MARK: - FrameProcessingState

    static func frameProcessingState(_ s: FrameProcessingState) -> Star_V1_FrameProcessingState {
        switch s {
        case .unprocessed:               return .fpsUnprocessed
        case .horizonDetection:          return .fpsHorizonDetection
        case .horizonDetected:           return .fpsHorizonDetected
        case .mergingHorizon:            return .fpsMergingHorizon
        case .earthAlignment(let step):
            switch step {
            case .start:                     return .fpsEarthAlignmentStart
            case .baseKeypointDetection:     return .fpsEarthAlignmentBaseKp
            case .baseKeypointDetectionComplete: return .fpsEarthAlignmentBaseKpDone
            case .aligningNeighbor:          return .fpsEarthAlignmentAligning
            case .loadingNeighbor:           return .fpsEarthAlignmentLoading
            case .complete:                  return .fpsEarthAlignmentComplete
            default:                         return .fpsEarthAlignmentAligning
            }
        case .creatingEarthAlignedFrame: return .fpsCreatingEarthAligned
        case .starKeypoints:             return .fpsStarKeypoints
        case .earthKeypoints:            return .fpsEarthKeypoints
        case .starKeypointsFound:        return .fpsStarKeypointsFound
        case .earthKeypointsFound:       return .fpsEarthKeypointsFound
        case .starAlignment(let step):
            switch step {
            case .start:                     return .fpsStarAlignmentStart
            case .baseKeypointDetection:     return .fpsStarAlignmentBaseKp
            case .baseKeypointDetectionComplete: return .fpsStarAlignmentBaseKpDone
            case .aligningNeighbor:          return .fpsStarAlignmentAligning
            case .loadingNeighbor:           return .fpsStarAlignmentLoading
            case .complete:                  return .fpsStarAlignmentComplete
            default:                         return .fpsStarAlignmentAligning
            }
        case .starAlignmentFailed:       return .fpsStarAlignmentFailed
        case .creatingStarAlignedFrame:  return .fpsCreatingStarAligned
        case .subtractingNeighbor:       return .fpsSubtractingNeighbor
        case .assemblingPixels:          return .fpsAssemblingPixels
        case .sortingPixels:             return .fpsSortingPixels
        case .detectingBlobs:            return .fpsDetectingBlobs
        case .filter1:                   return .fpsFilter1
        case .filter2:                   return .fpsFilter2
        case .filter3:                   return .fpsFilter3
        case .filter4:                   return .fpsFilter4
        case .filter5:                   return .fpsFilter5
        case .filter6:                   return .fpsFilter6
        case .filter7:                   return .fpsFilter7
        case .filter8:                   return .fpsFilter8
        case .firstClassification:       return .fpsFirstClassification
        case .readyForInterFrameProcessing: return .fpsReadyForInterFrame
        case .secondClassification:      return .fpsSecondClassification
        case .outlierProcessingComplete: return .fpsOutlierProcessingComplete
        case .finishing:                 return .fpsFinishing
        case .userModified:              return .fpsUserModified
        case .writingOutlierValues:      return .fpsWritingOutlierValues
        case .waitingToLoadImages:       return .fpsWaitingToLoadImages
        case .loadingImages:             return .fpsLoadingImages
        case .loadingImages1:            return .fpsLoadingImages1
        case .creatingRemovalMask:       return .fpsCreatingRemovalMask
        case .assemblingProcessedFrame:  return .fpsAssemblingProcessedFrame
        case .writingOutputFile:         return .fpsWritingOutputFile
        case .complete:                  return .fpsComplete
        }
    }

    // MARK: - CleanMethod

    static func cleanMethod(from proto: Star_V1_Config) -> CleanMethod {
        switch proto.cleanMethod {
        case .cleanSelective:     return .selective
        case .cleanAutomaticTrue: return .automatic(true)
        default:                  return .automatic(false)
        }
    }

    static func protoCleanMethod(_ cm: CleanMethod) -> Star_V1_CleanMethod {
        switch cm {
        case .selective:        return .cleanSelective
        case .automatic(true):  return .cleanAutomaticTrue
        case .automatic(false): return .cleanAutomatic
        }
    }

    // MARK: - DetectionType

    static func detectionType(from proto: Star_V1_DetectionType) -> DetectionType {
        switch proto {
        case .detectionMild:      return .mild
        case .detectionStrong:    return .strong
        case .detectionStronger:  return .stronger
        case .detectionExcessive: return .excessive
        case .detectionCustom:    return .custom
        default:                  return .strong
        }
    }

    static func protoDetectionType(_ dt: DetectionType) -> Star_V1_DetectionType {
        switch dt {
        case .mild:      return .detectionMild
        case .strong:    return .detectionStrong
        case .stronger:  return .detectionStronger
        case .excessive: return .detectionExcessive
        case .custom:    return .detectionCustom
        }
    }

    // MARK: - RemoveReason

    static func protoRemoveReason(_ rr: RemoveReason?) -> Star_V1_RemoveReason {
        guard let rr else { return .rrUndecided }
        switch rr {
        case .userSelected(true):          return .rrUserRemove
        case .userSelected(false):         return .rrUserKeep
        case .fromClassifier(let score):
            return score > 0 ? .rrClassifierRemove : .rrClassifierKeep
        }
    }

    static func removeReason(from proto: Star_V1_RemoveReason) -> RemoveReason? {
        switch proto {
        case .rrUndecided:        return nil
        case .rrUserRemove:       return .userSelected(true)
        case .rrUserKeep:         return .userSelected(false)
        case .rrClassifierRemove: return .fromClassifier(1.0)
        case .rrClassifierKeep:   return .fromClassifier(-1.0)
        default:                  return nil
        }
    }

    // MARK: - BoundingBox

    static func protoBoundingBox(_ bb: BoundingBox) -> Star_V1_BoundingBox {
        var out = Star_V1_BoundingBox()
        out.minX = Int32(bb.min.x)
        out.minY = Int32(bb.min.y)
        out.maxX = Int32(bb.max.x)
        out.maxY = Int32(bb.max.y)
        return out
    }

    // MARK: - Alignment

    static func protoAlignmentState(_ s: AlignmentState) -> Star_V1_AlignmentState {
        switch s {
        case .unableToDetectKeypoints: return .alignUnableToDetectKeypoints
        case .notEnoughKeypoints:      return .alignNotEnoughKeypoints
        case .noHomographyFound:       return .alignNoHomographyFound
        case .homographySuccess:       return .alignHomographySuccess
        case .usedExistingHomography:  return .alignUsedExistingHomography
        case .noAlignment:             return .alignNoAlignment
        case .unknown:                 return .alignUnknown
        }
    }

    static func protoNeighborHomography(_ w: AlignmentWarpInfoCodable, includeHomography: Bool) -> Star_V1_NeighborHomography {
        var out = Star_V1_NeighborHomography()
        out.frameIndex = Int32(w.frameIndex)
        out.deviation = w.deviation
        out.state = protoAlignmentState(w.alignmentState)
        if includeHomography, let h = w.homography { out.homography = h }
        return out
    }

    static func protoHomographyResults(_ h: HomographyResultsCodable, includeHomography: Bool) -> Star_V1_HomographyResults {
        var out = Star_V1_HomographyResults()
        out.frameIndex = Int32(h.frameIndex)
        out.compositeDeviation = h.compositeDeviation
        out.alignmentLooksOk = h.alignmentLooksOk
        out.neighbors = h.neighborHomography.map { protoNeighborHomography($0, includeHomography: includeHomography) }
        return out
    }

    // MARK: - Config round-trip

    static func protoConfig(_ c: Config) -> Star_V1_Config {
        var out = Star_V1_Config()
        out.outputPath = c.outputPath
        out.tempOutputPath = c.tempOutputPath
        out.cleanMethod = protoCleanMethod(c.cleanMethod)
        out.detectionType = protoDetectionType(c.detectionType)
        out.horizonDetectionEnabled = c.horizonDetectionEnabled
        out.tripodHeadWasMoving = c.tripodHeadWasMoving
        out.numberOfFramesToProcessConcurrently = Int32(c.numberOfFramesToProcessConcurrently)
        if c.ignoreLowerPixels != 0 { out.ignoreLowerPixels = Int32(c.ignoreLowerPixels) }
        out.writeOutlierGroupFiles = c.writeOutlierGroupFiles
        out.writeFramePreviewFiles = c.writeFramePreviewFiles
        out.starVersion = c.starVersion
        var ves = Star_V1_VideoEncodeSettings()
        ves.frameRate   = c.frameRate.rawValue
        ves.codec       = c.codec.rawValue
        ves.encoder     = c.encoder.rawValue
        ves.pixelFormat = c.pixelFormat.rawValue
        ves.muxer       = c.muxer.rawValue
        out.video = ves
        // Expert settings (always present in the outgoing proto so the client dialog shows current values).
        out.numberAlignedNeighborFrames = Int32(c.numberAlignedNeighborFrames)
        out.numberStaticNeighborFrames = Int32(c.numberStaticNeighborFrames)
        out.homographySmoothingEpsilon = c.homographySmoothingEpsilon
        out.keypointMemoryMultiplier = Int32(c.keypointMemoryMultiplier)
        out.outlierMemoryMultiplier = Int32(c.outlierMemoryMultiplier)
        out.mergeMemoryMultiplier = Int32(c.mergeMemoryMultiplier)
        out.useReferenceHorizonSmoothing = c.useReferenceHorizonSmoothing
        out.referenceHorizonSmoothingMaxDistance = Int32(c.referenceHorizonSmoothingMaxDistance)
        out.useReferenceHorizonBrightnessRefinement = c.useReferenceHorizonBrightnessRefinement
        out.referenceHorizonBrightnessRefinementSearchRadius = Int32(c.referenceHorizonBrightnessRefinementSearchRadius)
        out.referenceHorizonBrightnessRefinementHistBuckets = Int32(c.referenceHorizonBrightnessRefinementHistogramBuckets)
        out.referenceHorizonNeighborhoodSize = Int32(c.referenceHorizonNeighborhoodSize)
        out.horizonSpikeRemovalEnabled = c.horizonSpikeRemovalEnabled
        out.horizonSpikeMaxWidth = Int32(c.horizonSpikeMaxWidth)
        out.horizonSpikeMaxDeviationFraction = c.horizonSpikeMaxDeviationFraction
        out.horizonSpikeWindowHalf = Int32(c.horizonSpikeWindowHalf)
        out.horizonStripWidth = Int32(c.horizonStripWidth)
        out.useCannyForHorizonDetection = c.useCannyForHorizonDetection
        out.cannyMinThreshold = c.cannyMinThreshold
        out.cannyMaxThreshold = c.cannyMaxThreshold
        out.cannyUseL2Gradient = c.cannyUseL2Gradient
        out.horizonVerticalShiftAmount = Int32(c.horizonVerticalShiftAmount)
        out.allowEarthAlignment = c.allowEarthAlignment
        out.alignmentMaxKeypoints = Int32(c.alignmentMaxKeypoints)
        out.alignmentWriteDebugImages = c.alignmentWriteDebugImages
        out.alignmentGroundHorizonExtension = Int32(c.alignmentGroundHorizonExtension)
        out.alignmentSkyHorizonExtension = Int32(c.alignmentSkyHorizonExtension)
        out.alignmentBaseImageDilateSize = Int32(c.alignmentBaseImageDilateSize)
        out.alignmentBaseImageThresholdValue = Int32(c.alignmentBaseImageThresholdValue)
        return out
    }

    /// Apply only the *present* expert-setting fields from a proto Config onto a StarCore Config,
    /// so an unset field keeps StarCore's (non-zero) default rather than being clobbered by a proto zero.
    static func applyExpertConfig(_ c: inout Config, from p: Star_V1_Config) {
        if p.hasNumberAlignedNeighborFrames { c.numberAlignedNeighborFrames = Int(p.numberAlignedNeighborFrames) }
        if p.hasNumberStaticNeighborFrames { c.numberStaticNeighborFrames = Int(p.numberStaticNeighborFrames) }
        if p.hasHomographySmoothingEpsilon { c.homographySmoothingEpsilon = p.homographySmoothingEpsilon }
        if p.hasKeypointMemoryMultiplier { c.keypointMemoryMultiplier = Int(p.keypointMemoryMultiplier) }
        if p.hasOutlierMemoryMultiplier { c.outlierMemoryMultiplier = Int(p.outlierMemoryMultiplier) }
        if p.hasMergeMemoryMultiplier { c.mergeMemoryMultiplier = Int(p.mergeMemoryMultiplier) }
        if p.hasUseReferenceHorizonSmoothing { c.useReferenceHorizonSmoothing = p.useReferenceHorizonSmoothing }
        if p.hasReferenceHorizonSmoothingMaxDistance { c.referenceHorizonSmoothingMaxDistance = Int(p.referenceHorizonSmoothingMaxDistance) }
        if p.hasUseReferenceHorizonBrightnessRefinement { c.useReferenceHorizonBrightnessRefinement = p.useReferenceHorizonBrightnessRefinement }
        if p.hasReferenceHorizonBrightnessRefinementSearchRadius { c.referenceHorizonBrightnessRefinementSearchRadius = Int(p.referenceHorizonBrightnessRefinementSearchRadius) }
        if p.hasReferenceHorizonBrightnessRefinementHistBuckets { c.referenceHorizonBrightnessRefinementHistogramBuckets = Int(p.referenceHorizonBrightnessRefinementHistBuckets) }
        if p.hasReferenceHorizonNeighborhoodSize { c.referenceHorizonNeighborhoodSize = Int(p.referenceHorizonNeighborhoodSize) }
        if p.hasHorizonSpikeRemovalEnabled { c.horizonSpikeRemovalEnabled = p.horizonSpikeRemovalEnabled }
        if p.hasHorizonSpikeMaxWidth { c.horizonSpikeMaxWidth = Int(p.horizonSpikeMaxWidth) }
        if p.hasHorizonSpikeMaxDeviationFraction { c.horizonSpikeMaxDeviationFraction = p.horizonSpikeMaxDeviationFraction }
        if p.hasHorizonSpikeWindowHalf { c.horizonSpikeWindowHalf = Int(p.horizonSpikeWindowHalf) }
        if p.hasHorizonStripWidth { c.horizonStripWidth = Int(p.horizonStripWidth) }
        if p.hasUseCannyForHorizonDetection { c.useCannyForHorizonDetection = p.useCannyForHorizonDetection }
        if p.hasCannyMinThreshold { c.cannyMinThreshold = p.cannyMinThreshold }
        if p.hasCannyMaxThreshold { c.cannyMaxThreshold = p.cannyMaxThreshold }
        if p.hasCannyUseL2Gradient { c.cannyUseL2Gradient = p.cannyUseL2Gradient }
        if p.hasHorizonVerticalShiftAmount { c.horizonVerticalShiftAmount = Int(p.horizonVerticalShiftAmount) }
        if p.hasAllowEarthAlignment { c.allowEarthAlignment = p.allowEarthAlignment }
        if p.hasAlignmentMaxKeypoints { c.alignmentMaxKeypoints = Int(p.alignmentMaxKeypoints) }
        if p.hasAlignmentWriteDebugImages { c.alignmentWriteDebugImages = p.alignmentWriteDebugImages }
        if p.hasAlignmentGroundHorizonExtension { c.alignmentGroundHorizonExtension = Int(p.alignmentGroundHorizonExtension) }
        if p.hasAlignmentSkyHorizonExtension { c.alignmentSkyHorizonExtension = Int(p.alignmentSkyHorizonExtension) }
        if p.hasAlignmentBaseImageDilateSize { c.alignmentBaseImageDilateSize = Int(p.alignmentBaseImageDilateSize) }
        if p.hasAlignmentBaseImageThresholdValue { c.alignmentBaseImageThresholdValue = Int(p.alignmentBaseImageThresholdValue) }
    }

    // Build a VideoInfo from Swift Config's video fields (for use in Export.Video fallback).
    static func videoInfoFromConfig(_ c: Config) -> VideoInfo {
        VideoInfo(
            frameRate: c.frameRate,
            codec: c.codec,
            encoder: c.encoder,
            pixelFormat: c.pixelFormat,
            muxer: c.muxer,
            hasAudio: c.hasAudio
        )
    }

    // MARK: - VideoEncodeSettings / VideoInfo

    static func videoEncodeSettings(_ vi: VideoInfo) -> Star_V1_VideoEncodeSettings {
        var out = Star_V1_VideoEncodeSettings()
        out.codec        = vi.codec.rawValue
        out.pixelFormat  = vi.pixelFormat.rawValue
        out.muxer        = vi.muxer.rawValue
        out.frameRate    = vi.frameRate.rawValue
        out.encoder      = vi.encoder?.rawValue ?? ""
        return out
    }

    static func videoInfo(_ vi: VideoInfo) -> Star_V1_VideoInfo {
        var out = Star_V1_VideoInfo()
        out.settings   = videoEncodeSettings(vi)
        out.hasAudio_p = vi.hasAudio
        return out
    }

    // Returns nil when the VideoEncodeSettings carries no codec (i.e. the client omitted it).
    static func videoInfo(from proto: Star_V1_VideoEncodeSettings, hasAudio: Bool) -> VideoInfo? {
        guard !proto.codec.isEmpty,
              let codec  = FFmpegCodec(rawValue: proto.codec),
              let pixFmt = FFmpegPixelFormat(rawValue: proto.pixelFormat),
              let muxer  = FFmpegMuxer(rawValue: proto.muxer)
        else { return nil }
        let frameRate = FrameRate(rawValue: proto.frameRate)
        let encoder: FFmpegEncoder? = proto.encoder.isEmpty ? nil : FFmpegEncoder(rawValue: proto.encoder)
        return VideoInfo(
            frameRate: frameRate,
            codec: codec,
            encoder: encoder ?? codec.encoder(for: pixFmt),
            pixelFormat: pixFmt,
            muxer: muxer,
            hasAudio: hasAudio
        )
    }

    // MARK: - SessionInfo

    static func sessionInfo(session: Session, config: Config, imageInfo: ImageInfo,
                            frameCount: Int, videoInfo vi: VideoInfo? = nil) -> Star_V1_SessionInfo {
        var info = Star_V1_SessionInfo()
        info.sessionID = session.sessionID
        info.frameCount = Int32(frameCount)
        info.imageWidth = Int32(imageInfo.imageWidth)
        info.imageHeight = Int32(imageInfo.imageHeight)
        info.componentsPerPixel = Int32(imageInfo.componentsPerPixel)
        info.config = protoConfig(config)
        info.scratchSessionDir = session.scratchSessionDir
        if let vi { info.sourceVideoInfo = videoInfo(vi) }
        return info
    }

    // MARK: - FrameInfo

    static func frameInfo(frame: FrameAirplaneRemover, outlierGroups: OutlierGroups?) async -> Star_V1_FrameInfo {
        var fi = Star_V1_FrameInfo()
        fi.frameIndex = Int32(frame.frameIndex)
        fi.state = frameProcessingState(await frame.processingState())
        fi.cleanMethod = protoCleanMethod(await frame.cleanMethod)

        if let groups = outlierGroups {
            var pos = 0, neg = 0, und = 0
            for group in await groups.members.values {
                let rr = await group.shouldRemove()
                switch rr {
                case .some(.userSelected(true)):
                    pos += 1
                case .some(.fromClassifier(let s)) where s > 0:
                    pos += 1
                case .some(.userSelected(false)):
                    neg += 1
                case .some(.fromClassifier(let s)) where s <= 0:
                    neg += 1
                default:
                    und += 1
                }
            }
            fi.numPositiveOutliers  = Int32(pos)
            fi.numNegativeOutliers  = Int32(neg)
            fi.numUndecidedOutliers = Int32(und)
            fi.numTrashOutliers     = Int32(await groups.getTrash().count)
        }
        return fi
    }

    /// Map proto ReprocessingType → StarCore FrameReprocessingType.
    static func reprocessingType(_ t: Star_V1_ReprocessingType) -> FrameReprocessingType {
        switch t {
        case .reprocessEverything:  return .everything
        case .reprocessAlignment:   return .alignment
        case .reprocessOutliers:    return .outliers
        case .reprocessHorizons:    return .horizons
        case .reprocessAllHorizons: return .allHorizons
        default:                    return .none
        }
    }

    /// Map StarCore HorizonThumbnailOverlay.Kind → proto HorizonOverlayKind.
    static func horizonOverlayKind(_ k: HorizonThumbnailOverlay.Kind) -> Star_V1_HorizonOverlayKind {
        switch k {
        case .initial:   return .initial
        case .merged:    return .merged
        case .reference: return .reference
        }
    }
}
