package com.star.desktop.ui.app

import com.star.proto.VideoEncodeSettings

/**
 * The question at the end of a run, "render a video now?" (macOS `handleProcessingDone`), and which run it is about.
 *
 * The user's answer, or the preference that has them not asked, is given for one run: the one the Process All that asked it started. It is
 * [arm]ed for that run's number. A run begun after it (process from here, a frame again, a re-process, a settings change that started the run
 * over) is another run, and the question is not put at its end: the desktop asked it at whichever run ended while the answer was still
 * there, so a re-process ended with a prompt, or with a video of a partial sequence rendered unasked (P11). Nothing at the end of a run
 * that stopped or failed either.
 */
class RenderQuestion {
    enum class Outcome { NOTHING, ASK, RENDER }

    private var armedFor: Int? = null
    private var render = false
    private var ask = false

    /**
     * How the render at the end is to be done, as chosen in the prompt's options step, while armed to render. Read before [done], which
     * drops it with the rest. null when nothing was chosen: the render then starts from the session's config.
     */
    var renderSettings: VideoEncodeSettings? = null
        private set

    /**
     * Arm for run number [forRun]: [render] says yes, render at its end (answered in the first prompt), [ask] puts the question to the user
     * there (the render prompts are not turned off). Neither is no question at all, which is the same as not arming. [settings] is how to
     * render when [render] is set.
     */
    fun arm(forRun: Int, render: Boolean, ask: Boolean, settings: VideoEncodeSettings? = null) {
        if (!render && !ask) { disarm(); return }
        armedFor = forRun
        this.render = render
        this.ask = ask
        renderSettings = settings.takeIf { render }
    }

    /** The run stopped or failed, or the sequence closed: whatever was armed is dropped, the settings with it. */
    fun disarm() {
        armedFor = null
        render = false
        ask = false
        renderSettings = null
    }

    /** A run ended cleanly, with [runsStarted] runs started so far: what to do about the question. Used up either way. */
    fun done(runsStarted: Int): Outcome {
        val run = armedFor ?: return Outcome.NOTHING
        val answer = if (render) Outcome.RENDER else if (ask) Outcome.ASK else Outcome.NOTHING
        disarm()
        return if (runsStarted == run) answer else Outcome.NOTHING
    }
}
