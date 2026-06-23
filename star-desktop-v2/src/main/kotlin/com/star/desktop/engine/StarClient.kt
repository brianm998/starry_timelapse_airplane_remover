package com.star.desktop.engine

import com.google.protobuf.MessageLite
import com.google.protobuf.Parser
import com.star.proto.CancelResponse
import com.star.proto.CleanMethod
import com.star.proto.CloseSessionRequest
import com.star.proto.CloseSessionResponse
import com.star.proto.Config
import com.star.proto.ExportVideoRequest
import com.star.proto.FrameInfo
import com.star.proto.FrameRef
import com.star.proto.FrameViewMode
import com.star.proto.GetFramePreviewRequest
import com.star.proto.GetVideoCapabilitiesRequest
import com.star.proto.HelloRequest
import com.star.proto.HelloResponse
import com.star.proto.ImageRef
import com.star.proto.ListSessionsRequest
import com.star.proto.ListSessionsResponse
import com.star.proto.OpenConfigRequest
import com.star.proto.OpenProgress
import com.star.proto.OpenSequenceRequest
import com.star.proto.OpenVideoRequest
import com.star.proto.OutlierDecision
import com.star.proto.OutlierGroupList
import com.star.proto.ProgressEvent
import com.star.proto.SessionInfo
import com.star.proto.SessionRef
import com.star.proto.SetFrameCleanMethodRequest
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

    suspend fun hello(clientVersion: String): HelloResponse =
        call("Daemon.Hello", HelloRequest.newBuilder().setClientVersion(clientVersion).build(), HelloResponse.parser())

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

    // ---- Processing ----

    suspend fun startProcessing(sessionId: String, startIndex: Int = 0, endIndex: Int = -1): StartProcessingResponse =
        call(
            "Processing.Start",
            StartProcessingRequest.newBuilder().setSessionId(sessionId).setStartIndex(startIndex).setEndIndex(endIndex).build(),
            StartProcessingResponse.parser(),
        )

    fun streamProgress(sessionId: String): Flow<ProgressEvent> =
        serverStream("Processing.StreamProgress", sessionRef(sessionId), ProgressEvent.parser())

    suspend fun cancelProcessing(sessionId: String): CancelResponse =
        call("Processing.Cancel", sessionRef(sessionId), CancelResponse.parser())

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

    // ---- helpers ----

    private fun frameRef(sessionId: String, frameIndex: Int): FrameRef =
        FrameRef.newBuilder().setSessionId(sessionId).setFrameIndex(frameIndex).build()

    private fun sessionRef(sessionId: String): SessionRef =
        SessionRef.newBuilder().setSessionId(sessionId).build()
}
