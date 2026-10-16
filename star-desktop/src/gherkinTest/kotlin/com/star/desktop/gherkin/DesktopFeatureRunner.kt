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
import com.google.gson.JsonObject
import com.google.gson.JsonParser
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
import kotlin.test.assertEquals

/**
 * Runs a generated [Feature] against the real Compose root ([StarApp]) with a real `stard`, offscreen
 * (`java.awt.headless=true`, set by the `gherkinTest` Gradle task: no Xvfb). The step vocabulary is
 * [StepAction]; every case has to appear in [methodMap] or the run fails naming what is implemented.
 */
@OptIn(ExperimentalTestApi::class)
class DesktopFeatureRunner {
    class RunnerError(message: String) : AssertionError(message)

    private lateinit var scratch: File
    private lateinit var sequenceCopy: File
    private var vm: AppViewModel? = null
    private var scope: CoroutineScope? = null
    private var completeFrames = -1

    private val methodMap: Map<StepAction, (ComposeUiTest) -> Unit> = mapOf(
        StepAction.OPEN_SEQUENCE to ::openSequence,
        StepAction.PROCESS_EVERY_FRAME to ::processEveryFrame,
        StepAction.OUTPUT_FRAMES_WRITTEN to ::outputFramesWritten,
        // No clean-method steps: the auto-open path skips the startup questions and the session keeps initialConfigBeside's default,
        // CLEAN_SELECTIVE (InitialConfigBesideTest), which is what runVerifier judges. A feature that asks for another method fails
        // naming what is implemented.
        StepAction.AIRPLANES_REMOVED to { _ -> trailsRemoved("airplane") },
        StepAction.SATELLITES_REMOVED to { _ -> trailsRemoved("satellite") },
        StepAction.STARS_PRESERVED to { _ -> starsPreserved() },
    )

    fun run(feature: Feature) {
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
            scope?.cancel()
            System.setProperty("user.home", realHome)
            scratch.deleteRecursively()
        }
    }

    // ---- placeholders ----

    private fun param(name: String): String = Params.resolve(name, CLIENT) ?: throw RunnerError("no value for {$name}")

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

    /**
     * Copies the sequence to a fresh temp dir (star derives its temp and output paths from the input directory's name, so
     * re-processing a directory in place picks up the last run's state), then opens it exactly as `./gradlew run --args=` does:
     * [AppViewModel]'s auto-open hook, landing in edit mode, which skips the startup prompts.
     */
    private fun openSequence(t: ComposeUiTest) {
        val given = param("sequence")
        val source = resolveSequence(given)
        if (!source.isDirectory) throw RunnerError("sequence directory not found: $source")
        sequenceCopy = File(scratch, source.name)
        source.copyRecursively(sequenceCopy)

        val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        scope = appScope
        val model = AppViewModel(appScope, autoOpenPath = sequenceCopy.absolutePath, autoMode = "edit", autoFrame = null, releaseCheck = { null })
        vm = model

        // The sequence opens in the background, driven by the view model and not by composition. Nothing is composed until it has:
        // the start screen (the first thing StarApp would draw) embeds a JavaFX video background, and JavaFX cannot start headless, so
        // composing it blocks the UI thread for good.
        val deadline = System.nanoTime() + OPEN_TIMEOUT_MS * 1_000_000
        while (model.screen.value !is AppScreen.Sequence) {
            model.error.value?.let { throw RunnerError("the app reported an error while opening: $it") }
            if (System.nanoTime() > deadline) throw RunnerError("timed out after ${OPEN_TIMEOUT_MS / 1000}s waiting for the sequence to open (screen: ${model.screen.value})")
            Thread.sleep(50)
        }
        // Optional, for a runner too small for the default: detect keypoints at 1/<divisor> size. Written into the session config
        // as the startup question does, and waited for, so the settings dialog opened later proposes a config that has it.
        System.getenv("STAR_GHERKIN_DESKTOP_KEYPOINT_DIVISOR")?.toDoubleOrNull()?.let { divisor ->
            model.setKeypointDivisor(divisor)
            val wrote = System.nanoTime() + UI_TIMEOUT_MS * 1_000_000
            while (model.sessions.session.value?.config?.alignmentKeypointDetectionDivisor != divisor) {
                if (System.nanoTime() > wrote) throw RunnerError("the keypoint divisor $divisor was not written to the session config")
                Thread.sleep(50)
            }
            println("keypoint divisor set to $divisor")
        }
        t.setContent { StarApp(model) }
        waitFor(t, "the sequence screen", UI_TIMEOUT_MS) {
            model.error.value?.let { throw RunnerError("the app reported an error while opening: $it") }
            t.onAllNodesWithTagExists("process.frames")
        }
    }

    /** Process button → settings → Process Now → "render a video afterwards?" No → wait for the run to finish. */
    private fun processEveryFrame(t: ComposeUiTest) {
        val model = vm ?: throw RunnerError("\"I open the sequence\" has not run")
        t.onNodeWithTag("process.frames").performClick()
        // Enabled only once the dialog has asked the daemon whether the settings are valid (a moment after it opens).
        waitFor(t, "the processing settings' Process button to be enabled", UI_TIMEOUT_MS) {
            t.onAllNodesWithTagExists("settings.process")
        }
        t.onNodeWithTag("settings.process").performClick()
        waitFor(t, "the render-after prompt", UI_TIMEOUT_MS) { t.onAllNodesWithTagExists("prompt.pre.no") }
        t.onNodeWithTag("prompt.pre.no").performClick()

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
            done
        }
    }

    private fun outputFramesWritten(t: ComposeUiTest) {
        val want = param("expected_outputs").toIntOrNull() ?: throw RunnerError("{expected_outputs} is not a number")
        val model = vm ?: throw RunnerError("\"I open the sequence\" has not run")
        if (completeFrames < 0) throw RunnerError("\"I process every frame\" has not run")
        val outDir = outputDirectory(model)
        val files = outDir.listFiles { f -> f.isFile && !f.name.startsWith(".") }.orEmpty().map { it.name }.sorted()
        assertEquals(want, files.size, "frames written to $outDir: $files")
        assertEquals(want, completeFrames, "the progress line's complete count")
    }

    /** The session's output goes to <outputPath>/<sequence name>-star-v-<version>, beside the copy we made. */
    private fun outputDirectory(model: AppViewModel): File {
        val config = model.sessions.session.value?.config ?: throw RunnerError("no open session")
        val outDirs = File(config.outputPath).listFiles { f -> f.isDirectory && f.name.startsWith("${sequenceCopy.name}-star-v-") }.orEmpty()
        if (outDirs.size != 1) throw RunnerError("expected one output directory under ${config.outputPath}, found ${outDirs.map { it.name }}")
        return outDirs[0]
    }

    // ---- removal checks (star-removal-verify) ----
    // Same verifier, flags and vacuous-green guards as cli/Tests/GherkinTests/CliFeatureRunner.swift, run as a subprocess.

    private fun verifierBinary(): File {
        val exe = if (System.getProperty("os.name").startsWith("Windows")) "star-removal-verify.exe" else "star-removal-verify"
        val f = System.getenv("STAR_REMOVAL_VERIFY")?.takeIf { it.isNotEmpty() }?.let { File(it) }
            ?: File(repoRoot(), "removal_tools/.build/release/$exe")
        if (!f.isFile) throw RunnerError("no star-removal-verify at $f: run `swift build -c release --package-path removal_tools`, or set STAR_REMOVAL_VERIFY")
        return f
    }

    /** Not the scratch directory (deleted when the scenario ends): CI uploads this as an artifact. */
    private fun reportsDirectory(): File {
        val base = System.getenv("STAR_REMOVAL_REPORTS")?.takeIf { it.isNotEmpty() }?.let { File(it) } ?: File(repoRoot(), "removal-reports")
        return File(base, "desktop-removeAirplanes")
    }

    private fun labelsJson(): JsonObject {
        val labels = File(sequenceCopy, "labels.json")
        if (!labels.isFile) throw RunnerError("no labels.json in the sequence: $labels")
        return JsonParser.parseString(labels.readText()).asJsonObject
    }

    /** Runs the verifier for the method this client ran, selective. A failing exit status fails the step with its summary. */
    private fun runVerifier(extra: List<String>, reportName: String): JsonObject {
        val model = vm ?: throw RunnerError("\"I open the sequence\" has not run")
        if (completeFrames < 0) throw RunnerError("\"I process every frame\" has not run")
        val reports = reportsDirectory().apply { mkdirs() }
        val report = File(reports, "$reportName.json")
        val crops = File(reports, "$reportName-crops")
        val args = listOf(
            verifierBinary().absolutePath,
            "--input", sequenceCopy.absolutePath, "--output", outputDirectory(model).absolutePath,
            "--labels", File(sequenceCopy, "labels.json").absolutePath,
            "--thresholds", File(repoRoot(), "gherkin/removal-thresholds.json").absolutePath,
            "--clean-method", "selective", "--dataset", sequenceCopy.name,
            "--skip-unmeasurable", "--report", report.absolutePath, "--crops", crops.absolutePath,
        ) + extra
        val p = ProcessBuilder(args).redirectErrorStream(true).start()
        val text = p.inputStream.bufferedReader().readText()
        val status = p.waitFor()
        println(text.lines().takeLast(12).joinToString("\n"))
        if (status != 0) {
            throw RunnerError("star-removal-verify exited $status\n" + text.lines().takeLast(30).joinToString("\n") +
                "\nreport: $report\ncrops: $crops")
        }
        return JsonParser.parseString(report.readText()).asJsonObject
    }

    private fun trailsRemoved(trailClass: String) {
        val expected = labelsJson().getAsJsonObject("frames").entrySet().sumOf { (_, objs) ->
            objs.asJsonArray.count {
                val o = it.asJsonObject
                o.get("class")?.asString == trailClass && o.get("confirmed")?.asBoolean == true
            }
        }
        // selective leaves most faint labelled streaks alone by design (BUGS.md BUG-004), so it is judged on the pinned objects only,
        // exactly as the cli runner does for selective.
        val pinsFile = File(repoRoot(), "gherkin/removal-pins.json")
        val pinned = JsonParser.parseString(pinsFile.readText()).asJsonObject.getAsJsonArray("pins").size()
        val report = runVerifier(listOf("--expect", "$trailClass=removed", "--pins-only", "--pins", pinsFile.absolutePath), "${trailClass}s-removed")
        // not vacuous: the verifier must have looked at every confirmed object of this class
        val summary = report.getAsJsonObject("summary")
        val objects = summary?.get("objects")?.asInt ?: -1
        if (expected <= 0) throw RunnerError("labels.json has no confirmed $trailClass objects: the step would check nothing")
        if (objects != expected) throw RunnerError("the verifier checked $objects $trailClass objects, labels.json has $expected confirmed: refusing to pass")
        val checked = summary.get("pinsChecked")?.asInt ?: -1
        if (checked != pinned) throw RunnerError("the verifier checked $checked pinned objects, removal-pins.json has $pinned: refusing to pass")
        val measured = (summary.get("passed")?.asInt ?: 0) + (summary.get("failed")?.asInt ?: 0)
        if (measured <= 0) throw RunnerError("no $trailClass object was measurable: refusing to pass")
    }

    private fun starsPreserved() {
        val model = vm ?: throw RunnerError("\"I open the sequence\" has not run")
        val report = runVerifier(listOf("--stars"), "stars")
        val frames = outputDirectory(model).listFiles { f -> f.isFile && !f.name.startsWith(".") }.orEmpty().size
        val stars = report.getAsJsonObject("stars")?.size() ?: 0
        if (frames <= 0 || stars != frames) throw RunnerError("the star check covered $stars frames, Star wrote $frames: refusing to pass")
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
    }
}
