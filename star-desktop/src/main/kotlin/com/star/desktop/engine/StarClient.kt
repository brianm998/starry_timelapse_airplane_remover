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
import com.star.proto.OutlierAreaTool
import com.star.proto.CancelResponse
import com.star.proto.CleanMethod
import com.star.proto.ClearReferenceHorizonRequest
import com.star.proto.ClearReferenceHorizonResponse
import com.star.proto.ComputeHorizonInBandRequest
import com.star.proto.ComputeHorizonInBandResponse
import com.star.proto.GetBestHorizonRequest
import com.star.proto.GetBestHorizonResponse
import com.star.proto.GetAlignmentRequest
import com.star.proto.GetAlignmentSequenceRequest
import com.star.proto.GetReferenceHorizonRequest
import com.star.proto.GetReferenceHorizonResponse
import com.star.proto.ReprocessHorizonsRequest
import com.star.proto.SetReferenceHorizonRequest
import com.star.proto.SetReferenceHorizonResponse
import com.star.proto.CloseSessionRequest
import com.star.proto.CloseSessionResponse
import com.star.proto.Config
import com.star.proto.ExportVideoRequest
import com.star.proto.FrameInfo
import com.star.proto.FrameRef
import com.star.proto.FrameViewMode
import com.star.proto.GetFramePreviewRequest
import com.star.proto.GetHorizonOverlayRequest
import com.star.proto.GetHorizonOverlayResponse
import com.star.proto.GetVideoCapabilitiesRequest
import com.star.proto.HelloRequest
import com.star.proto.HelloResponse
import com.star.proto.ImageRef
import com.star.proto.ListSessionsRequest
import com.star.proto.ListSessionsResponse
import com.star.proto.MultiFrameDecisionsResponse
import com.star.proto.OpenConfigRequest
import com.star.proto.OpenProgress
import com.star.proto.OpenSequenceRequest
import com.star.proto.OpenVideoRequest
import com.star.proto.OutlierDecision
import com.star.proto.OutlierGroupList
import com.star.proto.Point
import com.star.proto.ProgressEvent
import com.star.proto.ReprocessFramesRequest
import com.star.proto.ReprocessFramesResponse
import com.star.proto.ReprocessingType
import com.star.proto.SessionInfo
import com.star.proto.SessionRef
import com.star.proto.SetFrameCleanMethodRequest
import com.star.proto.SetOutlierDecisionsInAreaRequest
import com.star.proto.SetOutlierDecisionsOverlappingRequest
import com.star.proto.SetOutlierDecisionsRequest
import com.star.proto.SetOutlierDecisionsResponse
import com.star.proto.ShutdownRequest
import com.star.proto.ShutdownResponse
import com.star.proto.StartProcessingRequest
import com.star.proto.StartProcessingResponse
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

    suspend fun shutdown(): ShutdownResponse =
        call("Daemon.Shutdown", ShutdownRequest.getDefaultInstance(), ShutdownResponse.parser())

    // ---- Session ----

    fun openVideo(videoPath: String, initialConfig: Config = Config.getDefaultInstance()): Flow<OpenProgress> =
        serverStream(
            "Session.OpenVideo",
            OpenVideoRequest.newBuilder().setVideoPath(videoPath).setInitialConfig(initialConfig).build(),
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

    // ---- Frame ----

    suspend fun getFrame(sessionId: String, frameIndex: Int): FrameInfo =
        call("Frame.Get", frameRef(sessionId, frameIndex), FrameInfo.parser())

    suspend fun getFramePreview(sessionId: String, frameIndex: Int, viewMode: FrameViewMode): ImageRef =
        call(
            "Frame.GetPreview",
            GetFramePreviewRequest.newBuilder().setSessionId(sessionId).setFrameIndex(frameIndex).setViewMode(viewMode).build(),
            ImageRef.parser(),
        )

    suspend fun getOutlierLabelImage(sessionId: String, frameIndex: Int): ImageRef =
        call("Frame.GetOutlierLabelImage", frameRef(sessionId, frameIndex), ImageRef.parser())

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

    fun reprocessHorizons(sessionId: String, editedFrames: List<Int>): Flow<ProgressEvent> =
        serverStream(
            "Horizon.Reprocess",
            ReprocessHorizonsRequest.newBuilder().setSessionId(sessionId).addAllEditedFrameIndices(editedFrames).build(),
            ProgressEvent.parser(),
        )

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
