package com.star.desktop.engine

import com.google.protobuf.MessageLite
import com.google.protobuf.Parser
import com.star.proto.AlignmentInfo
import com.star.proto.AlignmentSequence
import com.star.proto.ApplyDecisionTreeAllFramesRequest
import com.star.proto.ApplyDecisionTreeAllFramesResponse
import com.star.proto.ApplyDecisionTreeRequest
import com.star.proto.ApplyDecisionTreeResponse
import com.star.proto.ApplyOutlierAreaToolRequest
import com.star.proto.ApplyOutlierAreaToolResponse
import com.star.proto.BlobStepsResponse
import com.star.proto.CancelResponse
import com.star.proto.CleanMethod
import com.star.proto.ClearReferenceHorizonRequest
import com.star.proto.ClearReferenceHorizonResponse
import com.star.proto.CloseSessionRequest
import com.star.proto.CloseSessionResponse
import com.star.proto.ComputeHorizonInBandRequest
import com.star.proto.ComputeHorizonInBandResponse
import com.star.proto.Config
import com.star.proto.ConfigChangePreview
import com.star.proto.DeferRefinementResponse
import com.star.proto.DetectionType
import com.star.proto.ExportVideoRequest
import com.star.proto.FrameInfo
import com.star.proto.FrameRef
import com.star.proto.FrameViewMode
import com.star.proto.GetAlignmentRequest
import com.star.proto.GetAlignmentSequenceRequest
import com.star.proto.GetBestHorizonRequest
import com.star.proto.GetBestHorizonResponse
import com.star.proto.GetBlobStepsRequest
import com.star.proto.FrameFormat
import com.star.proto.GetDefaultVideoPathRequest
import com.star.proto.GetDefaultVideoPathResponse
import com.star.proto.GetFramePreviewRequest
import com.star.proto.GetHorizonOverlayRequest
import com.star.proto.GetHorizonOverlayResponse
import com.star.proto.GetHoughLineFinderArgsRequest
import com.star.proto.GetLineCandidatesRequest
import com.star.proto.GetOutlierFeaturesRequest
import com.star.proto.GetReferenceHorizonRequest
import com.star.proto.GetReferenceHorizonResponse
import com.star.proto.GetVideoCapabilitiesRequest
import com.star.proto.HelloRequest
import com.star.proto.HelloResponse
import com.star.proto.HorizonReferenceUpdatedRequest
import com.star.proto.HorizonReferenceUpdatedResponse
import com.star.proto.HoughLineFinderArgs
import com.star.proto.ImageRef
import com.star.proto.KeypointDivisorAdvice
import com.star.proto.LineCandidate
import com.star.proto.LineCandidatesResponse
import com.star.proto.ListSessionsRequest
import com.star.proto.ListSessionsResponse
import com.star.proto.MultiFrameDecisionsResponse
import com.star.proto.NeighborKind
import com.star.proto.OpenConfigRequest
import com.star.proto.OpenProgress
import com.star.proto.OpenSequenceRequest
import com.star.proto.OpenVideoRequest
import com.star.proto.OutlierAreaTool
import com.star.proto.OutlierDecision
import com.star.proto.OutlierFeaturesResponse
import com.star.proto.OutlierGroupList
import com.star.proto.Point
import com.star.proto.PreviewSize
import com.star.proto.ProbeVideoRequest
import com.star.proto.ProbeVideoResponse
import com.star.proto.ProgressEvent
import com.star.proto.RefinementStatusResponse
import com.star.proto.ReprocessFramesRequest
import com.star.proto.ReprocessFramesResponse
import com.star.proto.ReprocessHorizonsRequest
import com.star.proto.ReprocessingType
import com.star.proto.RunRefinementResponse
import com.star.proto.SequenceProgress
import com.star.proto.SessionInfo
import com.star.proto.SessionRef
import com.star.proto.SetAllOutliersRequest
import com.star.proto.SetCustomBlobStepsRequest
import com.star.proto.SetFrameCleanMethodRequest
import com.star.proto.SetHoughLineFinderArgRequest
import com.star.proto.SetLineRequest
import com.star.proto.SetLineResponse
import com.star.proto.SetLogLevelRequest
import com.star.proto.SetLogLevelResponse
import com.star.proto.SetNeighborOverrideRequest
import com.star.proto.SetNeighborOverrideResponse
import com.star.proto.SetOutlierDecisionsInAreaRequest
import com.star.proto.SetOutlierDecisionsOverlappingRequest
import com.star.proto.SetOutlierDecisionsRequest
import com.star.proto.SetOutlierDecisionsResponse
import com.star.proto.SetReferenceHorizonRequest
import com.star.proto.SetReferenceHorizonResponse
import com.star.proto.SetTunedHorizonParametersRequest
import com.star.proto.ShutdownRequest
import com.star.proto.ShutdownResponse
import com.star.proto.StartProcessingRequest
import com.star.proto.StartProcessingResponse
import com.star.proto.TunedHorizonParametersResponse
import com.star.proto.UpdateConfigRequest
import com.star.proto.VideoCapabilities
import com.star.proto.VideoEncodeSettings
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/**
 * Typed RPC client over [StdioConnection] — one suspend fun / Flow per the 22 daemon methods
 * verified in `daemon/Sources/stard/Dispatcher.swift`. Repositories call these; UI never builds
 * envelopes directly.
 *
 * Method shapes (verified against the daemon, not the design doc):
 *  - `Session.OpenSequence` / `Session.OpenConfig` are **unary** (return `SessionInfo`); only
 *    `Session.OpenVideo` streams `OpenProgress`.
 *  - `Processing.StreamProgress` is a **separate long-lived stream**, decoupled from `Processing.Start`
 *    (which is fire-and-forget). Subscribe to progress *before* calling Start.
 */
class StarClient(private val conn: StdioConnection) {

    private suspend fun <Resp : MessageLite> call(
        method: String,
        req: MessageLite,
        parser: Parser<Resp>,
    ): Resp {
        val env = conn.sendUnary(method, req.toByteArray())
        return parser.parseFrom(env.payload)
    }

    private fun <Item : MessageLite> serverStream(
        method: String,
        req: MessageLite,
        parser: Parser<Item>,
    ): Flow<Item> = conn.sendStream(method, req.toByteArray()).map { parser.parseFrom(it.payload) }

    // ---- Daemon ----

    /**
     * [locale] is the BCP-47 tag this client's UI is showing. The daemon adopts it for every
     * user-visible string it originates (warnings, error text), so the engine cannot end up
     * answering in a different language than the window it is answering into.
     */
    suspend fun hello(clientVersion: String, locale: String): HelloResponse =
        call("Daemon.Hello",
             HelloRequest.newBuilder().setClientVersion(clientVersion).setLocale(locale).build(),
             HelloResponse.parser())

    /**
     * Change how much the engine logs while it runs. An empty [level] or [fileLevel], or a null [fileEnabled], keeps what it was. The answer says
     * what is in force and where the engine's own log file is, if it is writing one.
     */
    suspend fun setLogLevel(level: String = "", fileEnabled: Boolean? = null, fileLevel: String = ""): SetLogLevelResponse =
        call(
            "Daemon.SetLogLevel",
            SetLogLevelRequest.newBuilder().setLevel(level).setFileLevel(fileLevel).also { b -> fileEnabled?.let { b.setFileEnabled(it) } }.build(),
            SetLogLevelResponse.parser(),
        )

    // ---- Blob processing (the developer window) ----

    /** The steps of a detection type, with their parameters and what they do; the same in every session. */
    suspend fun getBlobSteps(detectionType: DetectionType): BlobStepsResponse =
        call("Blob.GetSteps", GetBlobStepsRequest.newBuilder().setDetectionType(detectionType).build(), BlobStepsResponse.parser())

    /** Change the custom detection type; the answer is its steps as they are now. */
    suspend fun setCustomBlobSteps(change: SetCustomBlobStepsRequest): BlobStepsResponse =
        call("Blob.SetCustomSteps", change, BlobStepsResponse.parser())

    suspend fun shutdown(): ShutdownResponse =
        call("Daemon.Shutdown", ShutdownRequest.getDefaultInstance(), ShutdownResponse.parser())

    // ---- Session ----

    fun openVideo(
        videoPath: String,
        initialConfig: Config = Config.getDefaultInstance(),
        frameFormat: FrameFormat = FrameFormat.FRAME_FORMAT_TIFF16,
        jpegQuality: Int = 0,
        tiffCompression: com.star.proto.TiffCompression = com.star.proto.TiffCompression.TIFF_COMPRESSION_PACKBITS,
        extractInBackground: Boolean = false,
        /** The most ffmpeg processes that extract ahead of the in-order one; 0 leaves it to the engine's default. */
        maxJumpWorkers: Int = 0,
        maxLongGopJumpWorkers: Int = 0,
    ): Flow<OpenProgress> =
        serverStream(
            "Session.OpenVideo",
            OpenVideoRequest.newBuilder().setVideoPath(videoPath).setInitialConfig(initialConfig)
                .setFrameFormat(frameFormat).setJpegQuality(jpegQuality)
                .setTiffCompression(tiffCompression).setExtractInBackground(extractInBackground)
                .setExtractionSettings(
                    com.star.proto.ExtractionSettings.newBuilder()
                        .setMaxJumpWorkers(maxJumpWorkers).setMaxLongGopJumpWorkers(maxLongGopJumpWorkers),
                ).build(),
            OpenProgress.parser(),
        )

    /** A video's size and length from its header, and what a frame of each format costs in disk; `known` is false if it cannot be read. */
    suspend fun probeVideo(videoPath: String): ProbeVideoResponse =
        call("Session.ProbeVideo", ProbeVideoRequest.newBuilder().setVideoPath(videoPath).build(), ProbeVideoResponse.parser())

    /** As [openSequence], but streams how the frames are coming, and cancelling the collector cancels the open (no session is left behind). */
    fun openSequenceStream(sequenceDir: String, initialConfig: Config = Config.getDefaultInstance()): Flow<OpenProgress> =
        serverStream(
            "Session.OpenSequenceStream",
            OpenSequenceRequest.newBuilder().setSequenceDir(sequenceDir).setInitialConfig(initialConfig).build(),
            OpenProgress.parser(),
        )

    /** As [openConfig], streamed and cancellable like [openSequenceStream]. */
    fun openConfigStream(configJsonPath: String): Flow<OpenProgress> =
        serverStream(
            "Session.OpenConfigStream",
            OpenConfigRequest.newBuilder().setConfigJsonPath(configJsonPath).build(),
            OpenProgress.parser(),
        )

    suspend fun openSequence(sequenceDir: String, initialConfig: Config = Config.getDefaultInstance()): SessionInfo =
        call(
            "Session.OpenSequence",
            OpenSequenceRequest.newBuilder().setSequenceDir(sequenceDir).setInitialConfig(initialConfig).build(),
            SessionInfo.parser(),
        )

    suspend fun openConfig(configJsonPath: String): SessionInfo =
        call("Session.OpenConfig", OpenConfigRequest.newBuilder().setConfigJsonPath(configJsonPath).build(), SessionInfo.parser())

    suspend fun closeSession(sessionId: String): CloseSessionResponse =
        call("Session.Close", CloseSessionRequest.newBuilder().setSessionId(sessionId).build(), CloseSessionResponse.parser())

    suspend fun listSessions(): ListSessionsResponse =
        call("Session.List", ListSessionsRequest.getDefaultInstance(), ListSessionsResponse.parser())

    // ---- Sequence (config) ----

    suspend fun getConfig(sessionId: String): Config =
        call("Sequence.GetConfig", SessionRef.newBuilder().setSessionId(sessionId).build(), Config.parser())

    suspend fun updateConfig(sessionId: String, config: Config): Config =
        call("Sequence.UpdateConfig", UpdateConfigRequest.newBuilder().setSessionId(sessionId).setConfig(config).build(), Config.parser())

    /**
     * What applying [config] would do to the work already on disk, without applying it: which cached stages it would invalidate, and whether
     * there is finished work for that to contradict (the settings sheet's "already processed frames have different settings").
     */
    suspend fun previewConfigChange(sessionId: String, config: Config): ConfigChangePreview =
        call("Sequence.PreviewConfigChange", UpdateConfigRequest.newBuilder().setSessionId(sessionId).setConfig(config).build(), ConfigChangePreview.parser())

    /** Whether full resolution keypoint detection suits the sequence on this machine, and what to suggest otherwise (macOS `keypointDivisorAdvice`). */
    suspend fun getKeypointAdvice(sessionId: String): KeypointDivisorAdvice =
        call("Sequence.GetKeypointAdvice", SessionRef.newBuilder().setSessionId(sessionId).build(), KeypointDivisorAdvice.parser())

    /** How far a previous run got on the sequence, read off what it left on disk now (macOS `SequenceProgressSurvey`). */
    suspend fun getProgressSurvey(sessionId: String): SequenceProgress =
        call("Sequence.GetProgressSurvey", SessionRef.newBuilder().setSessionId(sessionId).build(), SequenceProgress.parser())

    // ---- Frame ----

    suspend fun getFrame(sessionId: String, frameIndex: Int): FrameInfo =
        call("Frame.Get", frameRef(sessionId, frameIndex), FrameInfo.parser())

    /**
     * What the user is looking at, so a video that is still being extracted fetches [viewing] and the frames in [nearby] first, where its
     * format allows. Cheap to call at every move: the engine collapses a scrub that is still going.
     */
    suspend fun prioritizeFrames(sessionId: String, viewing: Int, nearby: List<IntRange>) {
        val request = com.star.proto.PrioritizeFramesRequest.newBuilder().setSessionId(sessionId).setViewing(viewing)
        for (r in nearby) request.addNearby(com.star.proto.FrameRange.newBuilder().setStart(r.first).setEnd(r.last + 1))
        call("Frame.Prioritize", request.build(), com.star.proto.PrioritizeFramesResponse.parser())
    }

    /** How long until a frame that is not extracted yet is, for the wait panel. */
    suspend fun getFrameEta(sessionId: String, frameIndex: Int): com.star.proto.FrameEtaResponse =
        call(
            "Frame.GetEta",
            com.star.proto.FrameEtaRequest.newBuilder().setSessionId(sessionId).setFrameIndex(frameIndex).build(),
            com.star.proto.FrameEtaResponse.parser(),
        )

    /** The frame's image for [viewMode] at [size]: the preview by default, the filmstrip's thumbnail, or an 8-bit copy of the full-size image. */
    suspend fun getFramePreview(
        sessionId: String, frameIndex: Int, viewMode: FrameViewMode, size: PreviewSize = PreviewSize.PREVIEW_SIZE_PREVIEW,
    ): ImageRef =
        call(
            "Frame.GetPreview",
            GetFramePreviewRequest.newBuilder().setSessionId(sessionId).setFrameIndex(frameIndex).setViewMode(viewMode).setSize(size).build(),
            ImageRef.parser(),
        )

    /** Give a frame its own neighbour count of [kind], or with a null [count] take its own away (`Frame.SetNeighborOverride`). */
    suspend fun setNeighborOverride(sessionId: String, frameIndex: Int, kind: NeighborKind, count: Int?): SetNeighborOverrideResponse =
        call(
            "Frame.SetNeighborOverride",
            SetNeighborOverrideRequest.newBuilder().setSessionId(sessionId).setFrameIndex(frameIndex).setKind(kind)
                .also { if (count != null) it.setCount(count) else it.setClear(true) }.build(),
            SetNeighborOverrideResponse.parser(),
        )

    suspend fun getOutlierLabelImage(sessionId: String, frameIndex: Int): ImageRef =
        call("Frame.GetOutlierLabelImage", frameRef(sessionId, frameIndex), ImageRef.parser())

    /** An 8-bit mask of the frame's trashed outlier groups (255 = trash), for drawing the trash. */
    suspend fun getOutlierTrashImage(sessionId: String, frameIndex: Int): ImageRef =
        call("Frame.GetOutlierTrashImage", frameRef(sessionId, frameIndex), ImageRef.parser())

    suspend fun setAllOutliers(
        sessionId: String, frameIndex: Int, shouldRemove: Boolean, undecidedOnly: Boolean, includingTrash: Boolean,
    ): SetOutlierDecisionsResponse =
        call(
            "Outlier.SetAll",
            SetAllOutliersRequest.newBuilder().setSessionId(sessionId).setFrameIndex(frameIndex).setShouldRemove(shouldRemove)
                .setUndecidedOnly(undecidedOnly).setIncludingTrash(includingTrash).build(),
            SetOutlierDecisionsResponse.parser(),
        )

    suspend fun setFrameCleanMethod(sessionId: String, frameIndex: Int, cleanMethod: CleanMethod): FrameInfo =
        call(
            "Frame.SetCleanMethod",
            SetFrameCleanMethodRequest.newBuilder().setSessionId(sessionId).setFrameIndex(frameIndex).setCleanMethod(cleanMethod).build(),
            FrameInfo.parser(),
        )

    // ---- Outlier ----

    suspend fun listOutliers(sessionId: String, frameIndex: Int): OutlierGroupList =
        call("Outlier.List", frameRef(sessionId, frameIndex), OutlierGroupList.parser())

    suspend fun setOutlierDecisions(
        sessionId: String,
        frameIndex: Int,
        decisions: List<OutlierDecision>,
        rerender: Boolean = false,
    ): SetOutlierDecisionsResponse =
        call(
            "Outlier.SetDecisions",
            SetOutlierDecisionsRequest.newBuilder()
                .setSessionId(sessionId).setFrameIndex(frameIndex).addAllDecisions(decisions).setRerender(rerender).build(),
            SetOutlierDecisionsResponse.parser(),
        )

    /** Every decision-tree feature, and the classifier's score, of the given groups of a frame (all its groups when [groupIds] is empty). */
    suspend fun getOutlierFeatures(sessionId: String, frameIndex: Int, groupIds: List<Int> = emptyList()): OutlierFeaturesResponse =
        call(
            "Outlier.GetFeatures",
            GetOutlierFeaturesRequest.newBuilder().setSessionId(sessionId).setFrameIndex(frameIndex).addAllGroupIds(groupIds).build(),
            OutlierFeaturesResponse.parser(),
        )

    /** The lines the Hough finder proposes for one group, best fit first (`Outlier.GetLineCandidates`). */
    suspend fun getLineCandidates(sessionId: String, frameIndex: Int, groupId: Int): LineCandidatesResponse =
        call(
            "Outlier.GetLineCandidates",
            GetLineCandidatesRequest.newBuilder().setSessionId(sessionId).setFrameIndex(frameIndex).setGroupId(groupId).build(),
            LineCandidatesResponse.parser(),
        )

    /** Make [candidate] the line of one group; the group as it is then comes back (`Outlier.SetLine`). */
    suspend fun setLine(sessionId: String, frameIndex: Int, groupId: Int, candidate: LineCandidate): SetLineResponse =
        call(
            "Outlier.SetLine",
            SetLineRequest.newBuilder().setSessionId(sessionId).setFrameIndex(frameIndex).setGroupId(groupId).setCandidate(candidate).build(),
            SetLineResponse.parser(),
        )

    suspend fun getHoughLineFinderArgs(): HoughLineFinderArgs =
        call("Debug.GetHoughLineFinderArgs", GetHoughLineFinderArgsRequest.getDefaultInstance(), HoughLineFinderArgs.parser())

    /** Set one of the finder's arguments by name; all of them come back as they are then. */
    suspend fun setHoughLineFinderArg(name: String, value: Double): HoughLineFinderArgs =
        call(
            "Debug.SetHoughLineFinderArgs",
            SetHoughLineFinderArgRequest.newBuilder().setName(name).setValue(value).build(),
            HoughLineFinderArgs.parser(),
        )

    suspend fun renderFrame(sessionId: String, frameIndex: Int): ImageRef =
        call("Outlier.RenderFrame", frameRef(sessionId, frameIndex), ImageRef.parser())

    suspend fun applyDecisionTree(
        sessionId: String,
        frameIndex: Int,
        overwrite: Boolean,
        autoOnly: Boolean = false,
        includingTrash: Boolean = false,
        minimumSize: Int = 0,
        rerender: Boolean = false,
    ): ApplyDecisionTreeResponse =
        call(
            "Outlier.ApplyDecisionTree",
            ApplyDecisionTreeRequest.newBuilder()
                .setSessionId(sessionId).setFrameIndex(frameIndex).setOverwrite(overwrite)
                .setAutoOnly(autoOnly).setIncludingTrash(includingTrash).setMinimumSize(minimumSize).setRerender(rerender).build(),
            ApplyDecisionTreeResponse.parser(),
        )

    suspend fun applyDecisionTreeAllFrames(sessionId: String, overwrite: Boolean, minimumSize: Int = 0): ApplyDecisionTreeAllFramesResponse =
        call(
            "Outlier.ApplyDecisionTreeAllFrames",
            ApplyDecisionTreeAllFramesRequest.newBuilder().setSessionId(sessionId).setOverwrite(overwrite).setMinimumSize(minimumSize).build(),
            ApplyDecisionTreeAllFramesResponse.parser(),
        )

    suspend fun setOutlierDecisionsInArea(
        sessionId: String, startIndex: Int, endIndex: Int, shouldRemove: Boolean,
        start: Point, end: Point, includingTrash: Boolean = false, rerender: Boolean = false, overlapping: Boolean = false,
    ): MultiFrameDecisionsResponse =
        call(
            "Outlier.SetDecisionsInArea",
            SetOutlierDecisionsInAreaRequest.newBuilder()
                .setSessionId(sessionId).setStartIndex(startIndex).setEndIndex(endIndex).setShouldRemove(shouldRemove)
                .setStartLocation(start).setEndLocation(end).setIncludingTrash(includingTrash).setRerender(rerender)
                .setOverlapping(overlapping).build(),
            MultiFrameDecisionsResponse.parser(),
        )

    suspend fun setOutlierDecisionsOverlapping(
        sessionId: String, startIndex: Int, endIndex: Int, shouldRemove: Boolean,
        referenceFrame: Int, referenceGroupId: Int, rerender: Boolean = false,
    ): MultiFrameDecisionsResponse =
        call(
            "Outlier.SetDecisionsOverlapping",
            SetOutlierDecisionsOverlappingRequest.newBuilder()
                .setSessionId(sessionId).setStartIndex(startIndex).setEndIndex(endIndex).setShouldRemove(shouldRemove)
                .setReferenceFrame(referenceFrame).setReferenceGroupId(referenceGroupId).setRerender(rerender).build(),
            MultiFrameDecisionsResponse.parser(),
        )

    /**
     * Apply a single-frame area editing tool (razor/shovel/trash/extract) to a drag rectangle (image px).
     * [groupId] > 0 is TRASH-only: dump exactly that group (single-tap), ignoring the rectangle.
     */
    suspend fun applyOutlierAreaTool(
        sessionId: String, frameIndex: Int, tool: OutlierAreaTool,
        start: Point, end: Point, includingTrash: Boolean = false, rerender: Boolean = false, groupId: Int = 0,
    ): ApplyOutlierAreaToolResponse =
        call(
            "Outlier.ApplyAreaTool",
            ApplyOutlierAreaToolRequest.newBuilder()
                .setSessionId(sessionId).setFrameIndex(frameIndex).setTool(tool)
                .setStartLocation(start).setEndLocation(end).setIncludingTrash(includingTrash).setRerender(rerender)
                .setGroupId(groupId).build(),
            ApplyOutlierAreaToolResponse.parser(),
        )

    // ---- Processing ----

    suspend fun startProcessing(sessionId: String, startIndex: Int = 0, endIndex: Int = -1, force: Boolean = false): StartProcessingResponse =
        call(
            "Processing.Start",
            StartProcessingRequest.newBuilder().setSessionId(sessionId).setStartIndex(startIndex).setEndIndex(endIndex).setForce(force).build(),
            StartProcessingResponse.parser(),
        )

    fun streamProgress(sessionId: String): Flow<ProgressEvent> =
        serverStream("Processing.StreamProgress", sessionRef(sessionId), ProgressEvent.parser())

    /** Stop the run in progress, wait until it has stopped, and start over the range with the settings as they now are. */
    suspend fun restartProcessing(sessionId: String, startIndex: Int = 0, endIndex: Int = -1): StartProcessingResponse =
        call(
            "Processing.Restart",
            StartProcessingRequest.newBuilder().setSessionId(sessionId).setStartIndex(startIndex).setEndIndex(endIndex).build(),
            StartProcessingResponse.parser(),
        )

    suspend fun cancelProcessing(sessionId: String): CancelResponse =
        call("Processing.Cancel", sessionRef(sessionId), CancelResponse.parser())

    suspend fun reprocessFrames(sessionId: String, frameIndices: List<Int>, type: ReprocessingType): ReprocessFramesResponse =
        call(
            "Processing.ReprocessFrames",
            ReprocessFramesRequest.newBuilder().setSessionId(sessionId).addAllFrameIndices(frameIndices).setType(type).build(),
            ReprocessFramesResponse.parser(),
        )

    // ---- Export ----

    fun renderSequence(sessionId: String): Flow<ProgressEvent> =
        serverStream("Export.RenderSequence", sessionRef(sessionId), ProgressEvent.parser())

    /** Where a video would be written for the container [muxer] (empty for the session's own), before anything is rendered. */
    suspend fun getDefaultVideoPath(sessionId: String, muxer: String = ""): String =
        call(
            "Export.GetDefaultVideoPath",
            GetDefaultVideoPathRequest.newBuilder().setSessionId(sessionId).setMuxer(muxer).build(),
            GetDefaultVideoPathResponse.parser(),
        ).outputVideoPath

    fun exportVideo(
        sessionId: String,
        outputVideoPath: String = "",
        settings: VideoEncodeSettings = VideoEncodeSettings.getDefaultInstance(),
    ): Flow<ProgressEvent> =
        serverStream(
            "Export.Video",
            ExportVideoRequest.newBuilder().setSessionId(sessionId).setOutputVideoPath(outputVideoPath).setSettings(settings).build(),
            ProgressEvent.parser(),
        )

    suspend fun getVideoCapabilities(): VideoCapabilities =
        call("Export.GetVideoCapabilities", GetVideoCapabilitiesRequest.getDefaultInstance(), VideoCapabilities.parser())

    // ---- Alignment ----

    suspend fun getAlignment(sessionId: String, frameIndex: Int): AlignmentInfo =
        call("Alignment.Get", GetAlignmentRequest.newBuilder().setSessionId(sessionId).setFrameIndex(frameIndex).build(), AlignmentInfo.parser())

    suspend fun getAlignmentSequence(
        sessionId: String,
        includeHomography: Boolean = false,
        includePreviews: Boolean = false,
    ): AlignmentSequence =
        call(
            "Alignment.GetSequence",
            GetAlignmentSequenceRequest.newBuilder().setSessionId(sessionId)
                .setIncludeHomography(includeHomography).setIncludePreviews(includePreviews).build(),
            AlignmentSequence.parser(),
        )

    // ---- Horizon ----

    suspend fun setReferenceHorizon(req: SetReferenceHorizonRequest): SetReferenceHorizonResponse =
        call("Horizon.SetReference", req, SetReferenceHorizonResponse.parser())

    suspend fun getReferenceHorizon(sessionId: String, frameIndex: Int): GetReferenceHorizonResponse =
        call("Horizon.GetReference", GetReferenceHorizonRequest.newBuilder().setSessionId(sessionId).setFrameIndex(frameIndex).build(), GetReferenceHorizonResponse.parser())

    suspend fun clearReferenceHorizon(sessionId: String, frameIndex: Int, clearGlobal: Boolean): ClearReferenceHorizonResponse =
        call(
            "Horizon.ClearReference",
            ClearReferenceHorizonRequest.newBuilder().setSessionId(sessionId).setFrameIndex(frameIndex).setClearGlobal(clearGlobal).build(),
            ClearReferenceHorizonResponse.parser(),
        )

    @Deprecated("Horizon.ReferenceUpdated + Horizon.RunRefinement; this streams a run for old clients")
    fun reprocessHorizons(sessionId: String, editedFrames: List<Int>): Flow<ProgressEvent> =
        serverStream(
            "Horizon.Reprocess",
            ReprocessHorizonsRequest.newBuilder().setSessionId(sessionId).addAllEditedFrameIndices(editedFrames).build(),
            ProgressEvent.parser(),
        )

    /** The reference of [frameIndex] was saved; with [applyToNearby] the frames that interpolate from it become pending. */
    suspend fun horizonReferenceUpdated(sessionId: String, frameIndex: Int, applyToNearby: Boolean): HorizonReferenceUpdatedResponse =
        call(
            "Horizon.ReferenceUpdated",
            HorizonReferenceUpdatedRequest.newBuilder().setSessionId(sessionId).setFrameIndex(frameIndex).setApplyToNearby(applyToNearby).build(),
            HorizonReferenceUpdatedResponse.parser(),
        )

    /** The painter's "max downward extension": as stored (0 = derive) and as in force. */
    suspend fun getTunedHorizonParameters(sessionId: String): TunedHorizonParametersResponse =
        call("Horizon.GetTunedParameters", sessionRef(sessionId), TunedHorizonParametersResponse.parser())

    suspend fun setTunedHorizonMaxDownwardExtension(sessionId: String, maxDownwardExtension: Int): TunedHorizonParametersResponse =
        call(
            "Horizon.SetTunedParameters",
            SetTunedHorizonParametersRequest.newBuilder().setSessionId(sessionId).setMaxDownwardExtension(maxDownwardExtension).build(),
            TunedHorizonParametersResponse.parser(),
        )

    suspend fun getHorizonRefinementStatus(sessionId: String): RefinementStatusResponse =
        call("Horizon.GetRefinementStatus", sessionRef(sessionId), RefinementStatusResponse.parser())

    /** "Later": keep the refinement pending, but take away what the old horizon was baked into. */
    suspend fun deferHorizonRefinement(sessionId: String): DeferRefinementResponse =
        call("Horizon.DeferRefinement", sessionRef(sessionId), DeferRefinementResponse.parser())

    /** "Now": queue the pending refinement as a run; progress and the end of it arrive on the progress stream. */
    suspend fun runHorizonRefinement(sessionId: String): RunRefinementResponse =
        call("Horizon.RunRefinement", sessionRef(sessionId), RunRefinementResponse.parser())

    suspend fun getHorizonOverlay(sessionId: String, frameIndex: Int, width: Int, height: Int): GetHorizonOverlayResponse =
        call(
            "Horizon.GetOverlay",
            GetHorizonOverlayRequest.newBuilder().setSessionId(sessionId).setFrameIndex(frameIndex).setWidth(width).setHeight(height).build(),
            GetHorizonOverlayResponse.parser(),
        )

    suspend fun computeHorizonInBand(req: ComputeHorizonInBandRequest): ComputeHorizonInBandResponse =
        call("Horizon.ComputeInBand", req, ComputeHorizonInBandResponse.parser())

    suspend fun getBestHorizon(sessionId: String, frameIndex: Int, spaceWidth: Int, spaceHeight: Int): GetBestHorizonResponse =
        call(
            "Horizon.GetBest",
            GetBestHorizonRequest.newBuilder().setSessionId(sessionId).setFrameIndex(frameIndex)
                .setSpaceWidth(spaceWidth).setSpaceHeight(spaceHeight).build(),
            GetBestHorizonResponse.parser(),
        )

    // ---- helpers ----

    private fun frameRef(sessionId: String, frameIndex: Int): FrameRef =
        FrameRef.newBuilder().setSessionId(sessionId).setFrameIndex(frameIndex).build()

    private fun sessionRef(sessionId: String): SessionRef =
        SessionRef.newBuilder().setSessionId(sessionId).build()
}
