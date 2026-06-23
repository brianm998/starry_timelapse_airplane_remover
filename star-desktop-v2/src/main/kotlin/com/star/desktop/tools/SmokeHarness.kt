package com.star.desktop.tools

import com.star.desktop.data.SessionRepository
import com.star.desktop.engine.DaemonProcess
import com.star.desktop.engine.EngineState
import com.star.desktop.engine.EngineStatus
import com.star.proto.CleanMethod
import com.star.proto.Config
import com.star.proto.FrameViewMode
import com.star.proto.ProgressEvent
import com.star.proto.SessionInfo
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File

/**
 * Headless engine harness for verifying the daemon against a real `stard`.
 *
 *   ./gradlew smoke -Pseq="/abs/seq"                       # open + Hello
 *   ./gradlew smoke -Pseq="/abs/seq" -Pmode=processall     # process all (automatic), then probe
 *   ./gradlew smoke -Pseq="/abs/seq" -Pmode=selective      # process all (SELECTIVE → outliers), then probe
 *   ./gradlew smoke -Pseq="/abs/.../config.json" -Pmode=query   # resume a session and probe only
 */
object SmokeHarness {
    @JvmStatic
    fun main(args: Array<String>) = runBlocking {
        val scope = CoroutineScope(SupervisorJob())
        val engine = EngineState(scope)
        println("Resolving stard… ${runCatching { DaemonProcess.resolveStardBinary() }.getOrElse { it.message }}")
        if (!engine.start()) { System.err.println("FAILED: ${engine.status.value}"); return@runBlocking }
        val c = engine.status.value as EngineStatus.Connected
        println("Connected: daemonVersion=${c.daemonVersion} scratch=${c.scratchDir}")
        val client = engine.client!!

        val path = args.firstOrNull() ?: run {
            println("Sessions: ${client.listSessions().sessionsCount}"); engine.shutdown(); return@runBlocking
        }
        val mode = args.getOrNull(1) ?: "open"

        val info: SessionInfo = if (path.endsWith("config.json")) {
            println("Resuming config: $path")
            client.openConfig(path)
        } else {
            val clean = when (mode) {
                "selective" -> CleanMethod.CLEAN_SELECTIVE
                "processall", "process" -> CleanMethod.CLEAN_AUTOMATIC // fast path (no per-blob classification)
                else -> CleanMethod.CLEAN_SELECTIVE
            }
            val cfg = Config.newBuilder(SessionRepository.defaultInitialConfig()).setCleanMethod(clean).build()
            client.openSequence(File(path).absolutePath, cfg)
        }
        println("SessionInfo: id=${info.sessionId} frames=${info.frameCount} ${info.imageWidth}x${info.imageHeight}")
        println("configJson=${info.scratchSessionDir}/config.json")

        if (mode == "process" || mode == "processall" || mode == "selective") {
            val done = CompletableDeferred<Unit>()
            val sub = scope.launch {
                client.streamProgress(info.sessionId).collect { ev ->
                    if (ev.kindCase == ProgressEvent.KindCase.SEQUENCE_STATE && ev.sequenceState.state == "done") done.complete(Unit)
                }
            }
            delay(400)
            val end = if (mode == "process") 2 else -1
            println("Processing (mode=$mode endIndex=$end)…")
            client.startProcessing(info.sessionId, 0, end)
            val ok = withTimeoutOrNull(1_200_000) { done.await() } != null
            println("processing ${if (ok) "completed" else "TIMED OUT"}")
            sub.cancel()
        }

        // Probe what the client can actually retrieve for frame 0.
        if (mode == "query" || mode == "processall" || mode == "process" || mode == "selective") {
            for (vm in FrameViewMode.entries.filter { it != FrameViewMode.UNRECOGNIZED }) {
                val ref = runCatching { client.getFramePreview(info.sessionId, 0, vm) }.getOrNull()
                println("  preview[$vm] = ${ref?.path?.substringAfterLast('/') ?: "—"}")
            }
            val groups = runCatching { client.listOutliers(info.sessionId, 0) }.getOrNull()
            println("  outliers[0] = ${groups?.groupsCount ?: "error"}")
            groups?.groupsList?.take(3)?.forEach {
                println("    group id=${it.id} size=${it.size} bounds=(${it.bounds.minX},${it.bounds.minY})-(${it.bounds.maxX},${it.bounds.maxY}) decision=${it.shouldRemove}")
            }
            val label = runCatching { client.getOutlierLabelImage(info.sessionId, 0) }.getOrNull()
            println("  labelImage[0] = ${label?.path?.substringAfterLast('/') ?: "—"}")
        }

        if (!path.endsWith("config.json")) client.closeSession(info.sessionId)
        engine.shutdown()
        println("Done.")
    }
}
