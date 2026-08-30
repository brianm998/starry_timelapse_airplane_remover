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
        println("configJson=${info.configJsonPath.ifEmpty { "${info.scratchSessionDir}/config.json" }}")

        if (mode == "process" || mode == "processall" || mode == "selective") {
            val done = CompletableDeferred<Unit>()
            val sub = scope.launch {
                var n = 0
                try {
                    client.streamProgress(info.sessionId).collect { ev ->
                        n++
                        if (n <= 4 || ev.kindCase == ProgressEvent.KindCase.SEQUENCE_STATE) {
                            val extra = if (ev.kindCase == ProgressEvent.KindCase.SEQUENCE_STATE) " '${ev.sequenceState.state}'" else ""
                            println("  [recv #$n] ${ev.kindCase}$extra")
                        }
                        if (ev.kindCase == ProgressEvent.KindCase.SEQUENCE_STATE && ev.sequenceState.state == "done") done.complete(Unit)
                    }
                    println("  [client] progress stream ENDED after $n events")
                } catch (e: Throwable) {
                    println("  [client] progress stream FAILED after $n events: ${e.message}")
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

            // ---- Alignment endpoints ----
            val seq = runCatching { client.getAlignmentSequence(info.sessionId, includeHomography = true, includePreviews = true) }.getOrNull()
            println("  alignment: ${seq?.framesCount ?: "error"} frames")
            seq?.framesList?.getOrNull(1)?.let { a ->
                println("    frame1: star=${a.hasStarResults} neighbors=${a.star.neighborsCount} compositeDev=${"%.4f".format(a.star.compositeDeviation)} ok=${a.star.alignmentLooksOk} skyKp=${a.numSkyKeypoints}")
                a.star.neighborsList.firstOrNull()?.let { n ->
                    println("    neighbor0: idx=${n.frameIndex} dev=${"%.4f".format(n.deviation)} state=${n.state} hom=${n.homographyCount} preview=${n.alignedPreview.path.substringAfterLast('/').ifEmpty { "—" }}")
                }
            }

            // ---- Horizon endpoints ---- (paint a flat reference at mid-height, then read it back)
            val w = info.imageWidth; val h = info.imageHeight
            val setResp = runCatching {
                val cols = com.star.proto.HorizonColumns.newBuilder().setSpaceWidth(w).setSpaceHeight(h).addAllHorizonY(List(w) { h / 2 }).build()
                client.setReferenceHorizon(
                    com.star.proto.SetReferenceHorizonRequest.newBuilder()
                        .setSessionId(info.sessionId).setFrameIndex(1).setColumns(cols).setSetStaticReference(true).build(),
                )
            }.getOrElse { println("  horizon set ERROR: ${it.message}"); null }
            println("  horizon set: global=${setResp?.isGlobal} mask=${setResp?.referenceMask?.path?.substringAfterLast('/') ?: "—"}")
            val getResp = runCatching { client.getReferenceHorizon(info.sessionId, 1) }.getOrNull()
            println("  horizon get: exists=${getResp?.exists} cols=${getResp?.columns?.horizonYCount ?: 0}")
        }

        if (!path.endsWith("config.json")) client.closeSession(info.sessionId)
        engine.shutdown()
        println("Done.")
    }
}
