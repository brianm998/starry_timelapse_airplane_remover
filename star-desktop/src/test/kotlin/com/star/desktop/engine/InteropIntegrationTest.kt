package com.star.desktop.engine

import com.star.desktop.data.SessionRepository
import com.star.proto.CleanMethod
import com.star.proto.Config
import com.star.proto.ProgressEvent
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.security.MessageDigest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Integration tests against a REAL `stard` (§8.2/§8.3). They spawn the daemon, so they only run when
 * the relevant fixture is provided; otherwise they no-op (green) so normal CI / `gradle test` stays
 * fast and self-contained:
 *   - `-Dstar.it.config=/abs/config.json`  → cross-client resume + config-interop test (§8.3 gate).
 *   - `-Dstar.it.seq=/abs/sequence`         → RPC smoke against a fresh sequence (§8.2).
 * stard is resolved by DaemonProcess (../daemon/.build/debug/stard from the gradle project, or
 * -Dstar.stard.path / STARD_PATH).
 */
class InteropIntegrationTest {

    private val configPath: String? = System.getProperty("star.it.config")?.takeIf { it.isNotBlank() }
    private val seqPath: String? = System.getProperty("star.it.seq")?.takeIf { it.isNotBlank() }
    private val runProcess: Boolean = System.getProperty("star.it.process") == "true"

    /** Spawn a fresh stard, run [block] with a connected client, then shut down. */
    private fun <T> withEngine(block: suspend (StarClient) -> T): T = runBlocking {
        val scope = CoroutineScope(SupervisorJob())
        val engine = EngineState(scope)
        assertTrue(engine.start(), "engine failed to start: ${engine.status.value}")
        try {
            block(engine.client ?: error("no client after start"))
        } finally {
            engine.shutdown()
        }
    }

    /**
     * §8.3 cross-client interop gate (config-compatibility slice): a session described by a config.json
     * must resume identically across independent daemon processes, and the on-disk config format must
     * be stable. (Pixel-identity of rendered output is a separate, fixture+processing-heavy check.)
     */
    @Test
    fun crossClientConfigResume() {
        val cfg = configPath ?: run {
            println("[skip] crossClientConfigResume — set -Dstar.it.config=<config.json>")
            return
        }
        val file = File(cfg)
        assertTrue(file.exists(), "config not found: $cfg")

        val (protoA, diskA) = withEngine { client ->
            val info = client.openConfig(file.absolutePath)
            client.getConfig(info.sessionId) to file.readText()
        }
        // A second, independent daemon process resumes the same config (the cross-client path).
        val (protoB, diskB) = withEngine { client ->
            val info = client.openConfig(file.absolutePath)
            client.getConfig(info.sessionId) to file.readText()
        }

        assertEquals(protoA, protoB, "GetConfig differs across resumes — cross-client resume is not idempotent")
        assertEquals(diskA, diskB, "config.json bytes changed across resume — interop format is not stable")
        assertTrue(protoA.starVersion.isNotEmpty(), "config.starVersion missing (version-mismatch warning would not work)")
        assertTrue(protoA.hasNumberAlignedNeighborFrames(), "expert config field not round-tripped")
    }

    /** §8.2 RPC smoke against a real stard from a fresh sequence: Hello → open → frame/outlier reads → close. */
    @Test
    fun rpcSmokeOnSequence() {
        val seq = seqPath ?: run {
            println("[skip] rpcSmokeOnSequence — set -Dstar.it.seq=<sequence dir>")
            return
        }
        withEngine { client ->
            val hello = client.hello("itest", "en")
            assertTrue(hello.daemonVersion.isNotEmpty(), "Daemon.Hello returned no version")
            assertEquals("en", hello.locale, "Daemon.Hello did not adopt the locale we asked for")

            val cfg = Config.newBuilder(SessionRepository.defaultInitialConfig())
                .setCleanMethod(CleanMethod.CLEAN_SELECTIVE).build()
            val info = client.openSequence(File(seq).absolutePath, cfg)
            assertTrue(info.frameCount > 0, "OpenSequence returned no frames")
            assertTrue(info.imageWidth > 0 && info.imageHeight > 0, "OpenSequence returned no image dimensions")

            val frame = client.getFrame(info.sessionId, 0)
            assertEquals(0, frame.frameIndex)

            // On-demand preview generation: a freshly-opened, unprocessed sequence has no preview
            // JPEGs on disk, but Frame.GetPreview must generate the VIEW_ORIGINAL preview on demand
            // (mirroring the macOS GUI's PreviewOp/makeMissingImage). Without this the Kotlin client
            // shows blank frames + "loading…" thumbnails forever on every new sequence.
            val preview = client.getFramePreview(info.sessionId, 0, com.star.proto.FrameViewMode.VIEW_ORIGINAL)
            assertTrue(preview.path.isNotEmpty(), "GetPreview(VIEW_ORIGINAL) returned no path on a fresh sequence")
            assertTrue(File(preview.path).exists(), "GetPreview(VIEW_ORIGINAL) path does not exist on disk: ${preview.path}")

            // Outliers may not exist pre-processing; the call must not break the connection.
            runCatching { client.listOutliers(info.sessionId, 0) }
            client.closeSession(info.sessionId)
            // Connection still healthy after the round-trip.
            assertTrue(client.listSessions().sessionsCount >= 0)
        }
    }

    /**
     * Interactive horizon painter RPCs (`Horizon.GetBest` + `Horizon.ComputeInBand`) against a real
     * stard: a fresh sequence has no best-existing horizon; the combined detector over a full-width
     * band returns a per-column line of the right length without breaking the connection. This is the
     * daemon side of the Kotlin horizon-painter parity — the live band→detect path the macOS app runs.
     */
    @Test
    fun horizonComputeInBandRoundTrip() {
        val seq = seqPath ?: run {
            println("[skip] horizonComputeInBandRoundTrip — set -Dstar.it.seq=<sequence dir>")
            return
        }
        withEngine { client ->
            val info = client.openSequence(File(seq).absolutePath, SessionRepository.defaultInitialConfig())
            val w = info.imageWidth
            val h = info.imageHeight

            // No reference/horizon yet on a fresh sequence → best-existing reports none.
            val best = client.getBestHorizon(info.sessionId, 0, w, h)
            assertTrue(!best.exists, "fresh sequence unexpectedly reported a best-existing horizon")

            // A horizontal band across the full width through the vertical middle.
            val top = List(w) { (h * 0.40).toInt() }
            val bottom = List(w) { (h * 0.60).toInt() }
            val req = com.star.proto.ComputeHorizonInBandRequest.newBuilder()
                .setSessionId(info.sessionId).setFrameIndex(0)
                .setMethod(com.star.proto.HorizonBandMethod.HORIZON_BAND_METHOD_COMBINED_SIOX)
                .setSpaceWidth(w).setSpaceHeight(h)
                .addAllTopBoundaryY(top).addAllBottomBoundaryY(bottom)
                .build()
            val resp = client.computeHorizonInBand(req)
            assertEquals(w, resp.columns.horizonYCount, "detector returned a per-column line of the wrong length")
            // At least some columns should resolve to a horizon row in [0, h).
            assertTrue(resp.columns.horizonYList.any { it in 0 until h }, "detector produced no in-range horizon rows")

            // Connection still healthy.
            client.closeSession(info.sessionId)
            assertTrue(client.listSessions().sessionsCount >= 0)
        }
    }

    /**
     * §8.4 golden output: process + render the same sequence twice via independent daemon processes
     * and assert the rendered output frames are byte-identical — the §4.4 "same engine + same inputs ⇒
     * same output" guarantee that underpins cross-client output identity. Heavy (real processing), so
     * gated behind -Dstar.it.process=true (and needs -Dstar.it.seq).
     */
    @Test
    fun goldenRenderIsDeterministic() {
        val seq = seqPath
        if (!runProcess || seq == null) {
            println("[skip] goldenRenderIsDeterministic — set -Dstar.it.process=true -Dstar.it.seq=<dir>")
            return
        }
        val hashesA = processAndRenderHashes(seq)
        val hashesB = processAndRenderHashes(seq)
        assertTrue(hashesA.isNotEmpty(), "no rendered output frames found")
        assertEquals(hashesA, hashesB, "rendered output differs between identical runs (non-deterministic output)")
    }

    /**
     * Area editing tools round-trip (`Outlier.ApplyAreaTool`): process a sequence with a usesOutliers
     * clean method (so outlier groups are loaded), then drive razor/shovel/trash/extract against the real
     * daemon. Asserts the trash op moves a group into the trash and extract pulls it back — the behavior the
     * macOS FrameEditView drag relies on. Heavy (real selective processing), so gated like the golden test.
     */
    @Test
    fun areaToolRoundTrip() {
        val seq = seqPath
        if (!runProcess || seq == null) {
            println("[skip] areaToolRoundTrip — set -Dstar.it.process=true -Dstar.it.seq=<dir>")
            return
        }
        withEngine { client ->
            val cfg = Config.newBuilder(SessionRepository.defaultInitialConfig())
                .setCleanMethod(CleanMethod.CLEAN_SELECTIVE).build() // selective → outlier groups exist + loaded
            val info = client.openSequence(File(seq).absolutePath, cfg)

            val done = CompletableDeferred<Unit>()
            val sub = CoroutineScope(SupervisorJob()).launch {
                runCatching {
                    client.streamProgress(info.sessionId).collect { ev ->
                        if (ev.kindCase == ProgressEvent.KindCase.SEQUENCE_STATE && ev.sequenceState.state == "done") done.complete(Unit)
                    }
                }
            }
            delay(400)
            client.startProcessing(info.sessionId, 0, -1)
            assertTrue(withTimeoutOrNull(1_200_000) { done.await() } != null, "processing timed out")
            sub.cancel()

            // Find a frame that actually has outlier groups (some frames legitimately have none). This
            // also exercises the daemon's load-on-demand: StarCore purges groups to disk after processing,
            // so listing returning groups at all proves the reload path works.
            val frameIdx = (0 until info.frameCount).firstOrNull { client.listOutliers(info.sessionId, it).groupsCount > 0 }
            if (frameIdx == null) {
                println("[skip] areaToolRoundTrip — no frame has outlier groups after processing")
                client.closeSession(info.sessionId); return@withEngine
            }
            val before = client.listOutliers(info.sessionId, frameIdx).groupsList
            // Pick the largest group (most likely cleanly isolated within its own bounds).
            val g = before.maxBy { (it.bounds.maxX - it.bounds.minX).toLong() * (it.bounds.maxY - it.bounds.minY) }
            val sx = g.bounds.minX.toDouble(); val sy = g.bounds.minY.toDouble()
            val ex = g.bounds.maxX.toDouble(); val ey = g.bounds.maxY.toDouble()
            fun pt(x: Double, y: Double) = com.star.proto.Point.newBuilder().setX(x).setY(y).build()

            // TRASH single-group (groupId > 0, the client's single-tap path): EXACTLY the tapped group leaves
            // the member list — never any nested group. Member count must drop by exactly one.
            val trashed = client.applyOutlierAreaTool(info.sessionId, frameIdx, com.star.proto.OutlierAreaTool.AREA_TOOL_TRASH, pt(sx, sy), pt(ex, ey), groupId = g.id)
            val afterTrash = client.listOutliers(info.sessionId, frameIdx).groupsList
            assertTrue(afterTrash.none { it.id == g.id }, "trash did not remove group ${g.id} from the member list")
            assertEquals(before.size - 1, afterTrash.size, "single-group trash changed the member count by more than one (over-trashed)")
            assertTrue(trashed.frame.numTrashOutliers >= 1, "trash count did not rise after dumping a group")

            // EXTRACT: the group returns to the member list and the trash count drops back.
            val extracted = client.applyOutlierAreaTool(info.sessionId, frameIdx, com.star.proto.OutlierAreaTool.AREA_TOOL_EXTRACT_TRASH, pt(sx, sy), pt(ex, ey))
            val afterExtract = client.listOutliers(info.sessionId, frameIdx).groupsList
            assertTrue(extracted.frame.numTrashOutliers < trashed.frame.numTrashOutliers, "extract did not reduce the trash count")
            assertTrue(afterExtract.size > afterTrash.size, "extract did not restore any group to the member list")

            // RAZOR + SHOVEL over a small central area must succeed (return a frame), not break the connection.
            val cx = info.imageWidth / 2.0; val cy = info.imageHeight / 2.0
            val razor = client.applyOutlierAreaTool(info.sessionId, frameIdx, com.star.proto.OutlierAreaTool.AREA_TOOL_RAZOR, pt(cx - 5, cy - 5), pt(cx + 5, cy + 5))
            assertTrue(razor.hasFrame(), "razor returned no frame")
            val shovel = client.applyOutlierAreaTool(info.sessionId, frameIdx, com.star.proto.OutlierAreaTool.AREA_TOOL_SHOVEL, pt(cx - 20, cy - 20), pt(cx + 20, cy + 20))
            assertTrue(shovel.hasFrame(), "shovel returned no frame")

            client.closeSession(info.sessionId)
        }
    }

    /** Open → process(all) → render the sequence; return SHA-256 of each rendered output frame by name. */
    private fun processAndRenderHashes(seqDir: String): Map<String, String> = runBlocking {
        val scope = CoroutineScope(SupervisorJob())
        val engine = EngineState(scope)
        assertTrue(engine.start(), "engine failed to start: ${engine.status.value}")
        try {
            val client = engine.client ?: error("no client after start")
            val cfg = Config.newBuilder(SessionRepository.defaultInitialConfig())
                .setCleanMethod(CleanMethod.CLEAN_AUTOMATIC).build()  // fast path (no per-blob classification)
            val info = client.openSequence(File(seqDir).absolutePath, cfg)

            val done = CompletableDeferred<Unit>()
            val sub = scope.launch {
                runCatching {
                    client.streamProgress(info.sessionId).collect { ev ->
                        if (ev.kindCase == ProgressEvent.KindCase.SEQUENCE_STATE && ev.sequenceState.state == "done") done.complete(Unit)
                    }
                }
            }
            delay(400)
            client.startProcessing(info.sessionId, 0, -1)
            assertTrue(withTimeoutOrNull(1_200_000) { done.await() } != null, "processing timed out")
            sub.cancel()

            client.renderSequence(info.sessionId).collect { } // drain to completion
            val outDir = File(client.getConfig(info.sessionId).outputPath)
            val hashes = hashImagesUnder(outDir)
            client.closeSession(info.sessionId)
            hashes
        } finally {
            engine.shutdown()
        }
    }

    private fun hashImagesUnder(dir: File): Map<String, String> =
        dir.walkTopDown()
            .filter { it.isFile && it.extension.lowercase() in setOf("tif", "tiff", "png", "jpg", "jpeg") }
            .associate { it.name to MessageDigest.getInstance("SHA-256").digest(it.readBytes()).joinToString("") { b -> "%02x".format(b) } }
}
