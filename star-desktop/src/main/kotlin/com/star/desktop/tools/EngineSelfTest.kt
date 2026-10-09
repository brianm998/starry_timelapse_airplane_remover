package com.star.desktop.tools

import com.star.desktop.data.SessionRepository
import com.star.desktop.engine.DaemonProcess
import com.star.desktop.engine.EngineState
import com.star.desktop.engine.EngineStatus
import com.star.desktop.engine.StarClient
import com.star.desktop.i18n.Strings
import com.star.proto.CleanMethod
import com.star.proto.FrameViewMode
import com.star.proto.ProgressEvent
import com.star.proto.SessionInfo
import com.star.proto.VideoEncodeSettings
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.io.File
import java.time.LocalDateTime

/**
 * End-to-end check that this install of the desktop client can drive its engine.
 *
 * It uses the app's own classes the way the app does — [DaemonProcess.resolveStardBinary] picks
 * the bundled `stard`, [EngineState] spawns it and does the `Daemon.Hello` handshake, and
 * [StarClient] makes the same RPCs the UI makes — so it fails for the same reasons the app does.
 * It is built into the app because the failures it exists to catch only happen in an installed
 * copy on a machine that did not build it: the Windows engine that died right after "connecting"
 * was a `stard.exe` shipped without its resources, which worked on every machine with the build
 * tree still present (including CI) and nowhere else.
 *
 *     Star --self-test [options] [<image sequence dir>]               (the installed launcher)
 *     ./gradlew selfTest -Pseq=/abs/seq -Pprocess -Pexport -Pvideo=/abs/clip.mp4  (development)
 *
 * Options:
 *   --process         also process every frame of the sequence (automatic clean) and check the result
 *   --export          also render the processed frames to a video (needs --process), which runs the
 *                     bundled ffmpeg the way the Render Video dialog does
 *   --video <file>    also import a video, which runs the bundled ffprobe and ffmpeg
 *   --scratch <dir>   engine scratch dir (default: the app's own)
 *   --report <file>   where to write the report (default: <scratch>/logs/self-test.txt)
 *
 * Exits 0 when every check passed, 1 otherwise. The report ends with the engine's own log,
 * which is the evidence a bug report needs.
 */
object EngineSelfTest {

    @JvmStatic
    fun main(args: Array<String>) {
        kotlin.system.exitProcess(run(args.toList()))
    }

    private class Options(
        val sequence: String?,
        val process: Boolean,
        val export: Boolean,
        val video: String?,
        val scratch: String,
        val report: File?,
    )

    private fun parse(args: List<String>): Options {
        var sequence: String? = null
        var process = false
        var export = false
        var video: String? = null
        var scratch = DaemonProcess.defaultScratchDir()
        var report: File? = null
        val it = args.iterator()
        while (it.hasNext()) {
            when (val a = it.next()) {
                "--process" -> process = true
                "--export" -> export = true
                "--video" -> video = it.next()
                "--scratch" -> scratch = it.next()
                "--report" -> report = File(it.next())
                else -> sequence = a
            }
        }
        return Options(sequence, process, export, video, scratch, report)
    }

    /** Runs the checks and returns the process exit status. */
    fun run(args: List<String>): Int {
        val options = parse(args)
        val reportFile = options.report ?: File(File(options.scratch, "logs"), "self-test.txt")
        val report = Report(reportFile)
        report.line("Star desktop self-test — ${LocalDateTime.now()}")
        report.line("os: ${System.getProperty("os.name")} ${System.getProperty("os.version")} ${System.getProperty("os.arch")}")
        report.line("java: ${System.getProperty("java.version")} (${System.getProperty("java.home")})")
        report.line("scratch: ${options.scratch}")
        report.line("")

        val passed = try {
            runBlocking(Dispatchers.Default) { checks(options, report) }
        } catch (e: Throwable) {
            report.line("FAIL  self-test aborted: $e")
            false
        }

        // The engine's own stderr — a Swift fatalError prints nowhere else.
        val engineLog = File(File(options.scratch, "logs"), "stard.log")
        report.line("")
        report.line("---- engine log (${engineLog.absolutePath}) ----")
        if (engineLog.exists()) engineLog.readLines().takeLast(ENGINE_LOG_LINES).forEach(report::line)
        else report.line("(none)")
        report.line("")
        report.line(if (passed) "RESULT: PASS" else "RESULT: FAIL")
        report.line("report written to ${reportFile.absolutePath}")
        report.close()
        return if (passed) 0 else 1
    }

    /** This run's output directory, removed afterwards when every check passed. */
    private var outputDir: File? = null

    private suspend fun checks(options: Options, report: Report): Boolean {
        if (options.export && !options.process) {
            // Frames are only there to export once processing has written them.
            report.check<Unit>("options") { error("--export needs --process: there are no processed frames to render until the sequence has been processed") }
            return false
        }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        var engine: EngineState? = null
        try {
            // 1. The engine binary, resolved exactly as the app resolves it.
            val stard = report.check("locate engine") {
                DaemonProcess.resolveStardBinary().also { detail = it }
            } ?: return false

            // 2. A packaged app must carry what the engine needs beside it. (In a development run
            //    stard comes from the build tree, which has the resources but not ffmpeg.)
            if (System.getProperty("compose.application.resources.dir") != null) {
                report.check("packaged engine files") {
                    val dir = File(stard).parentFile
                    val exe = if (File(stard).name.endsWith(".exe")) ".exe" else ""
                    val missing = listOf(
                        "StarCore_StarCore.resources/Localizations/languages.json",
                        "ffmpeg$exe",
                        "ffprobe$exe",
                    ).filterNot { File(dir, it).exists() }
                    check(missing.isEmpty()) { "missing beside ${dir.absolutePath}: ${missing.joinToString()}" }
                    detail = dir.absolutePath
                } // not fatal: what the engine does without them is the evidence worth having
            }

            // 3. Spawn + Daemon.Hello — the step the Windows engine died in.
            val running = EngineState(scope, scratchDir = options.scratch)
            engine = running
            val client: StarClient = report.check("start engine (Daemon.Hello)") {
                check(running.start()) { "engine did not start: ${failure(running)}" }
                val connected = running.status.value as EngineStatus.Connected
                detail = "engine ${connected.daemonVersion}, scratch ${connected.scratchDir}"
                running.client ?: error("connected but no client")
            } ?: return false

            // 4. The engine can read its own localization tables. Asking for Spanish and getting
            //    English back means the tables were not found, i.e. the resources did not ship.
            report.check("engine localization tables") {
                val resolved = client.hello(CLIENT_VERSION, "es").locale
                check(resolved == "es") { "asked for 'es', engine resolved '$resolved' — its resource tables are missing" }
                client.hello(CLIENT_VERSION, Strings.currentCode)
                detail = "es resolved"
            } ?: return false

            options.sequence?.let { sequence ->
                val dir = File(sequence).absoluteFile
                // The app writes beside the sequence; a run there would find the previous run's output
                // and skip the frames as already done. A fresh directory per run keeps every check real.
                val output = File(File(options.scratch, "self-test"), "run-${System.currentTimeMillis()}")
                outputDir = output

                // 5. Open the folder the way the app's "open image sequence" does.
                val info: SessionInfo = report.check("open image sequence") {
                    check(dir.isDirectory) { "not a directory: $dir" }
                    check(output.mkdirs()) { "could not create $output" }
                    val config = SessionRepository.defaultInitialConfig().toBuilder()
                        .setOutputPath(output.path)
                        .setCleanMethod(CleanMethod.CLEAN_AUTOMATIC) // the fast path; selective adds only classification
                        .build()
                    val opened = client.openSequence(dir.path, config)
                    check(opened.frameCount > 0) { "no frames found in $dir" }
                    check(opened.imageWidth > 0 && opened.imageHeight > 0) { "frame size ${opened.imageWidth}x${opened.imageHeight}" }
                    detail = "${opened.frameCount} frames, ${opened.imageWidth}x${opened.imageHeight}"
                    opened
                } ?: return false

                // 6. The first thing the UI shows: a preview decoded from the original frame.
                report.check("original frame preview") {
                    val ref = client.getFramePreview(info.sessionId, 0, FrameViewMode.VIEW_ORIGINAL)
                    requireFile(ref.path)
                    detail = ref.path
                } ?: return false

                if (options.process) {
                    // 7. Process every frame and wait for the sequence to finish.
                    report.check("process all frames") {
                        val done = CompletableDeferred<Unit>()
                        val events = scope.launch {
                            client.streamProgress(info.sessionId).collect { ev ->
                                if (ev.kindCase == ProgressEvent.KindCase.SEQUENCE_STATE && ev.sequenceState.state == "done") {
                                    done.complete(Unit)
                                }
                            }
                        }
                        delay(400) // subscribe before Start, as the app does
                        val started = System.nanoTime()
                        client.startProcessing(info.sessionId, 0, -1)
                        try {
                            withTimeout(PROCESS_TIMEOUT_MS) {
                                while (!done.isCompleted) {
                                    check(running.status.value is EngineStatus.Connected) { "engine died while processing: ${failure(running)}" }
                                    delay(500)
                                }
                            }
                        } finally {
                            events.cancel()
                        }
                        detail = "${info.frameCount} frames in ${(System.nanoTime() - started) / 1_000_000_000}s"
                    } ?: return false

                    report.check("processed frame preview") {
                        val ref = client.getFramePreview(info.sessionId, 0, FrameViewMode.VIEW_PROCESSED)
                        requireFile(ref.path)
                        detail = ref.path
                    } ?: return false

                    if (options.export) {
                        // 8. Render the processed frames to a video the way the Render Video dialog
                        //    does — explicit encode settings, the engine choosing the frames — which
                        //    runs the ffmpeg beside stard. ProRes in a .mov is StarCore's own default
                        //    and its encoder is native to every ffmpeg build, so a failure here is the
                        //    engine's doing rather than a missing codec. 30 fps because the frame
                        //    count is checked below, and a wrong frame length in the engine's ffmpeg
                        //    input only shows from about 29.97 fps up (a 3-frame video came out as 4).
                        report.check("export video (bundled ffmpeg)") {
                            val video = File(output, EXPORT_FILENAME)
                            val settings = VideoEncodeSettings.newBuilder()
                                .setFrameRate(30.0).setCodec("prores").setEncoder("prores")
                                .setPixelFormat("yuv444p10le").setMuxer("mov").build()
                            withTimeout(EXPORT_TIMEOUT_MS) {
                                client.exportVideo(info.sessionId, video.path, settings).collect { }
                            }
                            check(video.isFile && video.length() > 0) { "the export finished but ${video.path} is missing or empty" }
                            // A file with some frames in it is not a video of every frame: count them,
                            // with the ffprobe beside stard when there is one (a dev tree has none).
                            val ffprobe = File(File(stard).parentFile, if (File(stard).name.endsWith(".exe")) "ffprobe.exe" else "ffprobe")
                            val frames = if (ffprobe.canExecute()) probeFrameCount(ffprobe, video) else null
                            if (frames != null) {
                                check(frames == info.frameCount) { "the video has $frames frames, the sequence ${info.frameCount}" }
                            }
                            detail = "${video.length()} bytes, " + (frames?.let { "$it frames" } ?: "frames not counted (no ffprobe beside stard)")
                        } ?: return false
                    }
                }

                report.check("close session") { client.closeSession(info.sessionId); detail = "" } ?: return false
            }

            options.video?.let { video ->
                // 9. Import a video the way dropping one on the app does: ffprobe reads it, ffmpeg
                //    decodes it to frames — both found beside stard, so this is the bundled pair.
                val info: SessionInfo = report.check("import video (bundled ffprobe + ffmpeg)") {
                    val file = File(video).absoluteFile
                    check(file.isFile) { "not a file: $file" }
                    var done: SessionInfo? = null
                    withTimeout(VIDEO_TIMEOUT_MS) {
                        client.openVideo(file.path, SessionRepository.defaultInitialConfig()).collect { p ->
                            if (p.kindCase == com.star.proto.OpenProgress.KindCase.DONE) done = p.done
                        }
                    }
                    val opened = done ?: error("the import finished without a session")
                    check(opened.frameCount > 0) { "no frames decoded from $file" }
                    detail = "${opened.frameCount} frames, ${opened.imageWidth}x${opened.imageHeight}"
                    opened
                } ?: return false
                report.check("video frame preview") {
                    val ref = client.getFramePreview(info.sessionId, 0, FrameViewMode.VIEW_ORIGINAL)
                    requireFile(ref.path)
                    detail = ref.path
                } ?: return false
                report.check("close video session") { client.closeSession(info.sessionId); detail = "" } ?: return false
            }
            return report.allPassed
        } finally {
            engine?.let { e ->
                runCatching { e.shutdown() }
                // A clean engine never wrote a crash or a missing-resources complaint.
                report.check("engine log has no crash") {
                    val log = File(File(options.scratch, "logs"), "stard.log")
                    val bad = if (log.exists()) log.readLines().filter { l -> BAD_LOG_LINES.any { it in l } } else emptyList()
                    check(bad.isEmpty()) { bad.joinToString(" | ") }
                    detail = ""
                }
            }
            scope.cancel()
            // Full-size frames add up; keep them only when something needs looking at.
            if (report.allPassed) outputDir?.deleteRecursively()
        }
    }

    private fun failure(engine: EngineState): String =
        (engine.status.value as? EngineStatus.Failed)?.message ?: engine.status.value.toString()

    /** How many video frames [video] holds, by decoding it with [ffprobe]; null if that could not be read. */
    private fun probeFrameCount(ffprobe: File, video: File): Int? {
        val process = ProcessBuilder(
            ffprobe.path, "-v", "error", "-count_frames", "-select_streams", "v:0",
            "-show_entries", "stream=nb_read_frames", "-of", "default=noprint_wrappers=1:nokey=1", video.path,
        ).redirectErrorStream(true).start()
        // The answer is one number, far below the pipe's buffer, so waiting before reading is safe.
        if (!process.waitFor(PROBE_TIMEOUT_SECONDS, java.util.concurrent.TimeUnit.SECONDS)) {
            process.destroyForcibly()
            return null
        }
        return process.inputStream.bufferedReader().readText().trim().toIntOrNull()
    }

    private fun requireFile(path: String) {
        check(path.isNotEmpty()) { "engine returned no path" }
        val f = File(path)
        check(f.exists() && f.length() > 0) { "engine returned $path, which does not exist" }
    }

    /** Lines in the engine log that mean the install is broken even if every RPC answered. */
    private val BAD_LOG_LINES = listOf("Fatal error", "*** star has crashed ***", "StarCore resources (StarCore_StarCore) not found")

    private const val CLIENT_VERSION = "self-test"
    private const val ENGINE_LOG_LINES = 200
    private const val PROCESS_TIMEOUT_MS = 30L * 60 * 1000
    private const val EXPORT_TIMEOUT_MS = 10L * 60 * 1000
    private const val EXPORT_FILENAME = "star-self-test.mov"
    private const val PROBE_TIMEOUT_SECONDS = 60L
    private const val VIDEO_TIMEOUT_MS = 10L * 60 * 1000

    /** The checks' outcomes, echoed to stdout and written to [file]. */
    private class Report(private val file: File) {
        private val writer = runCatching { file.parentFile?.mkdirs(); file.bufferedWriter() }.getOrNull()
        var allPassed = true
            private set

        fun line(text: String) {
            println(text)
            writer?.apply { appendLine(text); flush() }
        }

        class Step { var detail: String = "" }

        /** Runs one check; returns its value, or null (recording the failure) if it threw. */
        suspend fun <T> check(name: String, block: suspend Step.() -> T): T? {
            val step = Step()
            val started = System.nanoTime()
            return try {
                val value = step.block()
                val ms = (System.nanoTime() - started) / 1_000_000
                line("PASS  $name (${ms}ms)${if (step.detail.isNotEmpty()) " — ${step.detail}" else ""}")
                value
            } catch (e: Throwable) {
                allPassed = false
                line("FAIL  $name — ${e.message ?: e}")
                null
            }
        }

        fun close() { runCatching { writer?.close() } }
    }
}
