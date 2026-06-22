package com.star.engine

import com.google.protobuf.MessageLite
import com.google.protobuf.Parser
import com.star.proto.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/**
 * Typed RPC client over [StdioConnection].
 * Every §3 method gets one suspend fun or Flow fun here.
 * Repositories call these; never construct Envelopes in UI code.
 *
 * See KOTLIN_CLIENT_SPEC.md §2.3, §3.
 */
class StarClient(private val conn: StdioConnection) {

    // ---- Generic helpers ----

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
    ): Flow<Item> = conn.sendStream(method, req.toByteArray())
        .map { env -> parser.parseFrom(env.payload) }

    // ---- Daemon ----

    suspend fun hello(clientVersion: String): HelloResponse =
        call(
            "Daemon.Hello",
            HelloRequest.newBuilder().setClientVersion(clientVersion).build(),
            HelloResponse.parser(),
        )

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
        call(
            "Session.OpenConfig",
            OpenConfigRequest.newBuilder().setConfigJsonPath(configJsonPath).build(),
            SessionInfo.parser(),
        )

    suspend fun closeSession(sessionId: String): CloseSessionResponse =
        call(
            "Session.Close",
            CloseSessionRequest.newBuilder().setSessionId(sessionId).build(),
            CloseSessionResponse.parser(),
        )

    suspend fun listSessions(): ListSessionsResponse =
        call("Session.List", ListSessionsRequest.getDefaultInstance(), ListSessionsResponse.parser())

    // ---- Sequence ----

    suspend fun getConfig(sessionId: String): Config =
        call(
            "Sequence.GetConfig",
            SessionRef.newBuilder().setSessionId(sessionId).build(),
            Config.parser(),
        )

    suspend fun updateConfig(sessionId: String, config: Config): Config =
        call(
            "Sequence.UpdateConfig",
            UpdateConfigRequest.newBuilder().setSessionId(sessionId).setConfig(config).build(),
            Config.parser(),
        )

    // ---- Frame ----

    suspend fun getFrame(sessionId: String, frameIndex: Int): FrameInfo =
        call(
            "Frame.Get",
            FrameRef.newBuilder().setSessionId(sessionId).setFrameIndex(frameIndex).build(),
            FrameInfo.parser(),
        )

    suspend fun getFramePreview(sessionId: String, frameIndex: Int, viewMode: FrameViewMode): ImageRef =
        call(
            "Frame.GetPreview",
            GetFramePreviewRequest.newBuilder()
                .setSessionId(sessionId)
                .setFrameIndex(frameIndex)
                .setViewMode(viewMode)
                .build(),
            ImageRef.parser(),
        )

    suspend fun getOutlierLabelImage(sessionId: String, frameIndex: Int): ImageRef =
        call(
            "Frame.GetOutlierLabelImage",
            FrameRef.newBuilder().setSessionId(sessionId).setFrameIndex(frameIndex).build(),
            ImageRef.parser(),
        )

    suspend fun setFrameCleanMethod(sessionId: String, frameIndex: Int, cleanMethod: CleanMethod): FrameInfo =
        call(
            "Frame.SetCleanMethod",
            SetFrameCleanMethodRequest.newBuilder()
                .setSessionId(sessionId)
                .setFrameIndex(frameIndex)
                .setCleanMethod(cleanMethod)
                .build(),
            FrameInfo.parser(),
        )

    // ---- Outlier ----

    suspend fun listOutliers(sessionId: String, frameIndex: Int): OutlierGroupList =
        call(
            "Outlier.List",
            FrameRef.newBuilder().setSessionId(sessionId).setFrameIndex(frameIndex).build(),
            OutlierGroupList.parser(),
        )

    suspend fun setOutlierDecisions(
        sessionId: String,
        frameIndex: Int,
        decisions: List<OutlierDecision>,
        rerender: Boolean = false,
    ): SetOutlierDecisionsResponse =
        call(
            "Outlier.SetDecisions",
            SetOutlierDecisionsRequest.newBuilder()
                .setSessionId(sessionId)
                .setFrameIndex(frameIndex)
                .addAllDecisions(decisions)
                .setRerender(rerender)
                .build(),
            SetOutlierDecisionsResponse.parser(),
        )

    suspend fun renderFrame(sessionId: String, frameIndex: Int): ImageRef =
        call(
            "Outlier.RenderFrame",
            FrameRef.newBuilder().setSessionId(sessionId).setFrameIndex(frameIndex).build(),
            ImageRef.parser(),
        )

    // ---- Processing ----

    suspend fun startProcessing(sessionId: String, startIndex: Int = 0, endIndex: Int = -1): StartProcessingResponse =
        call(
            "Processing.Start",
            StartProcessingRequest.newBuilder()
                .setSessionId(sessionId)
                .setStartIndex(startIndex)
                .setEndIndex(endIndex)
                .build(),
            StartProcessingResponse.parser(),
        )

    fun streamProgress(sessionId: String): Flow<ProgressEvent> =
        serverStream(
            "Processing.StreamProgress",
            SessionRef.newBuilder().setSessionId(sessionId).build(),
            ProgressEvent.parser(),
        )

    suspend fun cancelProcessing(sessionId: String): CancelResponse =
        call(
            "Processing.Cancel",
            SessionRef.newBuilder().setSessionId(sessionId).build(),
            CancelResponse.parser(),
        )

    // ---- Export ----

    fun renderSequence(sessionId: String): Flow<ProgressEvent> =
        serverStream(
            "Export.RenderSequence",
            SessionRef.newBuilder().setSessionId(sessionId).build(),
            ProgressEvent.parser(),
        )

    fun exportVideo(
        sessionId: String,
        outputVideoPath: String = "",
        settings: VideoEncodeSettings = VideoEncodeSettings.getDefaultInstance(),
    ): Flow<ProgressEvent> =
        serverStream(
            "Export.Video",
            ExportVideoRequest.newBuilder()
                .setSessionId(sessionId)
                .setOutputVideoPath(outputVideoPath)
                .setSettings(settings)
                .build(),
            ProgressEvent.parser(),
        )

    suspend fun getVideoCapabilities(): VideoCapabilities =
        call(
            "Export.GetVideoCapabilities",
            GetVideoCapabilitiesRequest.getDefaultInstance(),
            VideoCapabilities.parser(),
        )
}
