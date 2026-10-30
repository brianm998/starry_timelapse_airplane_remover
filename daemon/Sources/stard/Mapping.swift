import Foundation
import StarCore
import StarCppBridge
import StarDaemonMessages

// Bidirectional type mapping between StarCore types and proto types.
enum Mapping {
    /// What `max_mat_memory_fraction` is clamped to (the macOS settings row's own limits).
    static let pixelThresholdRange: ClosedRange<Double> = 0.001...10

    static let memoryBudgetFractionRange: ClosedRange<Double> = 0.1 ... 0.95


    // MARK: - FrameViewMode

    static func frameViewMode(from proto: Star_V1_FrameViewMode) -> StarCore.FrameViewMode {
        switch proto {
        case .viewOriginal:    return .original
        // The final processed image -- what macOS shows -- which `ImageAccessor.linkFinal` points at
        // the output of whichever clean method the frame used.  `.autoProcessed` is only written
        // by automatic frames, so selective frames showed a debug image (the subtraction) instead.
        case .viewProcessed:   return .final
        case .viewSubtraction: return .subtraction
        case .viewValidation:  return .validation
        case .viewHorizon:               return .horizon
        case .viewMergedHorizon:         return .mergedHorizon
        case .viewUserHorizon:           return .userHorizon
        case .viewConsensusHorizon:      return .consensusHorizon
        case .viewStarAligned:           return .starAligned
        case .viewFailedStarAligned:     return .failedStarAligned
        case .viewEarthAligned:          return .earthAligned
        case .viewFailedEarthAligned:    return .failedEarthAligned
        case .viewBlobs:                 return .blobs
        case .viewRemoveMask:            return .removeMask
        case .viewAutoProcessed:         return .autoProcessed
        case .viewAutoSelectiveProcessed: return .autoSelectiveProcessed
        case .viewSelectiveProcessed:    return .selectiveProcessed
        default:               return .original
        }
    }

    /// The view mode a client can ask for that `type` is: every image the pipeline keeps has one.
    static func protoFrameViewMode(_ type: StarCore.FrameViewMode) -> Star_V1_FrameViewMode? {
        switch type {
        case .original:               return .viewOriginal
        case .final:                  return .viewProcessed
        case .subtraction:            return .viewSubtraction
        case .validation:             return .viewValidation
        case .horizon:                return .viewHorizon
        case .mergedHorizon:          return .viewMergedHorizon
        case .userHorizon:            return .viewUserHorizon
        case .consensusHorizon:       return .viewConsensusHorizon
        case .starAligned:            return .viewStarAligned
        case .failedStarAligned:      return .viewFailedStarAligned
        case .earthAligned:           return .viewEarthAligned
        case .failedEarthAligned:     return .viewFailedEarthAligned
        case .blobs:                  return .viewBlobs
        case .removeMask:             return .viewRemoveMask
        case .autoProcessed:          return .viewAutoProcessed
        case .autoSelectiveProcessed: return .viewAutoSelectiveProcessed
        case .selectiveProcessed:     return .viewSelectiveProcessed
        }
    }

    /// The images [frame] has on disk now that a client can ask for, and the aligned ones it can build from its homographies (the
    /// default mode never writes them, so a frame that was processed has them only this way, as the macOS gui offers them: see
    /// `FrameViewModel.hasImage`); the original is always among them.
    static func availableModes(of frame: FrameAirplaneRemover) async -> [Star_V1_FrameViewMode] {
        var modes: [Star_V1_FrameViewMode] = []
        for type in StarCore.FrameViewMode.allCases {
            guard let mode = protoFrameViewMode(type) else { continue }
            var offered = type == .original
                || frame.imageAccessor.imageExists(frameIndex: frame.frameIndex, ofType: type, atSize: .original)
            if !offered, type.isRecomputableCache { offered = await frame.canProduceAlignedImage(of: type) }
            if offered { modes.append(mode) }
        }
        return modes
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

    // MARK: - Video frame format

    /// The format an `OpenVideoRequest` asks for; an unset quality is the default one.
    static func frameDecodeFormat(from request: Star_V1_OpenVideoRequest) -> FrameDecodeFormat {
        let kind: FrameDecodeFormat.Kind
        switch request.frameFormat {
        case .tiff8: kind = .tiff8
        case .jpeg:  kind = .jpeg
        default:     kind = .tiff16
        }
        let quality = request.jpegQuality == 0 ? FrameDecodeFormat.defaultJPEGQuality : Int(request.jpegQuality)
        let compression: FrameDecodeFormat.TIFFCompression = request.tiffCompression == .none ? .none : .packBits
        return FrameDecodeFormat(kind: kind, jpegQuality: quality, tiffCompression: compression)
    }

    /// The worker limits an `OpenVideoRequest` asks for; 0 (unset) is StarCore's default.
    static func extractionSettings(from request: Star_V1_OpenVideoRequest) -> FrameExtractionSettings {
        FrameExtractionSettings(jumpWorkers: Int(request.extractionSettings.maxJumpWorkers),
                                longGOPJumpWorkers: Int(request.extractionSettings.maxLongGopJumpWorkers))
    }

    /// Frame ranges as the wire carries them: coalesced, end exclusive.
    static func frameRanges(_ set: IndexSet) -> [Star_V1_FrameRange] {
        set.rangeView.map {
            var range = Star_V1_FrameRange()
            range.start = Int32($0.lowerBound)
            range.end = Int32($0.upperBound)
            return range
        }
    }

    static func indexSet(_ ranges: [Star_V1_FrameRange]) -> IndexSet {
        var set = IndexSet()
        for range in ranges where range.end > range.start { set.insert(integersIn: Int(range.start)..<Int(range.end)) }
        return set
    }

    /// Where the extraction of a video's frames has got to.  `snapshot` lists every available range; an update leaves them out (a
    /// FramesAvailable follows).
    static func frameExtraction(of source: FrameSource, snapshot: Bool) -> Star_V1_FrameExtraction {
        let progress = source.progress
        var out = Star_V1_FrameExtraction()
        out.extracted = Int32(progress.extracted)
        out.total = Int32(progress.total)
        out.framesPerSecond = progress.framesPerSecond ?? 0
        out.complete = progress.isComplete
        out.seekable = progress.accessKind == .seekable
        out.active = progress.accessKind != nil
        if let error = progress.error { out.error = error }
        if let eta = progress.estimatedSecondsRemaining {
            out.etaSeconds = eta
            out.etaKnown = true
        }
        if snapshot { out.available = frameRanges(source.availableFrames) }
        return out
    }

    /// The answer to `Session.ProbeVideo`.
    static func probeVideoResponse(for videoPath: String) -> Star_V1_ProbeVideoResponse {
        var response = Star_V1_ProbeVideoResponse()
        guard let probe = VideoProbe.probe(videoAt: videoPath) else { return response }
        response.known = true
        response.width = Int32(probe.width)
        response.height = Int32(probe.height)
        response.frameCount = Int32(probe.frameCount ?? 0)
        response.frameCountExact = probe.frameCountIsExact
        if let seekable = probe.seekable {
            response.seekable = seekable
            response.seekableKnown = true
        } else {
            // The packets could not be examined: the codec's name is the best there is, but it is a guess, so it is not "known".
            response.seekable = probe.extractInBackgroundByDefault
        }
        response.tiff16RawBytesPerPixel = FrameDecodeFormat(kind: .tiff16, tiffCompression: .none).estimatedBytesPerPixel
        response.tiff8RawBytesPerPixel = FrameDecodeFormat(kind: .tiff8, tiffCompression: .none).estimatedBytesPerPixel
        response.tiff16BytesPerPixel = FrameDecodeFormat.tiff16.estimatedBytesPerPixel
        response.tiff8BytesPerPixel = FrameDecodeFormat.tiff8.estimatedBytesPerPixel
        response.jpegBytesPerPixel = FrameDecodeFormat.jpegQualityRange.map {
            FrameDecodeFormat(kind: .jpeg, jpegQuality: $0).estimatedBytesPerPixel
        }
        return response
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

    // MARK: - Line

    static func protoLine(_ line: Line) -> Star_V1_Line {
        var out = Star_V1_Line()
        out.theta = line.theta
        out.rho = line.rho
        out.votes = Int32(clamping: line.votes)
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

    static func protoNeighborHomography(_ w: AlignmentWarpInfoCodable, includeHomography: Bool, suspect: Bool = false) -> Star_V1_NeighborHomography {
        var out = Star_V1_NeighborHomography()
        out.frameIndex = Int32(w.frameIndex)
        out.deviation = w.deviation
        out.state = protoAlignmentState(w.alignmentState)
        out.suspect = suspect
        if includeHomography, let h = w.homography { out.homography = h }
        return out
    }

    static func protoHomographyResults(_ h: HomographyResultsCodable, includeHomography: Bool) -> Star_V1_HomographyResults {
        var out = Star_V1_HomographyResults()
        out.frameIndex = Int32(h.frameIndex)
        out.compositeDeviation = h.compositeDeviation
        out.alignmentLooksOk = h.alignmentLooksOk
        // Worked out here, on the whole set with its matrices, whatever the client asked to be sent: the heuristics fit a line through all of
        // a frame's neighbors, so a client given only the deviations could not reproduce them.
        let suspect = Set(h.partitionWarps().suspect.map(\.frameIndex))
        out.neighbors = h.neighborHomography.map {
            protoNeighborHomography($0, includeHomography: includeHomography, suspect: suspect.contains($0.frameIndex))
        }
        return out
    }

    // MARK: - Config round-trip

    static func protoConfig(_ c: Config) -> Star_V1_Config {
        var out = Star_V1_Config()
        out.outputPath = c.outputPath
        out.tempOutputPath = c.tempOutputPath
        out.cleanMethod = protoCleanMethod(c.cleanMethod)
        // The per-frame settings are read-only here: they change through Frame.SetCleanMethod and Frame.SetNeighborOverride (which do what
        // each change calls for), so a client that sends back a config it read earlier cannot undo one.
        out.pixelReplacementOverrides = Dictionary(uniqueKeysWithValues: c.pixelReplacementOverrides.map { (Int32($0.key), protoCleanMethod($0.value)) })
        out.staticNeighborFrameOverrides = Dictionary(uniqueKeysWithValues: c.staticNeighborFrameOverrides.map { (Int32($0.key), Int32($0.value)) })
        out.alignedNeighborFrameOverrides = Dictionary(uniqueKeysWithValues: c.alignedNeighborFrameOverrides.map { (Int32($0.key), Int32($0.value)) })
        out.detectionType = protoDetectionType(c.detectionType)
        out.horizonDetectionEnabled = c.horizonDetectionEnabled
        out.tripodHeadWasMoving = c.tripodHeadWasMoving
        out.numberOfFramesToProcessConcurrently = Int32(c.numberOfFramesToProcessConcurrently)
        if c.ignoreLowerPixels != 0 { out.ignoreLowerPixels = Int32(c.ignoreLowerPixels) }
        out.writeOutlierGroupFiles = c.writeOutlierGroupFiles
        out.writeFramePreviewFiles = c.writeFramePreviewFiles
        out.starVersion = c.starVersion
        out.imageSequenceDirname = c.imageSequenceDirname
        out.reprocessOnSettingsChange = c.reprocessOnSettingsChange
        out.maxMatMemoryFraction = c.maxMatMemoryFraction
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
        out.useCannyForHorizonDetection = c.useCannyForHorizonDetection
        out.cannyMinThreshold = c.cannyMinThreshold
        out.cannyMaxThreshold = c.cannyMaxThreshold
        out.cannyUseL2Gradient = c.cannyUseL2Gradient
        out.allowEarthAlignment = c.allowEarthAlignment
        out.alignmentMaxKeypoints = Int32(c.alignmentMaxKeypoints)
        out.alignmentWriteDebugImages = c.alignmentWriteDebugImages
        out.alignmentGroundHorizonExtension = Int32(c.alignmentGroundHorizonExtension)
        out.alignmentSkyHorizonExtension = Int32(c.alignmentSkyHorizonExtension)
        out.alignmentBaseImageDilateSize = Int32(c.alignmentBaseImageDilateSize)
        out.alignmentBaseImageThresholdValue = Int32(c.alignmentBaseImageThresholdValue)
        out.horizonMemoryMultiplier = Int32(c.horizonMemoryMultiplier)
        out.horizonReservationFloorMb = Int32(c.horizonReservationFloorMB)
        out.alignmentKeypointDetectionDivisor = c.alignmentKeypointDetectionDivisor
        out.maxConcurrentKeypointOps = Int32(c.maxConcurrentKeypointOps)
        out.mergeStreamingThresholdMb = Int32(c.mergeStreamingThresholdMB)
        out.useGpuAcceleration = c.useGPUForMerge
        out.cloudAwareMerge = c.cloudAwareMerge
        out.pixelThreshold = c.pixelThreshold
        // Read-only: not a Config field, so there is nothing for applyExpertConfig to
        // apply it back onto — computed fresh on every outgoing Config so a client
        // always shows the daemon's own machine's hardware, not a stale answer from
        // whenever the daemon happened to start.
        out.gpuHardwareAvailable = Config.isGPUHardwareAvailable
        if let device = GPUCapability.deviceName() { out.gpuDeviceName = device }
        out.resourceProfile = c.resourceProfile.rawValue
        out.useGpuForSift = c.useGPUForSIFT
        out.useGpuForAkaze = c.useGPUForAKAZE
        // Not an expert setting — recorded state.  Always sent, so a client that re-opens a
        // session can see it left a hand-painted horizon selection unfinished.
        out.startupHorizonFrameIndices = c.startupHorizonFrameIndices.map { Int32($0) }
        out.startupHorizonFramePosition = Int32(c.startupHorizonFramePosition)
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
        if p.hasUseCannyForHorizonDetection { c.useCannyForHorizonDetection = p.useCannyForHorizonDetection }
        if p.hasCannyMinThreshold { c.cannyMinThreshold = p.cannyMinThreshold }
        if p.hasCannyMaxThreshold { c.cannyMaxThreshold = p.cannyMaxThreshold }
        if p.hasCannyUseL2Gradient { c.cannyUseL2Gradient = p.cannyUseL2Gradient }
        if p.hasAllowEarthAlignment { c.allowEarthAlignment = p.allowEarthAlignment }
        if p.hasAlignmentMaxKeypoints { c.alignmentMaxKeypoints = Int(p.alignmentMaxKeypoints) }
        if p.hasAlignmentWriteDebugImages { c.alignmentWriteDebugImages = p.alignmentWriteDebugImages }
        if p.hasAlignmentGroundHorizonExtension { c.alignmentGroundHorizonExtension = Int(p.alignmentGroundHorizonExtension) }
        if p.hasAlignmentSkyHorizonExtension { c.alignmentSkyHorizonExtension = Int(p.alignmentSkyHorizonExtension) }
        if p.hasAlignmentBaseImageDilateSize { c.alignmentBaseImageDilateSize = Int(p.alignmentBaseImageDilateSize) }
        if p.hasAlignmentBaseImageThresholdValue { c.alignmentBaseImageThresholdValue = Int(p.alignmentBaseImageThresholdValue) }
        if p.hasHorizonMemoryMultiplier { c.horizonMemoryMultiplier = Int(p.horizonMemoryMultiplier) }
        // A divisor of 0 is not a request, it is a client with no min on its text box —
        // the Kotlin DoubleField has none. Config clamps anything <= 1 to full resolution
        // rather than honouring it, so an out-of-range value is harmless here, but do not
        // let it through as if it meant something.
        if p.hasAlignmentKeypointDetectionDivisor {
            c.alignmentKeypointDetectionDivisor = p.alignmentKeypointDetectionDivisor
            // A client that sent a divisor has chosen one; `set(imageInfo:)` must not
            // then choose a different one over the top of it.  A client that sent none
            // leaves the field absent and gets the automatic default.
            c.keypointDivisorWasChosen = true
        }
        // These three all have a meaningful 0, which is why they are `optional` in the
        // proto and read through `has…` here rather than relying on a proto3 zero:
        //   horizonReservationFloorMB  0 = no floor, use the multiplier alone
        //   maxConcurrentKeypointOps   0 = no explicit cap, the budget decides
        //   mergeStreamingThresholdMB  0 = never stream, always keep every source resident
        // Under implicit presence each of those requests would be indistinguishable from
        // an unset field, and StarCore's default (900, 0, 8192) would win instead — which
        // for the threshold means quietly streaming when the client asked not to.
        if p.hasHorizonReservationFloorMb { c.horizonReservationFloorMB = Int(p.horizonReservationFloorMb) }
        if p.hasMaxConcurrentKeypointOps { c.maxConcurrentKeypointOps = Int(p.maxConcurrentKeypointOps) }
        if p.hasMergeStreamingThresholdMb { c.mergeStreamingThresholdMB = Int(p.mergeStreamingThresholdMb) }
        if p.hasReprocessOnSettingsChange { c.reprocessOnSettingsChange = p.reprocessOnSettingsChange }
        // A budget of 0 would admit nothing and one past 1 more than the machine has; a client with no min on its text box can send either.
        if p.hasMaxMatMemoryFraction, p.maxMatMemoryFraction.isFinite {
            c.maxMatMemoryFraction = min(max(p.maxMatMemoryFraction, Mapping.memoryBudgetFractionRange.lowerBound), Mapping.memoryBudgetFractionRange.upperBound)
        }
        if p.hasUseGpuAcceleration { c.useGPUForMerge = p.useGpuAcceleration }
        if p.hasCloudAwareMerge { c.cloudAwareMerge = p.cloudAwareMerge }
        // The range the gui's field accepts: a threshold of 0 throws every pixel out, and a text box with no limits can send it.
        if p.hasPixelThreshold, p.pixelThreshold.isFinite {
            c.pixelThreshold = min(max(p.pixelThreshold, Mapping.pixelThresholdRange.lowerBound), Mapping.pixelThresholdRange.upperBound)
        }
        // Unknown names are ignored rather than rejected: a newer client may know profiles
        // this daemon does not, and keeping the config's own is the safe answer.
        if p.hasResourceProfile, let profile = ResourceProfile(rawValue: p.resourceProfile) {
            c.resourceProfile = profile
        }
        if p.hasUseGpuForSift { c.useGPUForSIFT = p.useGpuForSift }
        if p.hasUseGpuForAkaze { c.useGPUForAKAZE = p.useGpuForAkaze }
        // gpu_hardware_available is read-only (see protoConfig) and deliberately not
        // applied here — it describes hardware, not a setting a client can choose.
        // The record of an unfinished hand-painted horizon selection, applied as a pair and
        // gated on the position rather than on the list.  A repeated field cannot be
        // `optional`, so an empty list reads the same as an absent one — without this gate
        // a client that knows nothing about these would clear the record on every config
        // update it sent, which is exactly the loss they exist to prevent.
        if p.hasStartupHorizonFramePosition {
            c.startupHorizonFrameIndices = p.startupHorizonFrameIndices.map { Int($0) }
            c.startupHorizonFramePosition = Int(p.startupHorizonFramePosition)
        }
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
        out.outputHeight = Int32(vi.resolution.height)
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
            hasAudio: hasAudio,
            resolution: OutputResolution(height: Int(proto.outputHeight))
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
        info.configJsonPath = session.configJsonPath
        if let vi { info.sourceVideoInfo = videoInfo(vi) }
        let source = session.extractionSource
        if let source, !source.progress.isComplete { info.extraction = frameExtraction(of: source, snapshot: true) }
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
            fi.outliersLoaded       = true
        }
        fi.notExtracted = !frame.imageAccessor.imageSequence.source.isAvailable(frame.frameIndex)
        fi.availableModes = await availableModes(of: frame)
        if let path = frame.imageAccessor.nameForImage(frameIndex: frame.frameIndex, ofType: .original, atSize: .original) {
            fi.filename = (path as NSString).lastPathComponent
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
        case .consensus: return .consensus
        }
    }
}
