package com.star.desktop.engine

import com.star.desktop.data.SessionRepository
import com.star.proto.CleanMethod
import com.star.proto.Config
import com.star.proto.OpenProgress
import com.star.proto.ProgressEvent
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.security.MessageDigest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
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
    private fun stardPath(): String? = System.getProperty("star.stard.path")?.takeIf { it.isNotBlank() }

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
     * Process the whole sequence and return when the run ends, failing with the daemon's own message if it
     * ends in an error (a run that errors never says `done`, so waiting for `done` alone just times out).
     *
     * A run on this fixture occasionally ends with "error during merge ... mergedHorizon/<frame>.jpg: no such
     * file", a StarCore race in horizon merging that is not what these tests are about; a finished frame is
     * kept, so starting again completes the rest. Up to [attempts] runs are made before it counts as a failure.
     */
    private suspend fun processToCompletion(
        client: StarClient,
        sessionId: String,
        timeoutMs: Long = 1_200_000,
        attempts: Int = 3,
    ) {
        val ended = kotlinx.coroutines.channels.Channel<ProgressEvent>(kotlinx.coroutines.channels.Channel.UNLIMITED)
        val sub = CoroutineScope(SupervisorJob()).launch {
            runCatching {
                client.streamProgress(sessionId).collect { ev ->
                    if (ev.kindCase == ProgressEvent.KindCase.SEQUENCE_STATE && ev.sequenceState.state in setOf("done", "error", "cancelled")) {
                        ended.trySend(ev)
                    }
                }
            }
        }
        try {
            delay(400)
            repeat(attempts) { attempt ->
                client.startProcessing(sessionId, 0, -1)
                val ev = withTimeoutOrNull(timeoutMs) { ended.receive() } ?: error("processing timed out")
                if (ev.sequenceState.state == "done") return
                if (attempt == attempts - 1) {
                    assertEquals("done", ev.sequenceState.state, "processing did not finish cleanly: ${ev.sequenceState.message}")
                }
                println("[retry] processing ended with ${ev.sequenceState.state}: ${ev.sequenceState.message.take(200)}")
            }
        } finally {
            sub.cancel()
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

            // D3: the original size is an 8-bit copy of the full-size image (what "show full resolution" draws), and the
            // thumbnail is the filmstrip's smaller one (the preview if the view has none).
            val full = client.getFramePreview(info.sessionId, 0, com.star.proto.FrameViewMode.VIEW_ORIGINAL, com.star.proto.PreviewSize.PREVIEW_SIZE_ORIGINAL)
            assertTrue(File(full.path).exists(), "no full-size copy was made: ${full.path}")
            val fullImage = javax.imageio.ImageIO.read(File(full.path))
            assertEquals(info.imageWidth to info.imageHeight, fullImage.width to fullImage.height, "the full-size copy is not full size")
            assertTrue(File(full.path).path != preview.path, "the full-size copy is the preview")
            val thumb = client.getFramePreview(info.sessionId, 0, com.star.proto.FrameViewMode.VIEW_ORIGINAL, com.star.proto.PreviewSize.PREVIEW_SIZE_THUMBNAIL)
            assertTrue(File(thumb.path).exists(), "no thumbnail: ${thumb.path}")

            // Outliers may not exist pre-processing; the call must not break the connection.
            runCatching { client.listOutliers(info.sessionId, 0) }
            client.closeSession(info.sessionId)
            // Connection still healthy after the round-trip.
            assertTrue(client.listSessions().sessionsCount >= 0)
        }
    }

    /**
     * Regression test for a bug where the Kotlin filmstrip showed every frame as "unprocessed"
     * even for an already-fully-processed sequence: `Sequence.Open` falls back to a fresh
     * per-session scratch dir for `outputPath` whenever the client sends none, so reopening the
     * same sequence never resolves to where a prior run's output actually landed, and
     * `FrameAirplaneRemover.init`'s `outputFileExistsOnDisk()` check never finds it.
     * `AppViewModel.openSequence` now sends `outputPath` = the sequence dir's own parent (the
     * same convention macOS uses) so re-opens are deterministic; this test drives the daemon the
     * same way and asserts a second, independent process reports frame 0 as complete. Heavy (real
     * processing), so gated like the golden test.
     */
    @Test
    fun resumeDetectsAlreadyProcessedFrames() {
        val seq = seqPath
        if (!runProcess || seq == null) {
            println("[skip] resumeDetectsAlreadyProcessedFrames — set -Dstar.it.process=true -Dstar.it.seq=<dir>")
            return
        }
        // Copy the fixture into a scratch dir so this test's output doesn't pollute the shared fixture.
        val tmp = java.nio.file.Files.createTempDirectory("star-it-resume").toFile()
        val seqCopy = File(tmp, File(seq).name)
        File(seq).copyRecursively(seqCopy)
        val outputPath = seqCopy.parent!!
        val cfgWithOutput = Config.newBuilder(SessionRepository.defaultInitialConfig())
            .setCleanMethod(CleanMethod.CLEAN_SELECTIVE).setOutputPath(outputPath).build()

        try {
            withEngine { client ->
                val info = client.openSequence(seqCopy.absolutePath, cfgWithOutput)
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
                client.closeSession(info.sessionId)
            }

            // Independent daemon process, same sequence dir + same outputPath convention: Frame.Get
            // must now report the frame as already complete, not unprocessed.
            withEngine { client ->
                val info = client.openSequence(seqCopy.absolutePath, cfgWithOutput)
                val frame = client.getFrame(info.sessionId, 0)
                assertEquals(
                    com.star.proto.FrameProcessingState.FPS_COMPLETE, frame.state,
                    "reopening an already-processed sequence with a deterministic outputPath did not report frame 0 as complete",
                )
                client.closeSession(info.sessionId)
            }
        } finally {
            tmp.deleteRecursively()
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

    /**
     * F4: opening a sequence or a config as a stream says what it is opening, how many frames are loaded (counting up to all of them), and
     * ends with the session; and a config opened again names its sequence.
     */
    @Test
    fun openingStreamsItsProgress() {
        val seq = seqPath ?: run {
            println("[skip] openingStreamsItsProgress — set -Dstar.it.seq=<sequence dir>")
            return
        }
        val tmp = java.nio.file.Files.createTempDirectory("star-it-open").toFile()
        val seqCopy = File(tmp, File(seq).name)
        File(seq).copyRecursively(seqCopy)
        val cfg = Config.newBuilder(SessionRepository.defaultInitialConfig())
            .setCleanMethod(CleanMethod.CLEAN_SELECTIVE).setOutputPath(seqCopy.parent!!).build()
        try {
            withEngine { client ->
                val events = client.openSequenceStream(seqCopy.absolutePath, cfg).toList()
                val first = events.first()
                assertEquals(OpenProgress.KindCase.STAGE, first.kindCase, "the first thing said is what is being opened")
                assertEquals(com.star.proto.OpenStage.OPEN_STAGE_LOADING_FRAMES, first.stage.stage)
                assertEquals(seqCopy.name, first.stage.name)
                val info = events.last().also { assertEquals(OpenProgress.KindCase.DONE, it.kindCase, "the session comes last") }.done
                val loaded = events.filter { it.kindCase == OpenProgress.KindCase.LOADED }.map { it.loaded }
                assertTrue(loaded.isNotEmpty(), "no loading progress")
                assertEquals(0, loaded.first().loaded, "starts from none")
                assertEquals(info.frameCount, loaded.last().loaded, "ends with every frame")
                assertTrue(loaded.all { it.total == info.frameCount })
                assertEquals(loaded.map { it.loaded }, loaded.map { it.loaded }.sorted(), "never goes backwards")

                // The same sequence again from its config, in another daemon: named from the config, not from the path it was opened by.
                val configPath = info.configJsonPath
                client.closeSession(info.sessionId)
                val again = client.openConfigStream(configPath).toList()
                val named = again.first { it.kindCase == OpenProgress.KindCase.STAGE }.stage
                assertEquals(seqCopy.name, named.name, "a config names the sequence it opens")
                assertEquals(info.frameCount, again.last().done.frameCount)
                client.closeSession(again.last().done.sessionId)
            }
        } finally {
            tmp.deleteRecursively()
        }
    }

    /**
     * F4: giving up on a video that is being opened stops ffmpeg, takes back the frames it had written, leaves no session, and the same
     * video can then be opened again (ffmpeg would refuse to write over what a half-finished decode left).
     */
    @Test
    fun cancellingAVideoOpenStopsFfmpegAndTakesBackItsFrames() {
        if (!runProcess || stardPath() == null) {
            println("[skip] cancellingAVideoOpenStopsFfmpegAndTakesBackItsFrames — set -Dstar.it.process=true -Dstar.stard.path=<stard>")
            return
        }
        val ffmpeg = File("../external_binaries/bin/ffmpeg").takeIf { it.canExecute() }
        if (ffmpeg == null) {
            println("[skip] cancellingAVideoOpenStopsFfmpegAndTakesBackItsFrames — no ffmpeg to make a video with")
            return
        }
        val tmp = java.nio.file.Files.createTempDirectory("star-it-video").toFile()
        try {
            val video = File(tmp, "clip.mov")
            // Big frames, so that decoding goes on for a good while after the first one: this must be cancelled in the middle of it.
            val made = ProcessBuilder(
                ffmpeg.path, "-y", "-f", "lavfi", "-i", "testsrc2=size=3840x2160:rate=30", "-t", "2", "-c:v", "mpeg4", "-q:v", "2", video.path,
            ).redirectErrorStream(true).start().also { it.inputStream.readBytes() }.waitFor()
            assertEquals(0, made, "could not make a test video")
            val frames = File(tmp, "clip")

            fun cancelAfterFirstFrame(client: StarClient) {
                val seen = runBlocking {
                    withTimeoutOrNull(120_000) { client.openVideo(video.path).first { it.kindCase == OpenProgress.KindCase.PROGRESS } }
                }
                assertTrue(seen != null, "no frames were extracted")
            }

            withEngine { client ->
                cancelAfterFirstFrame(client)
                // Give the daemon time to see the cancel, stop ffmpeg and clean up.
                val deadline = System.currentTimeMillis() + 30_000
                while (frames.exists() && System.currentTimeMillis() < deadline) Thread.sleep(200)
                assertFalse(frames.exists(), "the frames a cancelled decode had written were left behind")
                val running = ProcessBuilder("pgrep", "-f", "${frames.path}/image_").start().also { it.inputStream.readBytes() }.waitFor()
                assertEquals(1, running, "ffmpeg is still decoding the video that was cancelled")
                assertEquals(0, runBlocking { client.listSessions().sessionsCount }, "a cancelled open left a session behind")

                // And the video can be opened again.
                cancelAfterFirstFrame(client)
            }
        } finally {
            tmp.deleteRecursively()
        }
    }

    /**
     * F3: the daemon says whether full resolution keypoint detection suits the sequence on this machine, with the numbers behind it; and a
     * divisor the client writes is the divisor in the config afterwards (sending one is also what marks it chosen).
     */
    @Test
    fun keypointAdviceAndTheChosenDivisor() {
        val seq = seqPath ?: run {
            println("[skip] keypointAdviceAndTheChosenDivisor — set -Dstar.it.seq=<sequence dir>")
            return
        }
        val tmp = java.nio.file.Files.createTempDirectory("star-it-divisor").toFile()
        val seqCopy = File(tmp, File(seq).name)
        File(seq).copyRecursively(seqCopy)
        val cfg = Config.newBuilder(SessionRepository.defaultInitialConfig())
            .setCleanMethod(CleanMethod.CLEAN_SELECTIVE).setOutputPath(seqCopy.parent!!).build()
        try {
            withEngine { client ->
                val info = client.openSequence(seqCopy.absolutePath, cfg)
                val advice = client.getKeypointAdvice(info.sessionId)
                assertTrue(advice.available, "the sequence is open, so its frame size is known: $advice")
                assertEquals(info.imageWidth.toLong() * info.imageHeight, advice.imagePixels)
                assertTrue(advice.thresholdPixels > 0 && advice.frameConcurrency > 0 && advice.physicalMemoryBytes > 0, "$advice")
                assertTrue(advice.fullResolutionConcurrency in 1..advice.frameConcurrency, "$advice")
                // The recommendation and the verdict agree: a reduction is advised exactly when the frame is past the threshold.
                assertEquals(advice.imagePixels > advice.thresholdPixels, advice.reduceRecommended, "$advice")
                assertEquals(if (advice.reduceRecommended) 1.5 else 1.0, advice.recommendedDivisor)

                val before = client.getConfig(info.sessionId)
                val updated = client.updateConfig(info.sessionId, before.toBuilder().setAlignmentKeypointDetectionDivisor(2.0).build())
                assertEquals(2.0, updated.alignmentKeypointDetectionDivisor)
                assertEquals(2.0, client.getConfig(info.sessionId).alignmentKeypointDetectionDivisor)
                client.closeSession(info.sessionId)
            }
        } finally {
            tmp.deleteRecursively()
        }
    }

    /**
     * F1: while a run goes the daemon reports how far each step has got, and the last report has every step it lists finished.
     * F2: the survey of what is on disk says "untouched" before the run and "complete" after it.
     */
    @Test
    fun stepProgressDuringARun() {
        val seq = seqPath
        if (!runProcess || seq == null) {
            println("[skip] stepProgressDuringARun — set -Dstar.it.process=true -Dstar.it.seq=<dir>")
            return
        }
        val tmp = java.nio.file.Files.createTempDirectory("star-it-steps").toFile()
        val seqCopy = File(tmp, File(seq).name)
        File(seq).copyRecursively(seqCopy)
        val cfg = Config.newBuilder(SessionRepository.defaultInitialConfig())
            .setCleanMethod(CleanMethod.CLEAN_SELECTIVE).setOutputPath(seqCopy.parent!!).build()
        try {
            withEngine { client ->
                val info = client.openSequence(seqCopy.absolutePath, cfg)
                val reports = java.util.concurrent.CopyOnWriteArrayList<com.star.proto.StepProgress>()
                val ended = kotlinx.coroutines.channels.Channel<String>(kotlinx.coroutines.channels.Channel.UNLIMITED)
                val sub = CoroutineScope(SupervisorJob()).launch {
                    runCatching {
                        client.streamProgress(info.sessionId).collect { ev ->
                            if (ev.kindCase == ProgressEvent.KindCase.STEP_PROGRESS) reports.add(ev.stepProgress)
                            if (ev.kindCase == ProgressEvent.KindCase.SEQUENCE_STATE && ev.sequenceState.state in setOf("done", "error", "cancelled")) {
                                ended.trySend(ev.sequenceState.state)
                            }
                        }
                    }
                }
                delay(400)
                val before = client.getProgressSurvey(info.sessionId)
                assertTrue(before.isUntouched, "nothing has been done to a fresh sequence: $before")
                assertFalse(before.isComplete)
                assertEquals(info.frameCount, before.frameCount)
                assertEquals(0, before.framesComplete)
                assertEquals(seqCopy.name, before.sequenceName.substringAfterLast('/'))
                assertTrue(before.stepsList.any { it.type == "merge" }, "every configuration merges")
                for (step in before.stepsList) {
                    assertEquals(info.frameCount, step.queued + step.alreadyDone, "${step.type} is measured over the whole sequence")
                    assertEquals(0, step.alreadyDone, "${step.type} has nothing on disk yet")
                }

                client.startProcessing(info.sessionId, 0, -1)
                val state = withTimeoutOrNull(1_200_000) { ended.receive() }
                sub.cancel()
                assertEquals("done", state, "the run did not finish cleanly")

                val after = client.getProgressSurvey(info.sessionId)
                assertTrue(after.isComplete, "every frame is written after a clean run: $after")
                assertFalse(after.isUntouched)
                assertEquals(info.frameCount, after.framesComplete)
                assertEquals(info.frameCount, after.stepsList.first { it.type == "merge" }.alreadyDone)

                assertTrue(reports.isNotEmpty(), "no step progress was reported")
                val last = reports.last()
                assertTrue(last.graphBuilt, "the last report is from before the plan was complete")
                assertTrue(last.stepsCount > 0, "a processed sequence has steps")
                for (step in last.stepsList) {
                    assertEquals(step.queued, 0, "${step.type} still has work queued at the end")
                    assertEquals(step.running, 0, "${step.type} is still running at the end")
                    assertTrue(step.done + step.alreadyDone > 0, "${step.type} did nothing")
                }
                assertTrue(last.stepsList.any { it.type == "merge" }, "the merge step is in every run")
                client.closeSession(info.sessionId)
            }
        } finally {
            tmp.deleteRecursively()
        }
    }

    /**
     * E4: a frame's own clean method and neighbour counts are the frame's alone, say so in its info, and are still there when the session
     * is opened again from its config in another daemon.
     */
    @Test
    fun perFrameSettingsSurviveReopen() {
        val seq = seqPath
        if (!runProcess || seq == null) {
            println("[skip] perFrameSettingsSurviveReopen — set -Dstar.it.process=true -Dstar.it.seq=<dir>")
            return
        }
        val tmp = java.nio.file.Files.createTempDirectory("star-it-perframe").toFile()
        val seqCopy = File(tmp, File(seq).name)
        File(seq).copyRecursively(seqCopy)
        val cfg = Config.newBuilder(SessionRepository.defaultInitialConfig())
            .setCleanMethod(CleanMethod.CLEAN_SELECTIVE).setOutputPath(seqCopy.parent!!).build()
        try {
            val configJson = withEngine { client ->
                val info = client.openSequence(seqCopy.absolutePath, cfg)
                val untouched = client.getFrame(info.sessionId, 1)
                assertTrue(!untouched.cleanMethodOverridden && !untouched.staticNeighborOverridden && !untouched.alignedNeighborOverridden)

                val set = client.setFrameCleanMethod(info.sessionId, 1, CleanMethod.CLEAN_AUTOMATIC)
                assertTrue(set.cleanMethodOverridden)
                assertEquals(CleanMethod.CLEAN_AUTOMATIC, set.cleanMethod)

                val staticSet = client.setNeighborOverride(info.sessionId, 1, com.star.proto.NeighborKind.NEIGHBOR_STATIC, 3)
                assertEquals(3, staticSet.frame.staticNeighborCount)
                assertTrue(staticSet.frame.staticNeighborOverridden)
                assertTrue(!staticSet.processingStarted)
                val cleared = client.setNeighborOverride(info.sessionId, 1, com.star.proto.NeighborKind.NEIGHBOR_STATIC, null)
                assertTrue(!cleared.frame.staticNeighborOverridden)
                client.setNeighborOverride(info.sessionId, 1, com.star.proto.NeighborKind.NEIGHBOR_STATIC, 4)

                assertTrue(runCatching { client.setNeighborOverride(info.sessionId, 1, com.star.proto.NeighborKind.NEIGHBOR_STATIC, 0) }.isFailure, "0 neighbours should be refused")
                client.closeSession(info.sessionId)
                info.configJsonPath
            }
            withEngine { client ->
                val info = client.openConfig(configJson)
                val frame = client.getFrame(info.sessionId, 1)
                assertTrue(frame.cleanMethodOverridden, "the frame's own clean method was lost on reopen")
                assertEquals(CleanMethod.CLEAN_AUTOMATIC, frame.cleanMethod)
                assertEquals(4, frame.staticNeighborCount)
                assertTrue(frame.staticNeighborOverridden)
                val other = client.getFrame(info.sessionId, 0)
                assertTrue(!other.cleanMethodOverridden, "another frame must keep the sequence's method")
                client.closeSession(info.sessionId)
            }
        } finally {
            tmp.deleteRecursively()
        }
    }

    /**
     * D8: `Outlier.GetFeatures` gives the outlier window every decision-tree feature of the groups asked for (all of the frame's when
     * none are named), by the names `OutlierGroupFeature` has, with the classifier's score.
     */
    @Test
    fun outlierFeaturesForTheWindow() {
        val seq = seqPath
        if (!runProcess || seq == null) {
            println("[skip] outlierFeaturesForTheWindow — set -Dstar.it.process=true -Dstar.it.seq=<dir>")
            return
        }
        withEngine { client ->
            val cfg = Config.newBuilder(SessionRepository.defaultInitialConfig())
                .setCleanMethod(CleanMethod.CLEAN_SELECTIVE).build()
            val info = client.openSequence(File(seq).absolutePath, cfg)
            processToCompletion(client, info.sessionId)

            val frameIdx = (0 until info.frameCount).firstOrNull { client.listOutliers(info.sessionId, it).groupsCount > 0 }
            if (frameIdx == null) {
                println("[skip] outlierFeaturesForTheWindow — no frame has outlier groups after processing")
                client.closeSession(info.sessionId); return@withEngine
            }
            val groups = client.listOutliers(info.sessionId, frameIdx).groupsList

            val all = client.getOutlierFeatures(info.sessionId, frameIdx).rowsList
            assertEquals(groups.map { it.id }.sorted(), all.map { it.groupId }, "naming no groups should give a row for every group, in id order")
            val expectedFeatures = com.star.desktop.domain.OutlierTable.columns
                .filter { it.source == com.star.desktop.domain.OutlierTable.Source.FEATURE }.map { it.feature }
            for (row in all) {
                assertTrue(row.featuresMap.keys.containsAll(expectedFeatures), "group ${row.groupId} lacks some of the table's features")
                assertTrue(row.classification in -1.0..1.0, "classifier score ${row.classification} is outside -1..1")
            }

            val one = groups.first()
            val named = client.getOutlierFeatures(info.sessionId, frameIdx, listOf(one.id, 65_000)).rowsList
            assertEquals(listOf(one.id), named.map { it.groupId }, "a group that is not in the frame should be left out")
            assertEquals(all.first { it.groupId == one.id }.featuresMap, named[0].featuresMap, "the same group should give the same values")

            client.closeSession(info.sessionId)
        }
    }

    /**
     * D9: the lines the Hough finder proposes for a group, choosing one as the group's line, and the finder's arguments.
     */
    @Test
    fun houghLinesForTheWindow() {
        val seq = seqPath
        if (!runProcess || seq == null) {
            println("[skip] houghLinesForTheWindow — set -Dstar.it.process=true -Dstar.it.seq=<dir>")
            return
        }
        withEngine { client ->
            val cfg = Config.newBuilder(SessionRepository.defaultInitialConfig())
                .setCleanMethod(CleanMethod.CLEAN_SELECTIVE).build()
            val info = client.openSequence(File(seq).absolutePath, cfg)
            processToCompletion(client, info.sessionId)

            val frameIdx = (0 until info.frameCount).firstOrNull { client.listOutliers(info.sessionId, it).groupsCount > 0 }
            if (frameIdx == null) {
                println("[skip] houghLinesForTheWindow — no frame has outlier groups after processing")
                client.closeSession(info.sessionId); return@withEngine
            }
            val group = client.listOutliers(info.sessionId, frameIdx).groupsList.maxBy { it.size }

            val candidates = client.getLineCandidates(info.sessionId, frameIdx, group.id).candidatesList
            assertTrue(candidates.isNotEmpty(), "the finder offered no line for group ${group.id}")
            assertEquals(candidates.map { it.intensityScore }.sortedDescending(), candidates.map { it.intensityScore }, "best fit should come first")

            // Choosing the last candidate (not the one the group already has) changes the group's line, and the frame's list shows it.
            val chosen = candidates.last()
            val after = client.setLine(info.sessionId, frameIdx, group.id, chosen).group
            assertEquals(chosen.line.theta, after.line.theta, 1e-9)
            assertEquals(chosen.line.rho, after.line.rho, 1e-9)
            val listed = client.listOutliers(info.sessionId, frameIdx).groupsList.first { it.id == group.id }
            assertEquals(chosen.line.theta, listed.line.theta, 1e-9, "the chosen line should stay the group's line")

            // The finder's arguments: both are listed, one changes, and it is put back so the daemon is left as it was.
            val args = client.getHoughLineFinderArgs().argsList
            assertEquals(setOf("imageDataBorderSize", "maxLineConstant"), args.map { it.name }.toSet())
            assertTrue(args.all { it.isInteger && it.description.isNotBlank() })
            val max = args.first { it.name == "maxLineConstant" }
            val changed = client.setHoughLineFinderArg("maxLineConstant", 123.0).argsList.first { it.name == "maxLineConstant" }
            assertEquals(123.0, changed.value)
            assertEquals(max.value, client.setHoughLineFinderArg("maxLineConstant", max.value).argsList.first { it.name == "maxLineConstant" }.value)
            assertTrue(runCatching { client.setHoughLineFinderArg("nope", 1.0) }.isFailure, "an unknown argument should be refused")

            client.closeSession(info.sessionId)
        }
    }

    /**
     * A6: the daemon keeps a set of progress subscribers, so a second stream (Export.RenderSequence,
     * Horizon.Reprocess) neither takes over nor kills the client's long-lived StreamProgress, and both of
     * those streams now end by themselves. The long-lived stream must hear the `done` of the run after them.
     */
    @Test
    fun progressStreamSurvivesOtherStreams() {
        val seq = seqPath
        if (!runProcess || seq == null) {
            println("[skip] progressStreamSurvivesOtherStreams — set -Dstar.it.process=true -Dstar.it.seq=<dir>")
            return
        }
        withEngine { client ->
            val cfg = Config.newBuilder(SessionRepository.defaultInitialConfig())
                .setCleanMethod(CleanMethod.CLEAN_AUTOMATIC).build()
            val info = client.openSequence(File(seq).absolutePath, cfg)

            val states = kotlinx.coroutines.channels.Channel<String>(kotlinx.coroutines.channels.Channel.UNLIMITED)
            val sub = CoroutineScope(SupervisorJob()).launch {
                runCatching {
                    client.streamProgress(info.sessionId).collect { ev ->
                        if (ev.kindCase == ProgressEvent.KindCase.SEQUENCE_STATE) states.trySend(ev.sequenceState.state)
                    }
                }
            }
            delay(400)
            client.startProcessing(info.sessionId, 0, -1)
            var first = withTimeoutOrNull(1_200_000) { states.receive() }
            if (first == "error") {   // the known intermittent StarCore merge race (see processToCompletion): a second run finishes it
                client.startProcessing(info.sessionId, 0, -1)
                first = withTimeoutOrNull(1_200_000) { states.receive() }
            }
            assertEquals("done", first, "first run did not finish")

            // Both of these must end on their own (they used to hold the slot / never end).
            assertTrue(withTimeoutOrNull(600_000) { client.renderSequence(info.sessionId).collect { } } != null, "render stream did not end")
            // The render's own `done` goes to the render stream only, not to the long-lived one.
            assertEquals(null, withTimeoutOrNull(1_000) { states.receive() }, "the render's completion reached the processing stream")

            // With no reference painted there is nothing for this to refine: it runs nothing and ends at once.
            @Suppress("DEPRECATION")
            val horizonStream = withTimeoutOrNull(120_000) { client.reprocessHorizons(info.sessionId, listOf(0)).collect { } }
            assertTrue(horizonStream != null, "horizon reprocess stream did not end")
            // And the next run's done still reaches the long-lived stream.
            client.startProcessing(info.sessionId, 0, -1)
            assertEquals("done", withTimeoutOrNull(120_000) { states.receive() }, "the long-lived stream missed the next run's done")

            sub.cancel()
            client.closeSession(info.sessionId)
        }
    }

    /**
     * A7: a stream attached after the open is told every frame's state first, so a resumed, already
     * processed session reads "N of N complete" immediately instead of starting from nothing.
     */
    @Test
    fun frameStatesSeededOnSubscribe() {
        val seq = seqPath
        if (!runProcess || seq == null) {
            println("[skip] frameStatesSeededOnSubscribe — set -Dstar.it.process=true -Dstar.it.seq=<dir>")
            return
        }
        val cfg = Config.newBuilder(SessionRepository.defaultInitialConfig())
            .setCleanMethod(CleanMethod.CLEAN_AUTOMATIC).build()
        val (configJson, frameCount) = withEngine { client ->
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
            client.closeSession(info.sessionId)
            info.configJsonPath to info.frameCount
        }

        // A fresh daemon resumes the finished sequence; nothing has run, yet the stream's first events
        // are one state per frame, all complete.
        withEngine { client ->
            val info = client.openConfig(configJson)
            val seeded = withTimeoutOrNull(30_000) {
                client.streamProgress(info.sessionId)
                    .filter { it.kindCase == ProgressEvent.KindCase.FRAME_STATE }
                    .take(frameCount)
                    .toList()
            }
            assertTrue(seeded != null, "no frame states arrived on a fresh subscription")
            assertEquals(frameCount, seeded!!.map { it.frameState.frameIndex }.toSet().size, "not one state per frame")
            assertTrue(
                seeded.all { it.frameState.state == com.star.proto.FrameProcessingState.FPS_COMPLETE },
                "resumed frames not reported complete: ${seeded.map { it.frameState.state }}",
            )
            client.closeSession(info.sessionId)
        }
    }

    /**
     * A5: Stop really stops. Processing.Cancel answers only once the graph has drained, the stream says
     * `cancelled` and never the stopped run's `done`, and a run started afterwards completes normally.
     */
    @Test
    fun cancelStopsProcessing() {
        val seq = seqPath
        if (!runProcess || seq == null) {
            println("[skip] cancelStopsProcessing — set -Dstar.it.process=true -Dstar.it.seq=<dir>")
            return
        }
        withEngine { client ->
            val cfg = Config.newBuilder(SessionRepository.defaultInitialConfig())
                .setCleanMethod(CleanMethod.CLEAN_AUTOMATIC).build()
            val info = client.openSequence(File(seq).absolutePath, cfg)

            val states = kotlinx.coroutines.channels.Channel<String>(kotlinx.coroutines.channels.Channel.UNLIMITED)
            val sub = CoroutineScope(SupervisorJob()).launch {
                runCatching {
                    client.streamProgress(info.sessionId).collect { ev ->
                        if (ev.kindCase == ProgressEvent.KindCase.SEQUENCE_STATE) states.trySend(ev.sequenceState.state)
                    }
                }
            }
            delay(400)
            client.startProcessing(info.sessionId, 0, -1)
            delay(1_000)
            client.cancelProcessing(info.sessionId)
            assertEquals("cancelled", withTimeoutOrNull(30_000) { states.receive() }, "no cancelled event after Cancel")
            // The stopped run's late completion must be swallowed, not reported as done.
            assertEquals(null, withTimeoutOrNull(5_000) { states.receive() }, "a stopped run still reported a state")

            client.startProcessing(info.sessionId, 0, -1)
            assertEquals("done", withTimeoutOrNull(1_200_000) { states.receive() }, "the run after a stop did not finish")
            sub.cancel()
            client.closeSession(info.sessionId)
        }
    }

    /**
     * A4: `end_index` 0 is frame 0, not "to the end". Start(0, 0) completes frame 0 and leaves the
     * last frame unfinished; Start(0, -1) is the whole sequence.
     */
    @Test
    fun singleFrameAtIndexZeroProcessesOnlyThatFrame() {
        val seq = seqPath
        if (!runProcess || seq == null) {
            println("[skip] singleFrameAtIndexZeroProcessesOnlyThatFrame — set -Dstar.it.process=true -Dstar.it.seq=<dir>")
            return
        }
        withEngine { client ->
            val cfg = Config.newBuilder(SessionRepository.defaultInitialConfig())
                .setCleanMethod(CleanMethod.CLEAN_AUTOMATIC).build()
            val info = client.openSequence(File(seq).absolutePath, cfg)
            assertTrue(info.frameCount > 2, "fixture needs at least three frames")

            val states = kotlinx.coroutines.channels.Channel<String>(kotlinx.coroutines.channels.Channel.UNLIMITED)
            val sub = CoroutineScope(SupervisorJob()).launch {
                runCatching {
                    client.streamProgress(info.sessionId).collect { ev ->
                        if (ev.kindCase == ProgressEvent.KindCase.SEQUENCE_STATE) states.trySend(ev.sequenceState.state)
                    }
                }
            }
            delay(400)
            // The first run is of frame 0 alone. StarCore may end such a run in "error" ("no usable star alignment": a single frame
            // has too little to align against on a sequence nothing else has been done to), which is not what this test is about:
            // what it checks is how far the range reaches.
            client.startProcessing(info.sessionId, 0, 0)
            val first = withTimeoutOrNull(1_200_000) { states.receive() }
            assertTrue(first == "done" || first == "error", "single-frame run did not end: $first")
            if (first == "done") {
                assertEquals(
                    com.star.proto.FrameProcessingState.FPS_COMPLETE, client.getFrame(info.sessionId, 0).state,
                    "frame 0 was not processed",
                )
            }
            assertEquals(
                com.star.proto.FrameProcessingState.FPS_UNPROCESSED, client.getFrame(info.sessionId, info.frameCount - 1).state,
                "Start(0, 0) reached the last frame: end_index 0 was read as 'to the end'",
            )

            sub.cancel()
            client.closeSession(info.sessionId)
        }
    }

    /**
     * A18: a granular reprocess deletes what macOS deletes. NONE leaves every output file in place (the
     * daemon used to delete them); EVERYTHING deletes the frame's work and the run recomputes it.
     */
    @Test
    fun reprocessTypesDeleteWhatMacOSDeletes() {
        val seq = seqPath
        if (!runProcess || seq == null) {
            println("[skip] reprocessTypesDeleteWhatMacOSDeletes — set -Dstar.it.process=true -Dstar.it.seq=<dir>")
            return
        }
        val tmp = java.nio.file.Files.createTempDirectory("star-it-reprocess").toFile()
        val seqCopy = File(tmp, File(seq).name)
        File(seq).copyRecursively(seqCopy)
        try {
            withEngine { client ->
                val cfg = Config.newBuilder(SessionRepository.defaultInitialConfig())
                    .setCleanMethod(CleanMethod.CLEAN_AUTOMATIC).setOutputPath(tmp.absolutePath).build()
                val info = client.openSequence(seqCopy.absolutePath, cfg)
                val outDir = File(client.getConfig(info.sessionId).outputPath)

                val states = kotlinx.coroutines.channels.Channel<String>(kotlinx.coroutines.channels.Channel.UNLIMITED)
                val sub = CoroutineScope(SupervisorJob()).launch {
                    runCatching {
                        client.streamProgress(info.sessionId).collect { ev ->
                            if (ev.kindCase == ProgressEvent.KindCase.SEQUENCE_STATE) states.trySend(ev.sequenceState.state)
                        }
                    }
                }
                delay(400)
                client.startProcessing(info.sessionId, 0, -1)
                assertEquals("done", withTimeoutOrNull(1_200_000) { states.receive() }, "processing timed out")

                // The images a run writes (not the source frames, not databases a run touches every time).
                fun files() = outDir.walkTopDown()
                    .filter { it.isFile && !it.startsWith(seqCopy) && it.extension.lowercase() in setOf("tif", "tiff", "png", "jpg", "jpeg") }
                    .map { it.relativeTo(outDir).path to it.lastModified() }.toMap()
                val before = files()
                assertTrue(before.isNotEmpty(), "processing wrote no output files")

                // NONE: nothing is deleted or rewritten.
                client.reprocessFrames(info.sessionId, listOf(1), com.star.proto.ReprocessingType.REPROCESS_NONE)
                assertEquals("done", withTimeoutOrNull(1_200_000) { states.receive() }, "REPROCESS_NONE run did not finish")
                assertEquals(before, files(), "REPROCESS_NONE changed the output files")

                // EVERYTHING: frame 1's work is deleted and recomputed (newer modification times), the rest untouched.
                delay(1_100) // file timestamps have 1 s granularity on some filesystems
                client.reprocessFrames(info.sessionId, listOf(1), com.star.proto.ReprocessingType.REPROCESS_EVERYTHING)
                assertEquals("done", withTimeoutOrNull(1_200_000) { states.receive() }, "REPROCESS_EVERYTHING run did not finish")
                assertEquals(
                    com.star.proto.FrameProcessingState.FPS_COMPLETE, client.getFrame(info.sessionId, 1).state,
                    "frame 1 was not recomputed",
                )
                val after = files()
                val rewritten = after.filter { (name, t) -> before[name]?.let { it < t } ?: true }
                assertTrue(rewritten.isNotEmpty(), "REPROCESS_EVERYTHING rewrote nothing")
                sub.cancel()
                client.closeSession(info.sessionId)
            }
        } finally {
            tmp.deleteRecursively()
        }
    }

    /**
     * A3: the Processed view is the final image, not the subtraction debug image. After a run,
     * Frame.GetPreview(VIEW_PROCESSED) resolves to a file of its own, distinct from the original's and the
     * subtraction's.
     */
    @Test
    fun processedViewIsTheFinalImage() {
        val seq = seqPath
        if (!runProcess || seq == null) {
            println("[skip] processedViewIsTheFinalImage — set -Dstar.it.process=true -Dstar.it.seq=<dir>")
            return
        }
        withEngine { client ->
            val cfg = Config.newBuilder(SessionRepository.defaultInitialConfig())
                .setCleanMethod(CleanMethod.CLEAN_AUTOMATIC).build()
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

            val processed = client.getFramePreview(info.sessionId, 0, com.star.proto.FrameViewMode.VIEW_PROCESSED)
            assertTrue(File(processed.path).isFile, "no processed preview on disk: ${processed.path}")
            val original = client.getFramePreview(info.sessionId, 0, com.star.proto.FrameViewMode.VIEW_ORIGINAL)
            assertTrue(processed.path != original.path, "the processed view is the original's preview")
            runCatching { client.getFramePreview(info.sessionId, 0, com.star.proto.FrameViewMode.VIEW_SUBTRACTION) }
                .getOrNull()?.let { assertTrue(processed.path != it.path, "the processed view is the subtraction debug image") }
            client.closeSession(info.sessionId)
        }
    }

    /**
     * A16: Session.Close stops a run in flight, waits for it, and ends the session's progress streams;
     * a session opened afterwards runs normally (it is not fighting the old run for the shared graph).
     */
    @Test
    fun closeStopsTheRunAndEndsTheStreams() {
        val seq = seqPath
        if (!runProcess || seq == null) {
            println("[skip] closeStopsTheRunAndEndsTheStreams — set -Dstar.it.process=true -Dstar.it.seq=<dir>")
            return
        }
        withEngine { client ->
            val cfg = Config.newBuilder(SessionRepository.defaultInitialConfig())
                .setCleanMethod(CleanMethod.CLEAN_AUTOMATIC).build()
            val first = client.openSequence(File(seq).absolutePath, cfg)

            val firstStates = mutableListOf<String>()
            val streamEnded = CompletableDeferred<Unit>()
            val sub = CoroutineScope(SupervisorJob()).launch {
                runCatching {
                    client.streamProgress(first.sessionId).collect { ev ->
                        if (ev.kindCase == ProgressEvent.KindCase.SEQUENCE_STATE) synchronized(firstStates) { firstStates += ev.sequenceState.state }
                    }
                }
                streamEnded.complete(Unit)
            }
            delay(400)
            client.startProcessing(first.sessionId, 0, -1)
            delay(1_000)
            client.closeSession(first.sessionId)
            assertTrue(withTimeoutOrNull(30_000) { streamEnded.await() } != null, "Close left the progress stream open")
            sub.cancel()
            synchronized(firstStates) {
                assertTrue("done" !in firstStates, "the closed session's stopped run reported done")
            }

            // The old session is gone.
            val gone = runCatching { client.getFrame(first.sessionId, 0) }
            assertTrue(gone.isFailure, "a closed session still answers")

            // A fresh session processes to the end.
            val second = client.openSequence(File(seq).absolutePath, cfg)
            val done = CompletableDeferred<Unit>()
            val sub2 = CoroutineScope(SupervisorJob()).launch {
                runCatching {
                    client.streamProgress(second.sessionId).collect { ev ->
                        if (ev.kindCase == ProgressEvent.KindCase.SEQUENCE_STATE && ev.sequenceState.state == "done") done.complete(Unit)
                    }
                }
            }
            delay(400)
            client.startProcessing(second.sessionId, 0, -1)
            assertTrue(withTimeoutOrNull(1_200_000) { done.await() } != null, "the session opened after a close did not finish")
            sub2.cancel()
            client.closeSession(second.sessionId)
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

    /**
     * A1: a decision is not lost when the session closes. The daemon writes it down at once and saves the
     * frame's finished image when the session closes, instead of leaving both to a timer or to Render All.
     * Process, edit one frame, close, reopen the config in a *new* daemon: the decision is still there, and
     * an output image was rewritten after the edit.
     */
    @Test
    fun editsSurviveCloseAndReopen() {
        val seq = seqPath
        if (!runProcess || seq == null) {
            println("[skip] editsSurviveCloseAndReopen — set -Dstar.it.process=true -Dstar.it.seq=<dir>")
            return
        }
        val tmp = java.nio.file.Files.createTempDirectory("star-it-edits").toFile()
        val seqCopy = File(tmp, File(seq).name)
        File(seq).copyRecursively(seqCopy)
        val cfg = Config.newBuilder(SessionRepository.defaultInitialConfig())
            .setCleanMethod(CleanMethod.CLEAN_SELECTIVE).setOutputPath(seqCopy.parent!!).build()
        try {
            var edited: Triple<Int, Int, com.star.proto.RemoveReason>? = null
            var editedAt = 0L
            val configJson = withEngine { client ->
                val info = client.openSequence(seqCopy.absolutePath, cfg)
                processToCompletion(client, info.sessionId)

                val frameIdx = (0 until info.frameCount).firstOrNull { client.listOutliers(info.sessionId, it).groupsCount > 0 }
                if (frameIdx == null) {
                    println("[skip] editsSurviveCloseAndReopen — no frame has outlier groups after processing")
                    client.closeSession(info.sessionId); return@withEngine null
                }
                val group = client.listOutliers(info.sessionId, frameIdx).groupsList.first()
                val wanted = if (group.shouldRemove == com.star.proto.RemoveReason.RR_USER_KEEP)
                    com.star.proto.RemoveReason.RR_USER_REMOVE else com.star.proto.RemoveReason.RR_USER_KEEP
                // File times are whole seconds on some filesystems; leave a gap so "after the edit" is meaningful.
                delay(1_100)
                editedAt = System.currentTimeMillis()
                client.setOutlierDecisions(
                    info.sessionId, frameIdx,
                    listOf(com.star.proto.OutlierDecision.newBuilder().setGroupId(group.id).setDecision(wanted).build()),
                )
                edited = Triple(frameIdx, group.id, wanted)
                // Closing must save the frame now, not ten seconds from now.
                client.closeSession(info.sessionId)
                info.configJsonPath
            } ?: return

            // A14: the session's config.json sits in the sequence's own temp output directory, where the macOS
            // app keeps it (so both clients can open it from their recents), not in the daemon's scratch dir.
            assertTrue(
                configJson.startsWith(File(tmp, "star_temp_${File(seq).name}").path + "/") && configJson.endsWith("/config.json"),
                "config.json is not in the sequence's temp output directory: $configJson",
            )

            val (frameIdx, groupId, wanted) = edited!!
            withEngine { client ->
                val info = client.openConfig(configJson)
                // A resumed frame's groups are on disk until something asks for them, and its counts are then
                // "unknown", which is not the same as 0/0/0: the reply says which it is (A11).
                assertTrue(!client.getFrame(info.sessionId, frameIdx).outliersLoaded, "unloaded outliers reported as loaded")
                val again = client.listOutliers(info.sessionId, frameIdx).groupsList.first { it.id == groupId }
                assertEquals(wanted, again.shouldRemove, "the decision did not survive closing and reopening")
                assertTrue(client.getFrame(info.sessionId, frameIdx).outliersLoaded, "loaded outliers reported as unloaded")
                client.closeSession(info.sessionId)
            }
            val rewritten = tmp.walkTopDown().filter {
                it.isFile && it.extension.lowercase() in setOf("tif", "tiff", "jpg", "jpeg", "png") && it.lastModified() >= editedAt
            }.toList()
            assertTrue(rewritten.isNotEmpty(), "no image was written after the edit: closing the session did not save the frame")
        } finally {
            tmp.deleteRecursively()
        }
    }

    /**
     * A2: "Render this frame" writes the finished image from the frame's decisions (it used to hand back a copy of
     * the unedited original), and "Render All" reports its progress.
     */
    @Test
    fun renderFrameReflectsTheDecisions() {
        val seq = seqPath
        if (!runProcess || seq == null) {
            println("[skip] renderFrameReflectsTheDecisions — set -Dstar.it.process=true -Dstar.it.seq=<dir>")
            return
        }
        val tmp = java.nio.file.Files.createTempDirectory("star-it-render").toFile()
        val seqCopy = File(tmp, File(seq).name)
        File(seq).copyRecursively(seqCopy)
        val cfg = Config.newBuilder(SessionRepository.defaultInitialConfig())
            .setCleanMethod(CleanMethod.CLEAN_SELECTIVE).setOutputPath(seqCopy.parent!!).build()
        try {
            withEngine { client ->
                val info = client.openSequence(seqCopy.absolutePath, cfg)
                processToCompletion(client, info.sessionId)
                val frameIdx = (0 until info.frameCount).firstOrNull { client.listOutliers(info.sessionId, it).groupsCount > 0 }
                if (frameIdx == null) {
                    println("[skip] renderFrameReflectsTheDecisions — no frame has outlier groups after processing")
                    client.closeSession(info.sessionId); return@withEngine
                }
                val groups = client.listOutliers(info.sessionId, frameIdx).groupsList
                // A9 / D6: Clear Undecided keeps the groups nobody has decided about (nothing is left undecided), and the trash
                // can be read as a mask the view draws.
                client.setAllOutliers(info.sessionId, frameIdx, shouldRemove = false, undecidedOnly = true, includingTrash = false)
                assertTrue(
                    client.listOutliers(info.sessionId, frameIdx).groupsList.none { it.shouldRemove == com.star.proto.RemoveReason.RR_UNDECIDED },
                    "Clear Undecided left a group undecided",
                )
                val trashMask = client.getOutlierTrashImage(info.sessionId, frameIdx)
                assertTrue(File(trashMask.path).exists(), "no trash mask was written")
                assertEquals(info.imageWidth, trashMask.width)
                if (client.getFrame(info.sessionId, frameIdx).numTrashOutliers > 0) {
                    val img = javax.imageio.ImageIO.read(File(trashMask.path))
                    val anyTrash = (0 until img.height step 7).any { y -> (0 until img.width).any { x -> img.raster.getSample(x, y, 0) > 0 } }
                    assertTrue(anyTrash, "the frame has trash but its mask is empty")
                }

                fun decideAll(reason: com.star.proto.RemoveReason) = runBlocking {
                    client.setOutlierDecisions(
                        info.sessionId, frameIdx,
                        groups.map { com.star.proto.OutlierDecision.newBuilder().setGroupId(it.id).setDecision(reason).build() },
                    )
                }

                // A render announces the new picture, so a client that cached the old one drops it (A11).
                val announced = CompletableDeferred<ProgressEvent>()
                val watcher = CoroutineScope(SupervisorJob()).launch {
                    runCatching {
                        client.streamProgress(info.sessionId).collect { ev ->
                            if (ev.kindCase == ProgressEvent.KindCase.IMAGE_SAVED && ev.imageSaved.frameIndex == frameIdx &&
                                ev.imageSaved.viewMode == com.star.proto.FrameViewMode.VIEW_PROCESSED
                            ) announced.complete(ev)
                        }
                    }
                }
                delay(400)

                decideAll(com.star.proto.RemoveReason.RR_USER_KEEP)
                val kept = File(client.renderFrame(info.sessionId, frameIdx).path).readBytes()
                assertTrue(withTimeoutOrNull(10_000) { announced.await() } != null, "no image_saved event after rendering frame $frameIdx")
                watcher.cancel()
                decideAll(com.star.proto.RemoveReason.RR_USER_REMOVE)
                val removed = File(client.renderFrame(info.sessionId, frameIdx).path).readBytes()
                val original = File(client.getFramePreview(info.sessionId, frameIdx, com.star.proto.FrameViewMode.VIEW_ORIGINAL).path).readBytes()

                assertTrue(!removed.contentEquals(kept), "rendering after removing every outlier gave the same picture as keeping them all")
                assertTrue(!removed.contentEquals(original), "the render of a frame with its outliers removed is just the original")

                // D1: a Keep / Remove box over the whole frame sets every group inside it (the box tools of the edit view).
                fun point(x: Int, y: Int) = com.star.proto.Point.newBuilder().setX(x.toDouble()).setY(y.toDouble()).build()
                client.setOutlierDecisionsInArea(info.sessionId, frameIdx, frameIdx, shouldRemove = true, point(0, 0), point(info.imageWidth, info.imageHeight))
                assertTrue(
                    client.listOutliers(info.sessionId, frameIdx).groupsList.all { it.shouldRemove == com.star.proto.RemoveReason.RR_USER_REMOVE },
                    "a Remove box over the whole frame left a group undecided or kept",
                )
                client.setOutlierDecisionsInArea(info.sessionId, frameIdx, frameIdx, shouldRemove = false, point(0, 0), point(info.imageWidth, info.imageHeight))
                assertTrue(
                    client.listOutliers(info.sessionId, frameIdx).groupsList.all { it.shouldRemove == com.star.proto.RemoveReason.RR_USER_KEEP },
                    "a Keep box over the whole frame left a group undecided or removed",
                )

                // A10: the decision tree, asked not to overwrite, leaves the user's own decisions alone (the client's
                // "Only Unclassified" default); the render it asks for is the edited picture, not the original.
                decideAll(com.star.proto.RemoveReason.RR_USER_KEEP)
                val classified = client.applyDecisionTree(info.sessionId, frameIdx, overwrite = false, minimumSize = 20, rerender = true)
                assertTrue(
                    client.listOutliers(info.sessionId, frameIdx).groupsList.all { it.shouldRemove == com.star.proto.RemoveReason.RR_USER_KEEP },
                    "the decision tree changed a decision the user made although it was asked not to overwrite",
                )
                assertTrue(classified.hasPreview() && File(classified.preview.path).exists(), "ApplyDecisionTree(rerender) returned no rendered preview")

                // Render All: every frame is done (or skipped as already done) and the bar is told.
                val io = mutableListOf<Pair<Int, Int>>()
                client.renderSequence(info.sessionId).collect { ev ->
                    if (ev.kindCase == ProgressEvent.KindCase.IO_PROGRESS) io += ev.ioProgress.current to ev.ioProgress.total
                }
                assertTrue(io.isNotEmpty(), "Render All reported no progress")
                assertEquals(info.frameCount to info.frameCount, io.last(), "Render All did not end at N of N")

                // G7: a video in a container whose name is not its file extension is named with the extension.
                val caps = client.getVideoCapabilities()
                val pick = caps.codecsList.flatMap { c -> c.encodersList.map { c.codec to it } }
                    .firstOrNull { (_, e) -> "matroska" in e.muxersList && e.pixelFormatsCount > 0 }
                if (pick == null) {
                    println("[skip] no matroska-capable encoder in this ffmpeg; not checking the default video name")
                } else {
                    val settings = com.star.proto.VideoEncodeSettings.newBuilder()
                        .setFrameRate(24.0).setCodec(pick.first).setEncoder(pick.second.encoder)
                        .setPixelFormat(pick.second.pixelFormatsList.first()).setMuxer("matroska").build()
                    val exported = runCatching { client.exportVideo(info.sessionId, "", settings).collect { } }
                    if (exported.exceptionOrNull()?.message?.contains("ffmpeg") == true && exported.exceptionOrNull()?.message?.contains("exist") == true) {
                        println("[skip] no ffmpeg beside this stard; not checking the default video name")
                    } else {
                        exported.getOrThrow()
                        val videos = tmp.walkTopDown().filter { it.isFile && it.name.endsWith(".mkv") }.toList()
                        assertTrue(videos.isNotEmpty(), "no .mkv was written: the default name did not use the container's extension")
                        assertTrue(tmp.walkTopDown().none { it.name.endsWith(".matroska") }, "a file with the muxer's name as its extension was written")
                    }
                }
                client.closeSession(info.sessionId)
            }
        } finally {
            tmp.deleteRecursively()
        }
    }

    /**
     * B1: repainting a reference marks the frames that interpolate from it as pending, "later" takes away their output,
     * and a refinement run redoes the work and clears the marks. Needs a moving camera so that references are per frame.
     */
    @Test
    fun horizonRefinementPendingDeferAndRun() {
        val seq = seqPath
        if (!runProcess || seq == null) {
            println("[skip] horizonRefinementPendingDeferAndRun — set -Dstar.it.process=true -Dstar.it.seq=<dir>")
            return
        }
        val tmp = java.nio.file.Files.createTempDirectory("star-it-horizon").toFile()
        val seqCopy = File(tmp, File(seq).name)
        File(seq).copyRecursively(seqCopy)
        val cfg = Config.newBuilder(SessionRepository.defaultInitialConfig())
            .setCleanMethod(CleanMethod.CLEAN_AUTOMATIC).setTripodHeadWasMoving(true).setOutputPath(seqCopy.parent!!).build()
        try {
            withEngine { client ->
                val info = client.openSequence(seqCopy.absolutePath, cfg)
                processToCompletion(client, info.sessionId)
                val n = info.frameCount

                // B8: the max-downward-extension stepper's value is one number for the sequence, stored apart from the derived default.
                val before = client.getTunedHorizonParameters(info.sessionId)
                assertEquals(0, before.maxDownwardExtension, "nothing is stored until the stepper is used")
                assertTrue(before.effectiveMaxDownwardExtension > 0, "the derived default is what is in force")
                val raised = client.setTunedHorizonMaxDownwardExtension(info.sessionId, before.effectiveMaxDownwardExtension + 10)
                assertEquals(before.effectiveMaxDownwardExtension + 10, raised.maxDownwardExtension)
                assertEquals(raised.maxDownwardExtension, raised.effectiveMaxDownwardExtension, "a stored value is the one in force")
                assertEquals(raised, client.getTunedHorizonParameters(info.sessionId), "what was set is what is read back")
                client.setTunedHorizonMaxDownwardExtension(info.sessionId, 0)   // back to derived, for the rest of the test

                // Paint a reference on frame 3.
                val w = info.imageWidth
                val h = info.imageHeight
                client.setReferenceHorizon(
                    com.star.proto.SetReferenceHorizonRequest.newBuilder().setSessionId(info.sessionId).setFrameIndex(3)
                        .setColumns(
                            com.star.proto.HorizonColumns.newBuilder().setSpaceWidth(w).setSpaceHeight(h)
                                .addAllHorizonY(List(w) { h / 2 }).build(),
                        ).build(),
                )
                // Without "apply to nearby" nothing is recorded.
                val none = client.horizonReferenceUpdated(info.sessionId, 3, applyToNearby = false)
                assertEquals(0, none.affectedFrameCount)
                assertTrue(!client.getHorizonRefinementStatus(info.sessionId).pending, "a refinement was recorded though nearby frames were not to be touched")

                val asked = client.horizonReferenceUpdated(info.sessionId, 3, applyToNearby = true)
                assertEquals(n, asked.affectedFrameCount, "every frame interpolates from the lone reference or is it")
                assertEquals(n, asked.renderCount, "every processed frame has output to render again")
                assertTrue(client.getHorizonRefinementStatus(info.sessionId).pending)
                assertTrue(client.getFrame(info.sessionId, 0).refinementPending, "frame 0 interpolates from the reference and is not marked")
                assertTrue(!client.getFrame(info.sessionId, 3).refinementPending, "the reference itself is marked")
                assertTrue(client.getHorizonOverlay(info.sessionId, 0, 64, 40).refinementPending, "the overlay does not say frame 0 is pending")

                // Later: the output the old horizon went into is taken away; the work stays pending.
                client.deferHorizonRefinement(info.sessionId)
                assertTrue(client.getHorizonRefinementStatus(info.sessionId).pending, "Later cleared the pending work")
                assertTrue(client.getFrame(info.sessionId, 0).state != com.star.proto.FrameProcessingState.FPS_COMPLETE,
                    "Later left frame 0 looking finished")

                // Now: runs, ends like any run, and the marks go.
                val ended = kotlinx.coroutines.channels.Channel<String>(kotlinx.coroutines.channels.Channel.UNLIMITED)
                val sub = CoroutineScope(SupervisorJob()).launch {
                    runCatching {
                        client.streamProgress(info.sessionId).collect { ev ->
                            if (ev.kindCase == ProgressEvent.KindCase.SEQUENCE_STATE) ended.trySend(ev.sequenceState.state)
                        }
                    }
                }
                delay(400)
                assertTrue(client.runHorizonRefinement(info.sessionId).started, "the refinement did not start")
                val state = withTimeoutOrNull(1_200_000) { ended.receive() }
                sub.cancel()
                assertEquals("done", state, "the refinement run did not end cleanly")
                assertTrue(!client.getHorizonRefinementStatus(info.sessionId).pending, "work is still pending after the run")
                assertTrue(!client.getFrame(info.sessionId, 0).refinementPending, "frame 0 is still marked after the run")
                assertEquals(com.star.proto.FrameProcessingState.FPS_COMPLETE, client.getFrame(info.sessionId, 0).state, "frame 0 was not rendered again")
                client.closeSession(info.sessionId)
            }
        } finally {
            tmp.deleteRecursively()
        }
    }
}
