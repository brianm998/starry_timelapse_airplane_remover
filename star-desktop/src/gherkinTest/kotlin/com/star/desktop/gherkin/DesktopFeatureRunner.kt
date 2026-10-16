package com.star.desktop.gherkin

import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ComposeTimeoutException
import androidx.compose.ui.test.ComposeUiTest
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.printToString
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.runDesktopComposeUiTest
import com.star.desktop.gherkin.generated.StepAction
import com.star.desktop.ui.app.AppScreen
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.app.StarApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import java.io.File
import java.nio.file.Files
import com.star.desktop.domain.FrameFormatChoice
import com.star.desktop.domain.RenderState
import com.star.desktop.ui.dialogs.VideoImportDialog
import kotlin.test.assertTrue

/**
 * Runs a generated [Feature] against the real Compose root ([StarApp]) with a real `stard`, offscreen
 * (`java.awt.headless=true`, set by the `gherkinTest` Gradle task: no Xvfb). The step vocabulary is
 * [StepAction]; every case has to appear in [methodMap] or the run fails naming what is implemented.
 */
@OptIn(ExperimentalTestApi::class)
class DesktopFeatureRunner {
    class RunnerError(message: String) : AssertionError(message)

    private lateinit var scratch: File
    private lateinit var feature: Feature
    private lateinit var sequenceCopy: File       // what was opened: a sequence directory, or a video file
    private lateinit var inputFrames: File        // the frames star processes (the decoded ones, for a video)
    private var sourceVideo: File? = null
    private var vm: AppViewModel? = null
    private var scope: CoroutineScope? = null
    private var completeFrames = -1
    private var rendersVideo = false
    private var finishedReview = false

    // The setting steps, applied as the startup prompts when the sequence opens (the generator makes them precede the open step).
    private var horizon: Boolean? = null
    private var moving: Boolean? = null
    private var clean: String? = null            // auto | selective | autoSelective, the validator's spelling

    private val methodMap: Map<StepAction, (ComposeUiTest) -> Unit> = mapOf(
        StepAction.HORIZON_YES to { horizon = true },
        StepAction.HORIZON_NO to { horizon = false },
        StepAction.CAMERA_STATIC to { moving = false },
        StepAction.CAMERA_MOVING to { moving = true },
        StepAction.CLEAN_AUTO to { clean = "auto" },
        StepAction.CLEAN_SELECTIVE to { clean = "selective" },
        StepAction.CLEAN_AUTO_SELECTIVE to { clean = "autoSelective" },
        StepAction.OPEN_SEQUENCE to ::openSequence,
        StepAction.IMPORT_VIDEO to ::importVideo,
        StepAction.PROCESS_EVERY_FRAME to ::processEveryFrame,
        StepAction.RENDER_OUTPUT_VIDEO to ::renderOutputVideo,
        StepAction.USED_REQUESTED_SETTINGS to ::usedRequestedSettings,
        StepAction.EVERY_FRAME_OUTPUT to ::everyFrameOutput,
        StepAction.OUTPUT_KEEPS_FORMAT to ::outputKeepsFormat,
        StepAction.PROCESSED_AUTO to { processedIn("auto") },
        StepAction.PROCESSED_SELECTIVE to { processedIn("selective") },
        StepAction.PROCESSED_AUTO_SELECTIVE to { processedIn("autoSelective") },
        StepAction.OUTPUT_VIDEO_MATCHES to ::outputVideoMatches,
        StepAction.NO_PROBLEMS to ::noProblems,
    )

    fun run(feature: Feature) {
        this.feature = feature
        // The pre-processing prompt asks whether to render afterwards, which is where this client chooses it.
        rendersVideo = feature.steps.any { it.action == StepAction.RENDER_OUTPUT_VIDEO }
        if (feature.steps.isEmpty()) throw RunnerError("feature \"${feature.name}\" has no steps: refusing to pass vacuously")
        // The client keeps its preferences in ~/.star.userprefs.json; a test must neither read nor write the real one.
        scratch = Files.createTempDirectory("star-gherkin-").toFile()
        val realHome = System.getProperty("user.home")
        System.setProperty("user.home", File(scratch, "home").apply { mkdirs() }.absolutePath)
        try {
            // Tall enough for the settings dialog's buttons to be on screen: a click lands by coordinates, and one below the window is lost.
            runDesktopComposeUiTest(width = 1400, height = 1100) {
                for (step in feature.steps) {
                    val method = methodMap[step.action] ?: throw RunnerError(
                        "no method for step \"$step\". Implemented steps:\n" +
                            methodMap.keys.map { "  ${it.text}" }.sorted().joinToString("\n"))
                    println("STEP: $step")
                    try {
                        method(this)
                    } catch (e: Throwable) {
                        throw AssertionError("step \"$step\" failed: ${e.message}", e)
                    }
                }
            }
        } finally {
            saveArtifacts(feature)
            scope?.cancel()
            System.setProperty("user.home", realHome)
            scratch.deleteRecursively()
        }
    }

    // ---- placeholders ----

    private fun param(name: String): String = Params.resolve(name, CLIENT, feature.id) ?: throw RunnerError("no value for {$name}")

    /** The repository root: the Gradle task passes it in; a run from an IDE falls back to walking up from the working directory. */
    private fun repoRoot(): File {
        System.getProperty("star.repo.root")?.let { return File(it) }
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            if (File(dir, "gherkin/steps.json").exists()) return dir
            dir = dir.parentFile
        }
        throw RunnerError("cannot find the repo root: set -Dstar.repo.root")
    }

    /** The test-data cache, by the fetch tool's rule: the `star.test.data` property the Gradle task forwards, else `<repo>/.test-data`. */
    private fun dataCache(): File =
        System.getProperty("star.test.data")?.takeIf { it.isNotEmpty() }?.let { File(it) } ?: File(repoRoot(), ".test-data")

    /** `data:<name>` resolves to `<cache>/<name>` and must be fetched already (`test_data/fetch.sh <name>`); a plain path is left alone. */
    private fun resolveSequence(given: String): File {
        if (!given.startsWith("data:")) return File(given).let { if (it.isAbsolute) it else File(repoRoot(), given) }
        val name = given.removePrefix("data:")
        val dir = File(dataCache(), name)
        if (!File(dir, ".complete").isFile) {
            throw RunnerError("test dataset `$name` is not fetched (no ${File(dir, ".complete")}). Run: test_data/fetch.sh $name (cache: ${dataCache()}; set STAR_TEST_DATA to share one)")
        }
        return dir
    }

    // ---- steps ----

    private fun requireSettings(): Triple<Boolean, Boolean, String> = Triple(
        horizon ?: throw RunnerError("no horizon step ran before the open step"),
        moving ?: throw RunnerError("no camera step ran before the open step"),
        clean ?: throw RunnerError("no clean method step ran before the open step"),
    )

    /** A dataset directory's single video file, or the file itself. */
    private fun resolveVideo(given: String): File {
        val source = resolveSequence(given)
        if (source.isFile) return source
        val videos = source.listFiles { f -> f.isFile && f.extension.lowercase() in VIDEO_EXTS }.orEmpty()
        if (videos.size != 1) throw RunnerError("expected exactly one video in $source, found ${videos.map { it.name }}")
        return videos[0]
    }

    private fun newModel(): AppViewModel {
        val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        scope = appScope
        // No auto-open hook and no autoMode: either one suppresses the startup prompts, and the prompts are how a user sets the
        // settings this feature asks for. The sequence is opened through the view model instead, as the file chooser does.
        return AppViewModel(appScope, autoOpenPath = null, autoMode = null, autoFrame = null, releaseCheck = { null }).also { vm = it }
    }

    /**
     * Copies the sequence to a fresh temp dir (star derives its temp and output paths from the input directory's name, so
     * re-processing a directory in place picks up the last run's state), opens it, and answers the startup prompts.
     */
    private fun openSequence(t: ComposeUiTest) {
        requireSettings()
        val source = resolveSequence(param("sequence"))
        if (!source.isDirectory) throw RunnerError("sequence directory not found: $source")
        sequenceCopy = File(scratch, source.name)
        source.copyRecursively(sequenceCopy)
        inputFrames = sequenceCopy
        val model = newModel()
        model.openSequence(sequenceCopy.absolutePath)
        finishOpening(t, model)
    }

    /** Opens the video through the import dialog (auto-open skips it and picks TIFF16), choosing the format the feature asks for. */
    private fun importVideo(t: ComposeUiTest) {
        requireSettings()
        val source = resolveVideo(param("video"))
        sequenceCopy = File(scratch, source.name)
        source.copyTo(sequenceCopy)
        sourceVideo = sequenceCopy
        // decodeVideo writes <video dir>/<name>/image_%04d.<ext>
        inputFrames = File(scratch, sequenceCopy.nameWithoutExtension)
        val model = newModel()
        model.openVideo(sequenceCopy.absolutePath)

        // Only the dialog is composed: the start screen behind it embeds a JavaFX video background, and JavaFX cannot start headless.
        t.setContent { VideoImportDialog(sequenceCopy.absolutePath, probe = { null }, onImport = model::confirmVideoImport, onCancel = model::cancelVideoImport) }
        val format = FrameFormatChoice.valueOf(param("frame_format").uppercase())
        waitFor(t, "the video import dialog", UI_TIMEOUT_MS) { t.onAllNodesWithTagExists("videoimport.import") }
        t.onNodeWithTag("videoimport.format.${format.name.lowercase()}").performClick()
        t.onNodeWithTag("videoimport.import").performClick()
        finishOpening(t, model)
    }

    private fun finishOpening(t: ComposeUiTest, model: AppViewModel) {
        // The sequence opens in the background, driven by the view model and not by composition. Nothing is composed until it has:
        // the start screen (the first thing StarApp would draw) embeds a JavaFX video background, and JavaFX cannot start headless, so
        // composing it blocks the UI thread for good.
        val deadline = System.nanoTime() + OPEN_TIMEOUT_MS * 1_000_000
        while (model.screen.value !is AppScreen.Sequence) {
            model.error.value?.let { throw RunnerError("the app reported an error while opening: $it") }
            if (System.nanoTime() > deadline) throw RunnerError("timed out after ${OPEN_TIMEOUT_MS / 1000}s waiting for the sequence to open (screen: ${model.screen.value})")
            Thread.sleep(50)
        }
        t.setContent { StarApp(model) }
        answerStartupPrompts(t, model)
    }

    /** Horizon → camera → (select horizon: No) → what to remove → Start processing, as a user answers them. */
    private fun answerStartupPrompts(t: ComposeUiTest, model: AppViewModel) {
        val (hasHorizon, isMoving, cleanMethod) = requireSettings()
        fun click(tag: String) {
            waitFor(t, "the startup prompt `$tag`", UI_TIMEOUT_MS) {
                model.error.value?.let { throw RunnerError("the app reported an error during the startup prompts: $it") }
                t.onAllNodesWithTagExists(tag)
            }
            // A click that lands before the card has been laid out is lost, and on a busy machine that happens: each answer replaces
            // the prompt, so a prompt that is still there a few seconds later was not answered. Click again.
            repeat(5) { attempt ->
                t.onNodeWithTag(tag).performClick()
                val gone = System.nanoTime() + 8_000_000_000L
                while (t.onAllNodesWithTagExists(tag) && System.nanoTime() < gone) { t.waitForIdle(); Thread.sleep(100) }
                if (!t.onAllNodesWithTagExists(tag)) return
                println("startup prompt `$tag` still showing after click ${attempt + 1}")
            }
            throw RunnerError("the startup prompt `$tag` did not go away after 5 clicks")
        }
        click(if (hasHorizon) "startup.horizon.yes" else "startup.horizon.no")
        click(if (isMoving) "startup.moving.moving" else "startup.moving.static")
        if (hasHorizon) click(if (isMoving) "startup.selectmovinghorizons.no" else "startup.selecthorizon.no")

        // Removal toggles, all on by default: everything is automatic; meteors off is auto selective; satellites off is selective.
        waitFor(t, "the removal prompt", UI_TIMEOUT_MS) { t.onAllNodesWithTagExists("startup.removal.start") }
        when (cleanMethod) {
            "auto" -> Unit
            "autoSelective" -> t.onNodeWithTag("startup.removal.meteors").performClick()
            "selective" -> t.onNodeWithTag("startup.removal.satellites").performClick()
            else -> throw RunnerError("unknown clean method $cleanMethod")
        }
        // Optional, for a runner too small for the default: detect keypoints at 1/<divisor> size. Written into the session config
        // as the startup question does, and waited for.
        System.getenv("STAR_GHERKIN_DESKTOP_KEYPOINT_DIVISOR")?.toDoubleOrNull()?.let { divisor ->
            model.setKeypointDivisor(divisor)
            val wrote = System.nanoTime() + UI_TIMEOUT_MS * 1_000_000
            while (model.sessions.session.value?.config?.alignmentKeypointDetectionDivisor != divisor) {
                if (System.nanoTime() > wrote) throw RunnerError("the keypoint divisor $divisor was not written to the session config")
                Thread.sleep(50)
            }
            println("keypoint divisor set to $divisor")
        }
    }

    /** Start processing → "render a video afterwards?" per the feature → wait for the run (and the render) to finish. */
    private fun processEveryFrame(t: ComposeUiTest) {
        val model = vm ?: throw RunnerError("neither \"I open the sequence\" nor \"I import the video\" has run")
        t.onNodeWithTag("startup.removal.start").performClick()
        waitFor(t, "the render-after prompt", UI_TIMEOUT_MS) { t.onAllNodesWithTagExists("prompt.pre.no") }
        t.onNodeWithTag(if (rendersVideo) "prompt.pre.yes" else "prompt.pre.no").performClick()

        // "<complete>/<total>/<running|idle>", set on the left panel's progress line. Finished: every frame complete and the run over.
        var last = "(none)"
        var lastDump = 0L
        waitFor(t, "processing to finish", PROCESS_TIMEOUT_MS, { "last progress: $last" }) {
            model.error.value?.let { throw RunnerError("the app reported an error while processing: $it") }
            val nodes = t.onAllNodes(hasTestTag("processing.progress")).fetchSemanticsNodes()
            val state = nodes.firstOrNull()?.config?.getOrNull(SemanticsProperties.StateDescription)
            if (state == null) {
                if (System.nanoTime() - lastDump > 20_000_000_000L) { lastDump = System.nanoTime(); println("no progress node (${nodes.size}); tree:\n" + t.onRoot().printToString(40)) }
                return@waitFor false
            }
            if (state != last) println("progress: $state")
            last = state
            val (complete, total, running) = state.split("/")
            val done = total.toInt() > 0 && complete == total && running == "idle"
            if (done) completeFrames = complete.toInt()
            // Auto selective leaves every frame waiting for its outliers to be reviewed (0/N complete, run over): the user finishes by
            // rendering all frames, which writes the final images but does not move the "complete" count. The cli has no review step.
            if (clean == "autoSelective" && total.toInt() > 0 && running == "idle" && complete != total) {
                if (!finishedReview) { finishedReview = true; t.onNodeWithTag("render.all.frames").performClick() }
                val written = runCatching { outputFrames().listFiles { f -> f.isFile && !f.name.startsWith(".") }.orEmpty().size }.getOrDefault(0)
                if (written == total.toInt()) { Thread.sleep(2000); completeFrames = written; return@waitFor true }
            }
            done
        }
    }

    /** Processing answered Yes to the render prompt; the render starts by itself with the default settings. Waits for it to succeed. */
    private fun renderOutputVideo(t: ComposeUiTest) {
        val model = vm ?: throw RunnerError("nothing has been opened")
        if (!rendersVideo) throw RunnerError("the render prompt was answered No")
        waitFor(t, "the video render to finish", RENDER_TIMEOUT_MS, { "render state: ${model.renderState.value}" }) {
            when (val s = model.renderState.value) {
                is RenderState.Failed -> throw RunnerError("rendering the video failed: ${s.message}")
                is RenderState.Succeeded -> true
                else -> false
            }
        }
    }

    // ---- validation: removal_tools/star-output-verify, the one tool every client uses ----

    private fun verifyBinary(): File {
        (System.getenv("STAR_OUTPUT_VERIFY_PATH") ?: "").takeIf { it.isNotEmpty() }?.let {
            return File(it).also { f -> if (!f.canExecute()) throw RunnerError("STAR_OUTPUT_VERIFY_PATH is not an executable: $it") }
        }
        val name = if (System.getProperty("os.name").lowercase().contains("win")) "star-output-verify.exe" else "star-output-verify"
        val exe = File(repoRoot(), "removal_tools/.build/release/$name")
        if (!exe.canExecute()) throw RunnerError("no validator at $exe: run `swift build -c release --package-path removal_tools`, or set STAR_OUTPUT_VERIFY_PATH")
        return exe
    }

    private fun verify(vararg args: String) {
        val process = ProcessBuilder(listOf(verifyBinary().absolutePath) + args.toList() + listOf("--report", File(scratch, "report-${args[0]}.json").absolutePath))
            .redirectErrorStream(true).start()
        val text = process.inputStream.bufferedReader().readText()
        val status = process.waitFor()
        val lines = text.lines()
        println(if (lines.size > 40) (lines.take(10) + "…" + lines.takeLast(10)).joinToString("\n") else text)
        if (status != 0) throw RunnerError("star-output-verify ${args[0]} failed:\n$text")
    }

    private fun session() = vm?.sessions?.session?.value ?: throw RunnerError("no open session")

    /** The directory processing wrote the final frames to: `<outputPath>/<sequence name>-star-v-<version>`. */
    private fun outputFrames(): File {
        val config = session().config
        val outDirs = File(config.outputPath).listFiles { f -> f.isDirectory && f.name.startsWith("${inputFrames.name}-star-v-") }.orEmpty()
        if (outDirs.size != 1) throw RunnerError("expected one output directory under ${config.outputPath}, found ${outDirs.map { it.name }}")
        return outDirs[0]
    }

    private fun usedRequestedSettings(t: ComposeUiTest) {
        val (hasHorizon, isMoving, cleanMethod) = requireSettings()
        val info = session()
        val config = info.configJsonPath.ifEmpty { "${info.scratchSessionDir}/config.json" }
        verify("settings", "--config", config, "--horizon", if (hasHorizon) "yes" else "no",
            "--camera", if (isMoving) "moving" else "static", "--clean", cleanMethod)
    }

    private fun everyFrameOutput(t: ComposeUiTest) {
        if (completeFrames < 0) throw RunnerError("\"I process every frame\" has not run")
        val args = mutableListOf("frames", "--input-dir", inputFrames.absolutePath, "--output-dir", outputFrames().absolutePath)
        sourceVideo?.let { args += listOf("--video", it.absolutePath) }
        verify(*args.toTypedArray())
    }

    private fun outputKeepsFormat(t: ComposeUiTest) =
        verify("format", "--input-dir", inputFrames.absolutePath, "--output-dir", outputFrames().absolutePath)

    private fun processedIn(mode: String) {
        val args = mutableListOf("mode", "--mode", mode, "--input-dir", inputFrames.absolutePath, "--output-dir", outputFrames().absolutePath,
            "--thresholds", File(repoRoot(), "removal_tools/thresholds.json").absolutePath)
        if (mode == "autoSelective") args += listOf("--config", session().let { it.configJsonPath.ifEmpty { "${it.scratchSessionDir}/config.json" } })
        if (System.getenv("STAR_GHERKIN_REPORT_ONLY") != null) args += "--report-only"
        verify(*args.toTypedArray())
    }

    private fun outputVideoMatches(t: ComposeUiTest) {
        val model = vm ?: throw RunnerError("nothing has been opened")
        val rendered = (model.renderState.value as? RenderState.Succeeded)?.path ?: throw RunnerError("no rendered video: ${model.renderState.value}")
        // the imported video's settings, else Config's defaults (ProRes, 30 fps)
        verify("video", "--video", rendered, "--output-dir", outputFrames().absolutePath, "--frame-rate", "30/1",
            "--codec", if (sourceVideo == null) "prores" else "h264")
    }

    /** The engine's warnings: nothing in the banner and nothing critical. */
    private fun noProblems(t: ComposeUiTest) {
        val model = vm ?: throw RunnerError("nothing has been opened")
        val w = model.warningState.value
        assertTrue(w.banner == null && w.critical == null, "star reported warnings: banner=${w.banner}, critical=${w.critical}")
    }

    /** Copies the validator's reports and the run's config.json to `$STAR_GHERKIN_ARTIFACTS/<feature>` for CI to upload. */
    private fun saveArtifacts(feature: Feature) {
        val dir = System.getenv("STAR_GHERKIN_ARTIFACTS")?.takeIf { it.isNotEmpty() } ?: return
        val dest = File(dir, feature.id).apply { mkdirs() }
        scratch.listFiles { f -> f.isFile && f.name.startsWith("report-") }.orEmpty().forEach { it.copyTo(File(dest, it.name), overwrite = true) }
        runCatching {
            val info = vm?.sessions?.session?.value
            val config = File(info?.configJsonPath?.ifEmpty { "${info.scratchSessionDir}/config.json" } ?: return@runCatching)
            if (config.isFile) config.copyTo(File(dest, "config.json"), overwrite = true)
        }
    }

    // ---- waiting ----

    private fun ComposeUiTest.onAllNodesWithTagExists(tag: String): Boolean =
        onAllNodes(hasTestTag(tag)).fetchSemanticsNodes().isNotEmpty()

    /**
     * Waits in real time. Processing runs in `stard` on real threads, not on the test clock, so this is `waitUntil` (which keeps
     * the main clock running and recomposing, `autoAdvance` being on) and never `runTest`'s virtual time.
     */
    private fun waitFor(t: ComposeUiTest, what: String, timeoutMs: Long, detail: () -> String = { "" }, condition: () -> Boolean) {
        // waitUntil's own timeout is measured on the test clock, which does not reliably follow real time while the UI is being
        // redrawn, so the deadline is kept here, in real time.
        val deadline = System.nanoTime() + timeoutMs * 1_000_000
        try {
            t.waitUntil(timeoutMillis = timeoutMs) {
                if (System.nanoTime() > deadline) throw RunnerError("timed out after ${timeoutMs / 1000}s waiting for $what ${detail()}\n" + t.onAllNodes(isRoot()).printToString(80))
                condition()
            }
        } catch (e: ComposeTimeoutException) {
            throw RunnerError("timed out after ${timeoutMs / 1000}s waiting for $what ${detail()}")
        }
    }

    private companion object {
        const val CLIENT = "desktop"
        const val OPEN_TIMEOUT_MS = 10L * 60_000
        const val UI_TIMEOUT_MS = 90_000L
        const val PROCESS_TIMEOUT_MS = 25L * 60_000
        const val RENDER_TIMEOUT_MS = 10L * 60_000
        val VIDEO_EXTS = setOf("mov", "mp4", "m4v", "avi", "mkv", "mpg", "mpeg")
    }
}
