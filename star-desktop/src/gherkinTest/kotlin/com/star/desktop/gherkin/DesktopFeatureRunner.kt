package com.star.desktop.gherkin

import androidx.compose.foundation.focusable
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.ComposeTimeoutException
import androidx.compose.ui.test.ComposeUiTest
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.printToString
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.runDesktopComposeUiTest
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.star.desktop.gherkin.generated.StepAction
import com.star.desktop.ui.app.AppScreen
import com.star.desktop.ui.app.AppViewModel
import com.star.desktop.ui.app.MenuEntry
import com.star.desktop.ui.app.StarApp
import com.star.desktop.ui.app.starMenusNow
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

    /** What the step being run was given for its inline arguments (`I click "<id>"`). */
    private var args: List<String> = emptyList()

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
        StepAction.IMPORT_VIDEO to { t -> importVideo(t) },
        StepAction.IMPORT_VIDEO_BACKGROUND to { t -> importVideo(t, inBackground = true) },
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
        StepAction.AIRPLANES_REMOVED to { trailsRemoved("airplane") },
        StepAction.SATELLITES_REMOVED to { trailsRemoved("satellite") },
        StepAction.STARS_PRESERVED to { starsPreserved() },
        StepAction.NOTHING_ELSE_CHANGED to { nothingElseChanged() },
        // the @ui vocabulary
        StepAction.COPY_SEQUENCE to ::copySequenceStep,
        StepAction.OPEN_COPIED to { t -> openCopiedSequence(t) },
        StepAction.OPEN_COPIED_NO_QUESTIONS to { t -> openCopiedSequence(t, askingTheStartupQuestions = false) },
        StepAction.CLICK_ID to { t -> clickId(t, args[0]) },
        StepAction.PRESS_KEY to { t -> pressKey(t, args[0]) },
        StepAction.ID_SHOWN to { t -> expectShown(t, args[0], shown = true) },
        StepAction.ID_NOT_SHOWN to { t -> expectShown(t, args[0], shown = false) },
        StepAction.ID_SELECTED to { t -> expectSelected(t, args[0], selected = true) },
        StepAction.ID_NOT_SELECTED to { t -> expectSelected(t, args[0], selected = false) },
        StepAction.ID_ON to { t -> expectOn(t, args[0], on = true) },
        StepAction.ID_OFF to { t -> expectOn(t, args[0], on = false) },
        StepAction.ID_READS to { t -> expectReads(t, args[0], args[1]) },
        StepAction.ID_SAYS to { t -> expectSays(t, args[0], args[1]) },
        // What the Compose test host has no AWT for. The menu bar and the secondary windows are AWT, so these steps work on what the app draws
        // them from: the menus as data (`starMenus`, which `StarMenuBar` draws and nothing else builds; `starMenusNow` reads them without composing) and the view model's window flags (which
        // `Main.kt` hangs each `Window` on, and `MainWindowsTest` reads it to hold it to).
        StepAction.APP_NO_SEQUENCE to ::startWithNoSequence,
        StepAction.PREFS_RECENTS to { seedRecents(args[0].toInt()) },
        StepAction.PREFS_LIST_RECENTS to { t -> expectRecents(t, args[0].toInt()) },
        StepAction.PREFS_FIXTURE to { seedPreferences(args[0]) },
        StepAction.PREFS_UNCHANGED to { expectPreferencesUnchanged(args[0]) },
        StepAction.PREFS_HAS_KEY to { t -> expectPreferencesKey(t, args[0]) },
        StepAction.PREFS_KEEPS_COPY to { t -> expectUndecodableCopy(t, args[0]) },
        StepAction.MENU_CHOOSE to { t -> chooseMenuCommand(t, args[0]) },
        StepAction.MENU_ENABLED to { t -> expectMenuCommand(t, args[0], enabled = true) },
        StepAction.MENU_DISABLED to { t -> expectMenuCommand(t, args[0], enabled = false) },
        StepAction.WINDOW_OPEN to { t -> expectWindow(t, args[0], open = true) },
        StepAction.WINDOW_NOT_OPEN to { t -> expectWindow(t, args[0], open = false) },
    )

    fun run(feature: Feature) {
        this.feature = feature
        // The pre-processing prompt asks whether to render afterwards, which is where this client chooses it.
        rendersVideo = feature.steps.any { it.action == StepAction.RENDER_OUTPUT_VIDEO }
        if (feature.steps.isEmpty()) throw RunnerError("feature \"${feature.name}\" has no steps: refusing to pass vacuously")
        // The client keeps its preferences in ~/.star.userprefs.json; a test must neither read nor write the real one.
        // a @ui feature may compare what the app says with the English catalogue
        // and may show the start screen, which would otherwise embed a JavaFX video that cannot start headless
        if ("@ui" in feature.tags) {
            com.star.desktop.i18n.Strings.setOverride("en")
            System.setProperty(com.star.desktop.ui.initial.NO_INTRO_VIDEO_PROPERTY, "true")
        }
        scratch = Files.createTempDirectory("star-gherkin-").toFile()
        val realHome = System.getProperty("user.home")
        System.setProperty("user.home", File(scratch, "home").apply { mkdirs() }.absolutePath)
        try {
            // Tall enough for the settings dialog's buttons to be on screen: a click lands by coordinates, and one below the window is lost.
            // A @ui feature that fails where gherkin/ui/known-gaps.json says it does passes, and says so; one that passes there fails until the
            // entry is removed (the parity backlog is that file, and it only shrinks).
            val gap = if ("@ui" in feature.tags) knownGap(feature.id) else null
            var failure: Throwable? = null
            runDesktopComposeUiTest(width = 1400, height = 1100) {
                try {
                    for (step in feature.steps) {
                        val method = methodMap[step.action] ?: throw RunnerError(
                            "no method for step \"$step\". Implemented steps:\n" +
                                methodMap.keys.map { "  ${it.text}" }.sorted().joinToString("\n"))
                        println("STEP: $step")
                        args = step.args
                        try {
                            method(this)
                        } catch (e: Throwable) {
                            throw AssertionError("step \"$step\" failed: ${e.message}", e)
                        }
                    }
                } catch (e: Throwable) {
                    failure = e
                }
            }
            failure?.let { e ->
                if (gap == null) throw e
                println("KNOWN GAP ${feature.id} on $CLIENT: $gap\n  it failed with: ${e.message}")
                return
            }
            if (gap != null) throw RunnerError("${feature.id} passes on $CLIENT, and gherkin/ui/known-gaps.json still lists it as a gap ($gap): remove the entry")
        } finally {
            saveArtifacts(feature)
            // A @ui feature often stops with a run going: the engine is asked to stop, so the next feature does not share it with the run.
            if ("@ui" in feature.tags) vm?.let { m -> runCatching { kotlinx.coroutines.runBlocking { kotlinx.coroutines.withTimeoutOrNull(10_000) { m.shutdown() } } } }
            scope?.cancel()
            System.setProperty("user.home", realHome)
            if ("@ui" in feature.tags) {
                com.star.desktop.i18n.Strings.setOverride(null)
                System.clearProperty(com.star.desktop.ui.initial.NO_INTRO_VIDEO_PROPERTY)
            }
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

    private fun newModel(openPath: String? = null, mode: String? = null): AppViewModel {
        // The removal pins were measured at DETECTION_STRONG (Star's own default, the cli's). A session opens at the user's remembered type, and
        // with none remembered the proto's zero value, DETECTION_MILD, so a removal feature seeds the remembered type before the view model
        // reads its preferences (user.home is the scratch home, see run()), and finishOpening only checks it. Patching the session afterwards
        // raced the daemon on a starved VM. Other features keep the client's own default.
        if (feature.steps.any { it.action in REMOVAL_ACTIONS }) {
            File(System.getProperty("user.home"), ".star.userprefs.json").writeText("""{"processingType":"strong"}""")
        }
        val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        scope = appScope
        // No auto-open hook and no autoMode: either one suppresses the startup prompts, and the prompts are how a user sets the
        // settings this feature asks for. The sequence is opened through the view model instead, as the file chooser does.
        return AppViewModel(appScope, autoOpenPath = openPath, autoMode = mode, autoFrame = if (mode != null) 0 else null, releaseCheck = { null }).also { vm = it }
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
    private fun importVideo(t: ComposeUiTest, inBackground: Boolean = false) {
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
        // The box starts off for H.264 (the probe is not run here, so for every video): once, to go to the main screen while the frames
        // are still being extracted, and the run then waits for them as it goes.
        if (inBackground) t.onNodeWithTag("videoimport.background").performClick()
        t.onNodeWithTag("videoimport.import").performClick()
        finishOpening(t, model)
    }

    /** Why [feature] is a known gap of this client, from gherkin/ui/known-gaps.json; null when it is not one. */
    private fun knownGap(feature: String): String? {
        val file = File(repoRoot(), "gherkin/ui/known-gaps.json").takeIf { it.isFile } ?: return null
        val gaps = JsonParser.parseString(file.readText()).asJsonObject.getAsJsonObject("gaps") ?: return null
        return gaps.getAsJsonObject(feature)?.get(CLIENT)?.asString
    }

    @androidx.compose.runtime.Composable
    private fun KeyHost(model: AppViewModel, content: @androidx.compose.runtime.Composable () -> Unit) {
        val focus = androidx.compose.runtime.remember { androidx.compose.ui.focus.FocusRequester() }
        androidx.compose.foundation.layout.Box(
            androidx.compose.ui.Modifier.focusRequester(focus).focusable().onKeyEvent { com.star.desktop.ui.app.handleGlobalKey(it, model) },
        ) { content() }
        androidx.compose.runtime.LaunchedEffect(Unit) { focus.requestFocus() }
    }

    // ---- the @ui steps ----

    /** A fresh copy of the sequence, as [openSequence] makes one: star derives its temp and output paths from the input directory's name. */
    private fun copySequenceStep(t: ComposeUiTest) {
        val source = resolveSequence(param("sequence"))
        if (!source.isDirectory) throw RunnerError("sequence directory not found: $source")
        sequenceCopy = File(scratch, source.name)
        source.copyRecursively(sequenceCopy)
        inputFrames = sequenceCopy
    }

    /** Opens the copy as the file chooser does, and stops there: the startup questions are the feature's to answer. */
    private fun openCopiedSequence(t: ComposeUiTest, askingTheStartupQuestions: Boolean = true) {
        if (!::sequenceCopy.isInitialized) throw RunnerError("\"a fresh copy of the sequence\" has not run")
        // The view model's own dev hook lands in the edit screen without the startup questions, as the gui's launch argument does.
        val model = if (askingTheStartupQuestions) newModel().also { it.openSequence(sequenceCopy.absolutePath) }
                    else newModel(openPath = sequenceCopy.absolutePath, mode = "edit")
        finishOpening(t, model, answer = false)
    }

    /** Clicks the control; where a list has one per row (the recents' remove button), the first, which is the row on top. */
    private fun clickId(t: ComposeUiTest, id: String) {
        waitFor(t, "\"$id\"", UI_TIMEOUT_MS) { t.onAllNodesWithTagExists(id) }
        t.waitForIdle()
        t.onAllNodes(hasTestTag(id))[0].performClick()
    }

    private fun expectShown(t: ComposeUiTest, id: String, shown: Boolean) {
        waitFor(t, "\"$id\" ${if (shown) "shown" else "not shown"}", UI_TIMEOUT_MS) { t.onAllNodesWithTagExists(id) == shown }
    }

    private fun semanticsOf(t: ComposeUiTest, id: String) =
        t.onAllNodes(hasTestTag(id)).fetchSemanticsNodes().firstOrNull()?.config

    private fun expectSelected(t: ComposeUiTest, id: String, selected: Boolean) {
        expectShown(t, id, shown = true)
        waitFor(t, "\"$id\" ${if (selected) "selected" else "not selected"}", 20_000, { "(Selected: ${semanticsOf(t, id)?.getOrNull(SemanticsProperties.Selected)})" }) {
            (semanticsOf(t, id)?.getOrNull(SemanticsProperties.Selected) ?: false) == selected
        }
    }

    private fun expectOn(t: ComposeUiTest, id: String, on: Boolean) {
        expectShown(t, id, shown = true)
        waitFor(t, "\"$id\" ${if (on) "on" else "off"}", 20_000, { "(ToggleableState: ${semanticsOf(t, id)?.getOrNull(SemanticsProperties.ToggleableState)})" }) {
            (semanticsOf(t, id)?.getOrNull(SemanticsProperties.ToggleableState) == ToggleableState.On) == on
        }
    }

    /** The control's text is exactly [expected]. */
    private fun expectSays(t: ComposeUiTest, id: String, expected: String) {
        expectShown(t, id, shown = true)
        fun texts() = semanticsOf(t, id)?.getOrNull(SemanticsProperties.Text)?.map { it.text }.orEmpty()
        waitFor(t, "\"$id\" to say \"$expected\"", 20_000, { "(it says ${texts()})" }) { expected in texts() || texts().joinToString("") == expected }
    }

    /** The control's text is the catalogue's English text for [key]. */
    private fun expectReads(t: ComposeUiTest, id: String, key: String) {
        expectShown(t, id, shown = true)
        val expected = com.star.desktop.i18n.localized(key)
        fun texts() = semanticsOf(t, id)?.getOrNull(SemanticsProperties.Text)?.map { it.text }.orEmpty()
        waitFor(t, "\"$id\" to read \"$expected\"", 20_000, { "(it reads ${texts()})" }) { expected in texts() || texts().joinToString("") == expected }
    }

    /** `return`, `escape`, `tab`, `space`, an arrow, or one character, with modifiers before it: `cmd+w`, `shift+cmd+,`. */
    private fun pressKey(t: ComposeUiTest, spec: String) {
        val parts = spec.lowercase().split('+')
        val name = parts.last().ifEmpty { throw RunnerError("\"$spec\" is not a key") }
        val mac = System.getProperty("os.name").orEmpty().startsWith("Mac", ignoreCase = true)
        val modifiers = parts.dropLast(1).map {
            when (it) {
                "cmd", "command" -> if (mac) Key.MetaLeft else Key.CtrlLeft
                "shift" -> Key.ShiftLeft
                "alt", "option" -> Key.AltLeft
                "ctrl", "control" -> Key.CtrlLeft
                else -> throw RunnerError("\"$it\" is not a modifier (in \"$spec\")")
            }
        }
        val key = when (name) {
            "return", "enter" -> Key.Enter
            "escape", "esc" -> Key.Escape
            "tab" -> Key.Tab
            "space" -> Key.Spacebar
            "left" -> Key.DirectionLeft
            "right" -> Key.DirectionRight
            "up" -> Key.DirectionUp
            "down" -> Key.DirectionDown
            else -> {
                if (name.length != 1) throw RunnerError("\"$name\" is not a key I know (in \"$spec\")")
                Key(java.awt.event.KeyEvent.getExtendedKeyCodeForChar(name[0].code))
            }
        }
        t.waitForIdle()
        t.onRoot().performKeyInput {
            modifiers.forEach { keyDown(it) }
            keyDown(key); keyUp(key)
            modifiers.asReversed().forEach { keyUp(it) }
        }
    }

    private fun finishOpening(t: ComposeUiTest, model: AppViewModel, answer: Boolean = true) {
        // The sequence opens in the background, driven by the view model and not by composition. Nothing is composed until it has:
        // the start screen (the first thing StarApp would draw) embeds a JavaFX video background, and JavaFX cannot start headless, so
        // composing it blocks the UI thread for good. (A @ui feature turns the video off, so one that wants the start screen can have it.)
        val deadline = System.nanoTime() + OPEN_TIMEOUT_MS * 1_000_000
        while (model.screen.value !is AppScreen.Sequence) {
            model.error.value?.let { throw RunnerError("the app reported an error while opening: $it") }
            if (System.nanoTime() > deadline) throw RunnerError(
                "timed out after ${OPEN_TIMEOUT_MS / 1000}s waiting for the sequence to open (screen: ${model.screen.value})\n" + processSnapshot())
            Thread.sleep(50)
        }
        if (feature.steps.any { it.action in REMOVAL_ACTIONS }) {
            val detection = model.sessions.session.value?.config?.detectionType
            if (detection != com.star.proto.DetectionType.DETECTION_STRONG) throw RunnerError("the session opened at detection type $detection, not DETECTION_STRONG")
        }
        showApp(t, model)
        if (answer) answerStartupPrompts(t, model)
    }

    /**
     * Composes the app. What `Main.kt` hangs on the window and not in [StarApp], a @ui feature hosts the same way: the window's key handler
     * (`Window(onKeyEvent = ...)`) on an ancestor, in the bubble phase, with the focus put on it to begin with.
     */
    private fun showApp(t: ComposeUiTest, model: AppViewModel) {
        if ("@ui" in feature.tags) t.setContent { KeyHost(model) { StarApp(model) } } else t.setContent { StarApp(model) }
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

        // Mode choice defaults to automatic; the auto-selective toggle under it makes it auto selective; the selective row is selective.
        waitFor(t, "the removal prompt", UI_TIMEOUT_MS) { t.onAllNodesWithTagExists("startup.removal.start") }
        when (cleanMethod) {
            "auto" -> Unit
            "autoSelective" -> t.onNodeWithTag("startup.removal.autoselective").performClick()
            "selective" -> t.onNodeWithTag("startup.removal.selective").performClick()
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
        // The removal card is taller than the window and scrolls: Automatic shows the auto-selective toggle and its text, and on a 12 MP
        // sequence on a small runner the speed settings open by themselves (about 280px), which put Start at y=1110 in a 1100px window.
        // A click lands by coordinates and one outside the window is lost, so the run never started and this waited out the whole timeout
        // below. Selective hides the extra rows, which is the one feature that always got through.
        t.onNodeWithTag("startup.removal.start").performScrollTo().performClick()
        waitFor(t, "the render-after prompt", UI_TIMEOUT_MS) { t.onAllNodesWithTagExists("prompt.pre.no") }
        t.onNodeWithTag(if (rendersVideo) "prompt.pre.yes" else "prompt.pre.no").performClick()

        // "<complete>/<total>/<running|idle>", set on the left panel's progress line. Finished: every frame complete and the run over.
        var last = "(none)"
        var lastDump = 0L
        waitFor(t, "processing to finish", PROCESS_TIMEOUT_MS, { "last progress: $last" }) {
            model.error.value?.let { throw RunnerError("the app reported an error while processing: $it") }
            // A dead engine (killed by the OS, say for memory) never finishes the run: without this the wait sits out its whole timeout.
            model.engineDown.value?.let { throw RunnerError("the engine stopped while processing: $it") }
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
            // An auto selective frame is complete once its final is written (StarCore's finishAuto sets it, as finishSelective does), so the run
            // ends N/N here as it does for every other clean method. It used to stop at 0/N and this clicked Render All Frames to finish (L5).
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

    // ---- removal checks (star-removal-verify) ----
    // Same verifier, flags and vacuous-green guards as cli/Tests/GherkinTests/CliFeatureRunner.swift, run as a subprocess.

    /** The clean method the feature asked for, in the removal verifier's spelling. */
    private fun removalMethod(): String = when (clean) {
        "auto" -> "automatic:false"
        "autoSelective" -> "automatic:true"
        "selective" -> "selective"
        else -> throw RunnerError("no clean method step ran before the open step")
    }

    private fun removalVerifierBinary(): File {
        val exe = if (System.getProperty("os.name").startsWith("Windows")) "star-removal-verify.exe" else "star-removal-verify"
        val f = System.getenv("STAR_REMOVAL_VERIFY")?.takeIf { it.isNotEmpty() }?.let { File(it) }
            ?: File(repoRoot(), "trail_tools/.build/release/$exe")
        if (!f.isFile) throw RunnerError("no star-removal-verify at $f: run `swift build -c release --package-path trail_tools`, or set STAR_REMOVAL_VERIFY")
        return f
    }

    private fun labelsJson(): JsonObject {
        val labels = File(sequenceCopy, "labels.json")
        if (!labels.isFile) throw RunnerError("no labels.json in the sequence: $labels")
        return JsonParser.parseString(labels.readText()).asJsonObject
    }

    /** Runs the verifier. Reports go in the scratch directory as `report-removal-*`, which `saveArtifacts` copies out for CI. */
    private fun runRemovalVerifier(extra: List<String>, reportName: String): JsonObject {
        if (completeFrames < 0) throw RunnerError("\"I process every frame\" has not run")
        val report = File(scratch, "report-removal-$reportName.json")
        val crops = File(scratch, "report-removal-$reportName-crops")
        val args = listOf(
            removalVerifierBinary().absolutePath,
            "--input", sequenceCopy.absolutePath, "--output", outputFrames().absolutePath,
            "--labels", File(sequenceCopy, "labels.json").absolutePath,
            "--thresholds", File(repoRoot(), "gherkin/removal-thresholds.json").absolutePath,
            "--clean-method", removalMethod(), "--dataset", sequenceCopy.name,
            "--skip-unmeasurable", "--report", report.absolutePath, "--crops", crops.absolutePath,
        ) + extra
        val p = ProcessBuilder(args).redirectErrorStream(true).start()
        val text = p.inputStream.bufferedReader().readText()
        val status = p.waitFor()
        println(text.lines().takeLast(12).joinToString("\n"))
        if (status != 0) {
            throw RunnerError("star-removal-verify exited $status for \"${feature.id}\"\n" + text.lines().takeLast(30).joinToString("\n") +
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
        // Per-object verdicts differ between platforms, and selective leaves most faint labelled streaks alone by design (BUGS.md BUG-004);
        // automatic:true is judged by the fraction removed plus pinned objects. See the cli runner.
        val pinsFile = File(repoRoot(), "gherkin/removal-pins.json")
        val pinned = JsonParser.parseString(pinsFile.readText()).asJsonObject.getAsJsonArray("pins").size()
        val extra = mutableListOf("--expect", "$trailClass=removed")
        val method = removalMethod()
        when (method) {
            "selective" -> extra += listOf("--pins-only", "--pins", pinsFile.absolutePath)
            "automatic:true" -> extra += listOf("--aggregate", "--pins", pinsFile.absolutePath)
        }
        val report = runRemovalVerifier(extra, "${trailClass}s-removed")
        // not vacuous: the verifier must have looked at every confirmed object of this class
        val summary = report.getAsJsonObject("summary")
        val objects = summary?.get("objects")?.asInt ?: -1
        if (expected <= 0) throw RunnerError("labels.json has no confirmed $trailClass objects: the step would check nothing")
        if (objects != expected) throw RunnerError("the verifier checked $objects $trailClass objects, labels.json has $expected confirmed: refusing to pass")
        if (method != "automatic:false") {
            val checked = summary.get("pinsChecked")?.asInt ?: -1
            if (checked != pinned) throw RunnerError("the verifier checked $checked pinned objects, removal-pins.json has $pinned: refusing to pass")
        }
        val measured = (summary.get("passed")?.asInt ?: 0) + (summary.get("failed")?.asInt ?: 0)
        if (measured <= 0) throw RunnerError("no $trailClass object was measurable: refusing to pass")
    }

    private fun nothingElseChanged() {
        if (removalMethod() != "selective") throw RunnerError("\"nothing outside the labelled trails changed\" is only valid with the selective clean method")
        val report = runRemovalVerifier(listOf("--unchanged-outside"), "unchanged-outside")
        val frames = outputFrames().listFiles { f -> f.isFile && !f.name.startsWith(".") }.orEmpty().size
        val covered = report.getAsJsonObject("collateral")?.size() ?: 0
        if (frames <= 0 || covered != frames) throw RunnerError("the unchanged-outside check covered $covered frames, Star wrote $frames: refusing to pass")
        if (report.get("collateralStatus")?.asString != "pass") throw RunnerError("the unchanged-outside check did not pass (status ${report.get("collateralStatus")})")
    }

    private fun starsPreserved() {
        val report = runRemovalVerifier(listOf("--stars"), "stars")
        val frames = outputFrames().listFiles { f -> f.isFile && !f.name.startsWith(".") }.orEmpty().size
        val stars = report.getAsJsonObject("stars")?.size() ?: 0
        if (frames <= 0 || stars != frames) throw RunnerError("the star check covered $stars frames, Star wrote $frames: refusing to pass")
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
        // A warning about a state that passes by itself (memory is low and star is waiting for it to free up) says something about the
        // machine, not about the run: a 7GB hosted runner raises it on every TIFF feature. Anything else is a problem.
        val banner = w.banner?.takeUnless { com.star.desktop.domain.WarningRouting.passes(it.warning) }
        assertTrue(banner == null && w.critical == null, "star reported warnings: banner=${w.banner}, critical=${w.critical}")
    }

    /**
     * What is running when a wait gives up, for the failure message: an open that hangs after the frame count is read is either ffmpeg
     * or the engine waiting on it, and which one is the whole question. Best effort, and only where `ps` exists.
     */
    private fun processSnapshot(): String = runCatching {
        val p = ProcessBuilder("ps", "-axo", "pid,ppid,stat,etime,pcpu,rss,command").redirectErrorStream(true).start()
        val lines = p.inputStream.bufferedReader().readLines()
        p.waitFor()
        "processes:\n" + (lines.take(1) + lines.filter { Regex("ffmpeg|ffprobe|stard").containsMatchIn(it) && !it.contains("ps -axo") }).joinToString("\n")
    }.getOrDefault("(no process snapshot: ps is not available)")

    /** Copies the validator's reports and the run's config.json to `$STAR_GHERKIN_ARTIFACTS/<feature>` for CI to upload. */
    private fun saveArtifacts(feature: Feature) {
        val dir = System.getenv("STAR_GHERKIN_ARTIFACTS")?.takeIf { it.isNotEmpty() } ?: return
        val dest = File(dir, feature.id).apply { mkdirs() }
        scratch.listFiles { f -> f.name.startsWith("report-") }.orEmpty().forEach { it.copyRecursively(File(dest, it.name), overwrite = true) }
        runCatching {
            val info = vm?.sessions?.session?.value
            val config = File(info?.configJsonPath?.ifEmpty { "${info.scratchSessionDir}/config.json" } ?: return@runCatching)
            if (config.isFile) config.copyTo(File(dest, "config.json"), overwrite = true)
        }
    }

    // ---- the start screen, the preferences, the menu and the windows ----

    /** The start screen, as the app launches: no sequence, and the preferences the earlier steps left in the scratch home. */
    private fun startWithNoSequence(t: ComposeUiTest) {
        showApp(t, newModel())
    }

    private fun preferencesFile() = File(System.getProperty("user.home"), ".star.userprefs.json")

    /** `n` recently opened sequences in the preferences the app will start from (each a config.json that exists: one that does not is dropped). */
    private fun seedRecents(n: Int) {
        val entries = JsonObject()
        for (i in 1..n) {
            val config = File(File(scratch, "recent$i").apply { mkdirs() }, "config.json").apply { writeText("{}") }
            entries.addProperty(config.absolutePath, 10L * i)
        }
        preferencesFile().writeText(JsonObject().apply { add("recentlyOpenedSequencelist", entries) }.toString())
    }

    /** The bytes of a file of `gherkin/ui/fixtures/prefs/`. */
    private fun fixtureBytes(name: String): ByteArray = File(repoRoot(), "gherkin/ui/fixtures/prefs/$name.json").readBytes()

    /** The preferences the app will start from are this file, as it is. */
    private fun seedPreferences(fixture: String) = preferencesFile().writeBytes(fixtureBytes(fixture))

    /** The file has not been touched for a few seconds, which is longer than the app takes to write one it means to write. */
    private fun expectPreferencesUnchanged(fixture: String) {
        val expected = fixtureBytes(fixture)
        val deadline = System.nanoTime() + 4_000_000_000L
        do {
            if (!preferencesFile().readBytes().contentEquals(expected)) throw RunnerError("the preferences file is not the fixture \"$fixture\" any more")
            Thread.sleep(500)
        } while (System.nanoTime() < deadline)
    }

    private fun expectPreferencesKey(t: ComposeUiTest, key: String) {
        fun has() = runCatching { JsonParser.parseString(preferencesFile().readText()).asJsonObject.has(key) }.getOrDefault(false)
        waitFor(t, "the preferences file to have the key \"$key\"", 15_000) { has() }
    }

    private fun expectUndecodableCopy(t: ComposeUiTest, fixture: String) {
        val copy = File(preferencesFile().path + ".undecodable")
        val expected = fixtureBytes(fixture)
        waitFor(t, "a copy of the unreadable preferences file beside it", 15_000) { copy.isFile && copy.readBytes().contentEquals(expected) }
    }

    private fun recentCount(): Int? = runCatching {
        JsonParser.parseString(preferencesFile().readText()).asJsonObject.getAsJsonObject("recentlyOpenedSequencelist")?.size() ?: 0
    }.getOrNull()

    private fun expectRecents(t: ComposeUiTest, n: Int) {
        waitFor(t, "the preferences file to list $n recent sequences", 15_000, { "(it lists ${recentCount()})" }) { recentCount() == n }
    }

    /** The command's menu title and item label, in English: from `gherkin/ui/commands.json` and the catalogue. */
    private fun menuItem(command: String): Pair<String, String> {
        val table = JsonParser.parseString(File(repoRoot(), "gherkin/ui/commands.json").readText()).asJsonObject
        val entry = table.getAsJsonArray("commands").map { it.asJsonObject }.firstOrNull { it["id"].asString == command }
            ?: throw RunnerError("no command \"$command\" in gherkin/ui/commands.json")
        val titleKey = table.getAsJsonObject("menus")[entry["menu"].asString].asString
        return com.star.desktop.i18n.localized(titleKey) to com.star.desktop.i18n.localized(entry["label"].asString)
    }

    /** The menu's item for the command, or null while there is no app or the menu does not have it. The menus are read on the UI thread, as composition reads what they enable on. */
    private fun findMenuCommand(t: ComposeUiTest, command: String): MenuEntry.Command? {
        val (title, label) = menuItem(command)
        val model = vm ?: return null
        return t.runOnUiThread { starMenusNow(model) }.firstOrNull { it.title == title }?.entries?.filterIsInstance<MenuEntry.Command>()?.firstOrNull { it.label == label }
    }

    private fun expectMenuCommand(t: ComposeUiTest, command: String, enabled: Boolean) {
        waitFor(t, "the menu command \"$command\" to be ${if (enabled) "enabled" else "disabled"}", 20_000,
            { "(${findMenuCommand(t, command)?.let { if (it.enabled) "it is enabled" else "it is disabled" } ?: "there is no such item"})" }) {
            findMenuCommand(t, command)?.enabled == enabled
        }
    }

    /** Chooses the item as a click on the menu would: what its handler does. A disabled item cannot be chosen, as in a menu. */
    private fun chooseMenuCommand(t: ComposeUiTest, command: String) {
        expectMenuCommand(t, command, enabled = true)
        val item = findMenuCommand(t, command) ?: throw RunnerError("no menu item for \"$command\"")
        t.runOnUiThread { item.onClick() }
        t.waitForIdle()
    }

    /** A secondary window is open when the flag `Main.kt` shows its `Window` for says so. */
    private fun windowIsOpen(name: String): Boolean {
        val model = vm ?: throw RunnerError("no app is running")
        return when (name) {
            "debug" -> model.showDebugWindow.value
            "outlier" -> model.showOutlierWindow.value
            "alignment" -> model.showAlignmentWindow.value
            "blob" -> model.showBlobWindow.value
            else -> throw RunnerError("no window called \"$name\" (debug, outlier, alignment or blob)")
        }
    }

    private fun expectWindow(t: ComposeUiTest, name: String, open: Boolean) {
        waitFor(t, "the $name window to be ${if (open) "open" else "closed"}", 15_000) { windowIsOpen(name) == open }
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
        const val PROCESS_TIMEOUT_MS = 50L * 60_000   // auto selective on a 4-core runner took over 25 minutes
        const val RENDER_TIMEOUT_MS = 10L * 60_000
        val REMOVAL_ACTIONS = setOf(StepAction.AIRPLANES_REMOVED, StepAction.SATELLITES_REMOVED, StepAction.STARS_PRESERVED, StepAction.NOTHING_ELSE_CHANGED)
        val VIDEO_EXTS = setOf("mov", "mp4", "m4v", "avi", "mkv", "mpg", "mpeg")
    }
}
